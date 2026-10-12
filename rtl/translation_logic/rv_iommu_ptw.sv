// Copyright © 2025 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date: 20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Hardware Page Table Walker (PTW). Translation scheme Sv39x4.
//              This module is an adaptation of the CVA6 Sv39 PTW developed by
//              David Schaffenrath and Florian Zaruba; and the CVA6 Sv39x4 PTW
//              developed by Bruno Sá.

module rv_iommu_ptw #(

    /// RISC-V IOMMU configuration struct
    parameter rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::NullCfg,

    /// Address data type
    parameter type addr_t = logic,
    /// Physical address data type
    parameter type paddr_t = logic,

    /// AXI data types
    parameter type axi_req_t = logic,
    parameter type axi_resp_t = logic
) (
    input  logic                        clk_i,
    input  logic                        rst_ni,
    
    // Init PTW
    input  logic                        init_ptw_i,

    // Error signaling
    output logic                            active_o,
    output logic                            error_o,
    output logic                            error_2S_o,
    output logic                            error_2S_int_o,
    output logic [rv_iommu::GPLEN39-1:0]    bad_gpaddr_o,
    output rv_iommu::cause_t                cause_code_o,

    // Transaction data 
    input  logic                        en_1S_i,
    input  logic                        en_2S_i,
    input  logic                        is_store_i,
    input  logic                        is_rx_i,
    input  rv_iommu::ppn_t              iosatp_ppn_i,
    input  rv_iommu::ppn_t              iohgatp_ppn_i,

    // IOTLB tags
    input  addr_t                       iova_i,
    input  rv_iommu::pscid_t            pscid_i,
    input  rv_iommu::gscid_t            gscid_i,

    // IOTLB update port
    output rv_iommu::iotlb_up_t         update_o,

    // MSI translation
    input  logic                            msi_en_i,
    input  logic [rv_iommu::GPPNW39-1:0]    msi_addr_mask_i,
    input  logic [rv_iommu::GPPNW39-1:0]    msi_addr_pattern_i,

    // Bus to send first-stage data to MSI PTW
    output logic                            gpaddr_is_msi_o,
    output rv_iommu::iotlb_stage_content_t  msi_1S_content_o,

    // Implicit second-stage translations
    input  logic                        imp_init_i,
    input  rv_iommu::ppn_t              pdt_gppn_i,
    output logic                        imp_done_o,
    output logic                        imp_err_o,
    
    // Memory interface
    input  axi_resp_t                   mem_resp_i,
    output axi_req_t                    mem_req_o
);

    localparam int unsigned PLEN = RVIOMMUCfg.PAddrWidth;
    localparam int unsigned PPNW = PLEN-12;

    // PTW states
    typedef enum logic[1:0] {
      IDLE          = 2'b00,
      MEM_ACCESS    = 2'b01,
      PROC_PTE      = 2'b10,
      ERROR         = 2'b11
    } ptw_state_t;
    ptw_state_t state_q, state_n;

    // PTW walking
    assign active_o = (state_q != IDLE);
    
    // Page levels
    typedef enum logic [1:0] {
        LVL1    = 2'b00,
        LVL2    = 2'b01,
        LVL3    = 2'b10
    } ptw_lvl_t;
    ptw_lvl_t main_lvl_q, main_lvl_n;
    ptw_lvl_t s1_lvl_n, s1_lvl_q;

    // Internal PTW stages
    typedef enum logic [1:0] {
        STAGE_1,
        STAGE_2_INTERMED,
        STAGE_2_FINAL
    } ptw_stage_t;
    ptw_stage_t ptw_stage_q, ptw_stage_n;

    // To cast input memory port to normal PTE data
    rv_iommu::pte_t pte;
    assign pte = rv_iommu::pte_t'(mem_resp_i.r.data);

    // Global bit
    logic global_mapping_q, global_mapping_n;
    // IOVA
    addr_t iova_q, iova_n;
    // Intermediate GPAs
    logic [rv_iommu::GPLEN39-1:0] gpa_x_q, gpa_x_n;
    // Final GPA
    logic [rv_iommu::GPLEN39-1:0] gpaddr_q, gpaddr_n;
    // Leaf first-stage PTE
    rv_iommu::pte_t leaf_1Spte_q, leaf_1Spte_n;
    // Physical pointer
    paddr_t ptw_pptr_q, ptw_pptr_n;

    // GPA is the address of a virtual IF
    logic gpaddr_is_msi;

    // Implicit second-stage translation
    logic implicit_trans_q, implicit_trans_n;

    // Cause propagation
    rv_iommu::cause_t cause_q, cause_n;
    // Page faults / guest page faults
    logic pf_excep_q, pf_excep_n;
    // Data corruption
    logic pt_data_corrupt_q, pt_data_corrupt_n;

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;
    always_comb begin : ptw_init_control
        edge_trigger_n = edge_trigger_q;
        if (!edge_trigger_q && init_ptw_i)
            edge_trigger_n = 1'b1;
        if (edge_trigger_q && !init_ptw_i)
            edge_trigger_n = 1'b0;
    end

    //-------------------------
    // MSI Translation Support
    //-------------------------
    generate
        // Enabled
        if (RVIOMMUCfg.MSITrans != rv_iommu_cfg::MSI_DISABLED) begin : gen_msi_support_ptw
            assign gpaddr_is_msi    = (msi_en_i && is_store_i &&
                                        ((pte.ppn[rv_iommu::GPPNW39-1:0] & ~msi_addr_mask_i) == 
                                         (msi_addr_pattern_i & ~msi_addr_mask_i)));
            assign msi_1S_content_o.v       = pte.v;
            assign msi_1S_content_o.r       = pte.r;
            assign msi_1S_content_o.w       = pte.w;
            assign msi_1S_content_o.x       = pte.x;
            assign msi_1S_content_o.u       = pte.u;
            assign msi_1S_content_o.g       = pte.g;
            assign msi_1S_content_o.ppn     = pte.ppn;
            assign msi_1S_content_o.is_1G   = (main_lvl_q == LVL1);
            assign msi_1S_content_o.is_2M   = (main_lvl_q == LVL2);
        end
        // Disabled
        else begin : gen_msi_support_ptw_disabled
            assign gpaddr_is_msi    = 1'b0;
            assign msi_1S_content_o = '0;
        end

    endgenerate

    //--------------
    // IOTLB Update
    //--------------
    always_comb begin : iotlb_update
        
        update_o.vpn = iova_i[rv_iommu::GPLEN39-1:12];
        update_o.content.content_1S.is_2M = 1'b0;
        update_o.content.content_1S.is_1G = 1'b0;
        update_o.content.content_2S.is_2M = 1'b0;
        update_o.content.content_2S.is_1G = 1'b0;

        // Two-stage
        if(en_2S_i && en_1S_i) begin 
            update_o.content.content_2S.is_2M = (main_lvl_q == LVL2);
            update_o.content.content_2S.is_1G = (main_lvl_q == LVL1);
            update_o.content.content_1S.is_2M = (s1_lvl_q == LVL2);
            update_o.content.content_1S.is_1G = (s1_lvl_q == LVL1);
        end

        // stage 1 only
        else if(en_1S_i) begin
            update_o.content.content_1S.is_2M = (main_lvl_q == LVL2);
            update_o.content.content_1S.is_1G = (main_lvl_q == LVL1);
        end

        // stage 2 only
        else if (en_2S_i) begin
            update_o.content.content_2S.is_2M = (main_lvl_q == LVL2);
            update_o.content.content_2S.is_1G = (main_lvl_q == LVL1);
        end

        update_o.pscid = pscid_i;
        update_o.gscid = gscid_i;

        if(en_2S_i) begin
            update_o.content.content_1S.v    = leaf_1Spte_q.v;
            update_o.content.content_1S.r    = leaf_1Spte_q.r;
            update_o.content.content_1S.w    = leaf_1Spte_q.w;
            update_o.content.content_1S.x    = leaf_1Spte_q.x;
            update_o.content.content_1S.u    = leaf_1Spte_q.u;
            update_o.content.content_1S.g    = leaf_1Spte_q.g | global_mapping_q;
            update_o.content.content_1S.ppn  = leaf_1Spte_q.ppn;
            update_o.content.content_2S.v    = pte.v;
            update_o.content.content_2S.r    = pte.r;
            update_o.content.content_2S.w    = pte.w;
            update_o.content.content_2S.x    = pte.x;
            update_o.content.content_2S.u    = pte.u;
            update_o.content.content_2S.g    = pte.g;
            update_o.content.content_2S.ppn  = pte.ppn;
        end
        
        else begin
            update_o.content.content_1S.v    = pte.v;
            update_o.content.content_1S.r    = pte.r;
            update_o.content.content_1S.w    = pte.w;
            update_o.content.content_1S.x    = pte.x;
            update_o.content.content_1S.u    = pte.u;
            update_o.content.content_1S.g    = pte.g | global_mapping_q;
            update_o.content.content_1S.ppn  = pte.ppn;
            update_o.content.content_2S      = '0;
        end
    end

    //-----------------------------
    // PTW FSM combinational logic
    //-----------------------------
    always_comb begin : ptw_fsm_comb
        automatic paddr_t pptr;
        automatic logic [rv_iommu::GPLEN39-1:0] final_gpa;
        pptr = '0;
        final_gpa = '0;

        // Default assignments
        // AXI parameters
        // AW
        mem_req_o.aw            = '0;

        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w             = '0;

        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b1;

        // AR
        mem_req_o.ar            = '0;
        mem_req_o.ar.id         = 'd0;  // do not change unless you know what you are doing
        mem_req_o.ar.addr       = addr_t'(ptw_pptr_q);
        mem_req_o.ar.len        = 8'b0;
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;

        mem_req_o.ar_valid      = 1'b0;

        // R
        mem_req_o.r_ready       = 1'b0;
        
        update_o.update         = 1'b0;
        imp_done_o              = 1'b0;
        gpaddr_is_msi_o         = 1'b0;
        error_o                 = 1'b0;
        imp_err_o               = 1'b0;
        error_2S_o              = 1'b0;
        error_2S_int_o          = 1'b0;
        bad_gpaddr_o            = '0;
        cause_code_o            = '0;

        // Next state values
        state_n                 = state_q;
        ptw_stage_n             = ptw_stage_q;
        main_lvl_n              = main_lvl_q;
        s1_lvl_n                = s1_lvl_q;
        ptw_pptr_n              = ptw_pptr_q;
        iova_n                  = iova_q;
        gpaddr_n                = gpaddr_q;
        gpa_x_n                 = gpa_x_q;
        leaf_1Spte_n            = leaf_1Spte_q;
        global_mapping_n        = global_mapping_q;
        implicit_trans_n        = implicit_trans_q;
        cause_n                 = cause_q;
        pf_excep_n              = pf_excep_q;
        pt_data_corrupt_n       = pt_data_corrupt_q;

        unique case (state_q)

            // Check for possible misses to trigger PTW
            IDLE: begin
                main_lvl_n          = LVL1;
                s1_lvl_n            = LVL1;
                global_mapping_n    = 1'b0;
                gpaddr_n            = '0;
                leaf_1Spte_n        = '0;
                pf_excep_n          = 1'b0;
                pt_data_corrupt_n   = 1'b0;

                if (init_ptw_i && !edge_trigger_q) begin

                    state_n = MEM_ACCESS;
                    iova_n = (imp_init_i) ? 
                             (addr_t'({pdt_gppn_i, 12'b0})) : 
                             (iova_i);
                    implicit_trans_n = imp_init_i;

                    unique case ({en_1S_i, en_2S_i})

                        // Second stage only
                        2'b01: begin
                            
                            ptw_stage_n = STAGE_2_FINAL;
                        
                            // Normal second-stage translation
                            if (!imp_init_i) begin
                                gpaddr_n = iova_i[rv_iommu::GPLEN39-1:0];
                                ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], iova_i[rv_iommu::GPLEN39-1:30], 3'b0};

                                // From Spec:
                                // For G-stage translation Address bits 63:41 must all be zeros, or else a guest-page-fault exception occurs."
                                if (|iova_i[RVIOMMUCfg.AxiAddrWidth-1:rv_iommu::GPLEN39] != 1'b0) begin
                                    pf_excep_n  = 1'b1;
                                    state_n     = ERROR;
                                end
                            end

                            // Implicit second-stage translation
                            else begin
                                gpaddr_n = {pdt_gppn_i[rv_iommu::GPPNW39-1:0], 12'b0};
                                ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], pdt_gppn_i[rv_iommu::GPPNW39-1:18], 3'b0};
                            end
                        end 

                        // First stage only
                        2'b10: begin
                            
                            ptw_stage_n = STAGE_1;
                            ptw_pptr_n  = {iosatp_ppn_i[PPNW-1:0], iova_i[rv_iommu::VLEN39-1:30], 3'b0};
                        end

                        // Two-stage
                        2'b11: begin
                            ptw_stage_n = STAGE_2_INTERMED;

                            pptr[rv_iommu::GPLEN39-1:0] = {iosatp_ppn_i[rv_iommu::GPPNW39-1:0], iova_i[rv_iommu::VLEN39-1:30], 3'b0};
                            gpa_x_n = pptr[rv_iommu::GPLEN39-1:0];
                            ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], pptr[rv_iommu::GPLEN39-1:30], 3'b0};
                        end

                        // Both stages Bare (should never reach here)
                        default: begin
                            state_n = IDLE;
                        end
                    endcase
                end
            end

            // Perform memory access with address hold in ptw_pptr_q
            MEM_ACCESS: begin
                mem_req_o.ar_valid = 1'b1;
                if (mem_resp_i.ar_ready) begin
                    state_n = PROC_PTE;
                end
            end

            // Process PTEs
            PROC_PTE: begin

                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                        
                    if (pte.g && ptw_stage_q == STAGE_1)
                        global_mapping_n = 1'b1;

                    // From Spec:
                    // If pte.v = 0, or if pte.r = 0 and pte.w = 1, or if any bits or encodings that are reserved for
                    // future standard use are set within pte, stop and raise a page-fault exception corresponding
                    // to the original access type.
                    if (!pte.v || (!pte.r && pte.w) ||
                        (pte.g && (ptw_stage_q != STAGE_1))) begin
                        pf_excep_n    = 1'b1;
                        state_n         = ERROR;
                    end

                    // Valid PTE
                    else begin : valid_pte
                        state_n = IDLE;

                        // Leaf PTE
                        if (pte.r || pte.x) begin : leaf_pte
                            unique case (ptw_stage_q)
                                
                                // Leaf first-stage PTE
                                STAGE_1: begin

                                    final_gpa = {pte.ppn[rv_iommu::GPPNW39-1:0], iova_q[11:0]};

                                    // superpages
                                    if (main_lvl_q == LVL2)
                                        final_gpa[20:0] = iova_q[20:0];
                                    else if (main_lvl_q == LVL1)
                                        final_gpa[29:0] = iova_q[29:0];
                                    // LVL3 is a valid 4 KiB leaf; keep the PPN
                                    // and page offset assembled above.
                                    else if (main_lvl_q != LVL3) begin
                                        pf_excep_n  = 1'b1;
                                        state_n     = ERROR;
                                    end

                                    leaf_1Spte_n = pte;

                                    if (en_2S_i) begin
                                        state_n = MEM_ACCESS;
                                        ptw_stage_n = STAGE_2_FINAL;
                                        s1_lvl_n = main_lvl_q;
                                        main_lvl_n = LVL1;
                                        gpaddr_n = final_gpa;
                                        ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], final_gpa[rv_iommu::GPLEN39-1:30], 3'b0};

                                        // GPA is an MSI address
                                        if (gpaddr_is_msi) begin
                                            gpaddr_is_msi_o = 1'b1;
                                            state_n         = IDLE;
                                        end
                                    end
                                end

                                // Leaf intermediate second-stage PTE
                                STAGE_2_INTERMED: begin
                                    state_n = MEM_ACCESS;
                                    ptw_stage_n = STAGE_1;
                                    main_lvl_n = s1_lvl_q;
                                    pptr = {pte.ppn[PPNW-1:0], gpa_x_q[11:0]};

                                    // superpages
                                    if (main_lvl_q == LVL2)
                                        pptr[20:0] = gpa_x_q[20:0];
                                    else if (main_lvl_q == LVL1)
                                        pptr[29:0] = gpa_x_q[29:0];
                                    // A 4 KiB G-stage leaf also keeps the
                                    // already assembled PPN and page offset.
                                    else if (main_lvl_q != LVL3) begin
                                        pf_excep_n  = 1'b1;
                                        state_n     = ERROR;
                                    end
                                    ptw_pptr_n = pptr;
                                end
                                default:;
                            endcase

                            /*** Translation completed ***/

                            if ((ptw_stage_q == STAGE_2_FINAL) || (!en_2S_i)) begin
                                    if (!implicit_trans_q)
                                        update_o.update = 1'b1;
                                    else
                                        imp_done_o = 1'b1;
                            end

                            // From Spec:
                            // (1): If i > 0 and pte.vpn[i − 1 : 0] != 0, this is a misaligned superpage.
                            //      Stop and raise a page-fault exception corresponding to the original access type.
                            // (2): When a virtual page is accessed and the A bit is clear, or is written and the D bit is clear,
                            //      a page-fault exception is raised.
                            // (3): For G-stage address translation, all memory accesses are considered to be user-level accesses,
                            //      as though executed in U-mode.
                            if ((main_lvl_q == LVL1 && |pte.ppn[17:0] != 1'b0   ) ||       // 1G
                                (main_lvl_q == LVL2 && |pte.ppn[8:0] != 1'b0    ) ||       // 2M
                                (!pte.a || !pte.r || (is_store_i && !pte.d)     ) ||
                                (ptw_stage_q != STAGE_1 && !pte.u              )) begin
                                
                                pf_excep_n          = 1'b1;
                                state_n             = ERROR;
                                ptw_stage_n         = ptw_stage_q;
                                update_o.update     = 1'b0;
                                imp_done_o          = 1'b0;
                            end
                        end
                        
                        // Non-leaf PTE
                        else begin : non_leaf_pte

                            state_n = MEM_ACCESS;
                            
                            if (main_lvl_q == LVL1) begin

                                main_lvl_n = LVL2;
                                unique case (ptw_stage_q)

                                    STAGE_1: begin

                                        if (en_2S_i) begin
                                            ptw_stage_n = STAGE_2_INTERMED;
                                            main_lvl_n = LVL1;
                                            s1_lvl_n = LVL2;

                                            pptr[rv_iommu::GPLEN39-1:0] = {pte.ppn[rv_iommu::GPPNW39-1:0], iova_q[29:21], 3'b0};
                                            gpa_x_n = pptr[rv_iommu::GPLEN39-1:0];
                                            ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], pptr[rv_iommu::GPLEN39-1:30], 3'b0};
                                        end 
                                        
                                        else begin
                                            ptw_pptr_n = {pte.ppn[PPNW-1:0], iova_q[29:21], 3'b0};
                                        end
                                    end

                                    STAGE_2_INTERMED: begin
                                        ptw_pptr_n = {pte.ppn[PPNW-1:0], gpa_x_q[29:21], 3'b0};
                                    end

                                    STAGE_2_FINAL: begin
                                        ptw_pptr_n = {pte.ppn[PPNW-1:0], gpaddr_q[29:21], 3'b0};
                                    end
                                    default:;
                                endcase
                            end

                            else if (main_lvl_q == LVL2) begin
                                
                                main_lvl_n  = LVL3;
                                unique case (ptw_stage_q)

                                    STAGE_1: begin

                                        if (en_2S_i) begin
                                            ptw_stage_n = STAGE_2_INTERMED;
                                            main_lvl_n = LVL1;
                                            s1_lvl_n = LVL3;

                                            pptr[rv_iommu::GPLEN39-1:0] = {pte.ppn[rv_iommu::GPPNW39-1:0], iova_q[20:12], 3'b0};
                                            gpa_x_n = pptr[rv_iommu::GPLEN39-1:0];
                                            ptw_pptr_n = {iohgatp_ppn_i[PPNW-1:2], pptr[rv_iommu::GPLEN39-1:30], 3'b0};
                                        end 
                                        
                                        else begin
                                            ptw_pptr_n = {pte.ppn[PPNW-1:0], iova_q[20:12], 3'b0};
                                        end
                                    end

                                    STAGE_2_INTERMED: begin
                                        ptw_pptr_n = {pte.ppn[PPNW-1:0], gpa_x_q[20:12], 3'b0};
                                    end

                                    STAGE_2_FINAL: begin
                                        ptw_pptr_n = {pte.ppn[PPNW-1:0], gpaddr_q[20:12], 3'b0};
                                    end
                                    default:;
                                endcase
                            end

                            // From Spec:
                            // Otherwise, this PTE is a pointer to the next level of the page table. Let i = i − 1.
                            // If i < 0, stop and raise a page-fault exception corresponding to the original access type.
                            else begin
                                pf_excep_n  = 1'b1;
                                state_n     = ERROR;
                                ptw_stage_n = ptw_stage_q;
                            end

                            // From Spec:
                            // For non-leaf PTEs, the D, A, and U bits are reserved for future standard use.
                            // Until their use is defined by a standard extension, they MUST be cleared by software for forward compatibility.
                            if(pte.a || pte.d || pte.u) begin
                                pf_excep_n  = 1'b1;
                                state_n     = ERROR;
                                ptw_stage_n = ptw_stage_q;
                            end
                        end
                    end

                    // Bits [63:54] are reserved for standard use and must be cleared by SW if the corresponding extension is not implemented
                    if ((|pte.reserved) != 1'b0) begin
                        state_n         = ERROR;
                        pf_excep_n      = 1'b1;
                        ptw_stage_n     = ptw_stage_q;
                        update_o.update = 1'b0;
                        imp_done_o      = 1'b0;
                    end

                    // From Spec:
                    // For Sv39x4 (...) GPA's bits 63:41 must all be zeros, or else a guest-page-fault exception occurs.
                    if ((ptw_stage_q == STAGE_1) && (en_2S_i) && 
                        (|pte.ppn[43:rv_iommu::GPPNW39]) != 1'b0) begin
                        state_n         = ERROR;
                        pf_excep_n      = 1'b1;
                        ptw_stage_n     = STAGE_2_INTERMED;
                        update_o.update = 1'b0;
                        imp_done_o      = 1'b0;
                    end

                    // Check for AXI errors
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        state_n             = ERROR;
                        pt_data_corrupt_n   = 1'b1;
                        cause_n             = rv_iommu::PT_DATA_CORRUPTION;
                        update_o.update     = 1'b0;
                        imp_done_o          = 1'b0;
                    end
                end
            end

            // Propagate error to IOMMU
            ERROR: begin
                state_n     = IDLE;
                error_o     = 1'b1;
                imp_err_o   = implicit_trans_q;

                // Data corruption
                if (pt_data_corrupt_q) begin
                    cause_code_o = cause_q;
                end
                // Page fault
                else if (pf_excep_q) begin
                    if (ptw_stage_q != STAGE_1) begin
                        error_2S_o      = 1'b1;
                        error_2S_int_o  = (ptw_stage_q == STAGE_2_INTERMED) | implicit_trans_q;
                        bad_gpaddr_o    = (ptw_stage_q == STAGE_2_INTERMED) ? (gpa_x_q) : (gpaddr_q);
                        if (is_store_i)
                            cause_code_o = rv_iommu::STORE_GUEST_PAGE_FAULT;
                        else
                            cause_code_o = rv_iommu::LOAD_GUEST_PAGE_FAULT;
                    end
                    else begin
                        if (is_store_i)
                            cause_code_o = rv_iommu::STORE_PAGE_FAULT;
                        else
                            cause_code_o = rv_iommu::LOAD_PAGE_FAULT;
                    end
                end
            end
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : ptw_fsm_ff
        if (!rst_ni) begin
            state_q                 <= IDLE;
            ptw_stage_q             <= STAGE_1;
            main_lvl_q              <= LVL1;
            s1_lvl_q                <= LVL1;
            iova_q                  <= '0;
            gpaddr_q                <= '0;
            gpa_x_q                 <= '0;
            ptw_pptr_q              <= '0;
            leaf_1Spte_q            <= '0;
            cause_q                 <= '0;
            global_mapping_q        <= 1'b0;
            implicit_trans_q        <= 1'b0;
            pf_excep_q              <= 1'b0;
            pt_data_corrupt_q       <= 1'b0;
            edge_trigger_q          <= 1'b0;

        end else begin
            state_q                 <= state_n;
            ptw_stage_q             <= ptw_stage_n;
            main_lvl_q              <= main_lvl_n;
            s1_lvl_q                <= s1_lvl_n;
            iova_q                  <= iova_n;
            gpaddr_q                <= gpaddr_n;
            gpa_x_q                 <= gpa_x_n;
            ptw_pptr_q              <= ptw_pptr_n;
            leaf_1Spte_q            <= leaf_1Spte_n;
            cause_q                 <= cause_n;
            global_mapping_q        <= global_mapping_n;
            implicit_trans_q        <= implicit_trans_n;
            pf_excep_q              <= pf_excep_n;
            pt_data_corrupt_q       <= pt_data_corrupt_n;
            edge_trigger_q          <= edge_trigger_n;
        end
    end

endmodule
