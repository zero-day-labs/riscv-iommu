// Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
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
// Date: 16/01/2023
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Hardware Page Table Walker (PTW). Translation scheme Sv39x4.
//              This module is an adaptation of the CVA6 Sv39 MMU developed by
//              David Schaffenrath and Florian Zaruba; and the CVA6 Sv39x4 TLB
//              developed by Bruno Sá.
//              Includes MSI translation support parameterizable.

module rv_iommu_ptw_sv39x4 #(

    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans    = rv_iommu::MSI_DISABLED,

    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
) (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Trigger PTW
    input  logic                    init_ptw_i,

    // Error signaling
    output logic                                ptw_active_o,           // Set when PTW is walking memory
    output logic                                ptw_error_o,            // set when an error occurred (excluding access errors)
    output logic                                ptw_error_2S_o,         // set when the fault occurred in stage 2
    output logic                                ptw_error_2S_int_o,     // set when an error occurred in stage 2 during stage 1 translation
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_o,

    input  logic                    en_1S_i,        // Enable signal for first-stage translation. Defined by DC
    input  logic                    en_2S_i,        // Enable signal for second-stage translation. Defined by DC only
    input  logic                    is_store_i,     // Indicate whether this translation was triggered by a store or a load
    input  logic                    is_rx_i,        // Indicate whether the access is read-for-execute

    input  axi_rsp_t    mem_resp_i,
    output axi_req_t    mem_req_o,

    // to IOTLB, update logic
    output logic                    update_o,
    output logic                    up_1S_2M_o,
    output logic                    up_1S_1G_o,
    output logic                    up_2S_2M_o,
    output logic                    up_2S_1G_o,
    output logic [riscv::GPPNW-1:0] up_vpn_o,
    output logic [19:0]             up_pscid_o,
    output logic [15:0]             up_gscid_o,
    output riscv::pte_t             up_1S_content_o,
    output riscv::pte_t             up_2S_content_o,

    // IOTLB tags
    input  logic [riscv::VLEN-1:0]  req_iova_i,
    input  logic [19:0]             pscid_i,
    input  logic [15:0]             gscid_i,

    // MSI translation
    input  logic                    msi_en_i,
    input  logic [riscv::GPPNW-1:0] msi_addr_mask_i,
    input  logic [riscv::GPPNW-1:0] msi_addr_pattern_i,

    // Bus to send first-stage data to MSI PTW
    output logic                        gpaddr_is_msi_o,
    output logic [riscv::GPPNW-1:0]     msi_vpn_o,
    output logic                        msi_1S_2M_o,
    output logic                        msi_1S_1G_o,
    output riscv::pte_t                 msi_gpte_o,

    // from DC
    input  logic [riscv::PPNW-1:0]  iosatp_ppn_i,  // ppn from iosatp
    input  logic [riscv::PPNW-1:0]  iohgatp_ppn_i, // ppn from iohgatp

    output logic [riscv::GPLEN-1:0] bad_gpaddr_o    // to return the GPA in case of second-stage error
);

    // PTW states
    enum logic[1:0] {
      IDLE,         // 00
      MEM_ACCESS,   // 01
      PROC_PTE,     // 10
      ERROR         // 11
    } state_q, state_n;

    // Page levels: 3 for Sv39x4
    enum logic [1:0] {
        LVL1, LVL2, LVL3
    } main_lvl_q, main_lvl_n, s1_lvl_n, s1_lvl_q;

    // Internal PTW stages
    enum logic [1:0] {
        STAGE_1,            // Comes from a S1_XX memory access
        STAGE_2_INTERMED,   // Comes from a S2_XX memory access different from the last one
        STAGE_2_FINAL       // Comes from the last S2_XX memory accesses
    } ptw_stage_q, ptw_stage_n;

    // To cast input memory port to normal PTE data
    riscv::pte_t pte;
    assign pte = riscv::pte_t'(mem_resp_i.r.data);

    // Register to store leaf first-stage PTE to be updated in the IOTLB
    riscv::pte_t leaf_1Spte_q, leaf_1Spte_n;

    // global bit register
    logic global_mapping_q, global_mapping_n;
    // to register PSCID to be updated
    logic [19:0]  iotlb_update_pscid_q, iotlb_update_pscid_n;
    // to register GSCID to be updated
    logic [15:0]  iotlb_update_gscid_q, iotlb_update_gscid_n;
    // to register the input GVA (VPNs). SV39x4 defines a 39 bit virtual address for first stage
    logic [riscv::VLEN-1:0] iova_q,   iova_n;
    // to register the final leaf GPA (GPPNs). SV39x4 defines a 41 bit GPA for second stage
    logic [riscv::GPLEN-1:0] gpaddr_q, gpaddr_n;
    // 4 byte aligned physical pointer
    logic [riscv::PLEN-1:0] ptw_pptr_q, ptw_pptr_n;     // address used to access (read memory)
    // To save GPA_n
    logic [riscv::GPLEN-1:0] gpa_x_q, gpa_x_n;

    // GPA is the address of a virtual IF
    logic gpaddr_is_msi;

    // To save final GPA
    logic [riscv::GPLEN-1:0] final_gpa;

    // To signal page faults / guest page faults
    logic pf_excep_q, pf_excep_n;

    // PTW walking
    assign ptw_active_o    = (state_q != IDLE);

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;

    // FIFO edge-triggered push control
    always_comb begin : ptw_init_control

        // Default
        edge_trigger_n = edge_trigger_q;

        // Edged signal
        if (!edge_trigger_q && init_ptw_i)
            edge_trigger_n = 1'b1;

        // End of edged signal
        if (edge_trigger_q && !init_ptw_i)
            edge_trigger_n = 1'b0;

    end : ptw_init_control

    // MSI translation support
    generate

        // Enabled
        if (MSITrans != rv_iommu::MSI_DISABLED) begin : gen_msi_support

            // GPA is the address of a virtual interrupt file
            assign gpaddr_is_msi    = (msi_en_i && is_store_i &&
                                        ((pte.ppn[riscv::GPPNW-1:0] & ~msi_addr_mask_i) == 
                                         (msi_addr_pattern_i & ~msi_addr_mask_i)));

            // Bus to send first-stage data to MSI PTW                            
            assign msi_vpn_o        = iova_q[riscv::SVX-1:12];
            assign msi_1S_2M_o      = (main_lvl_q == LVL2);
            assign msi_1S_1G_o      = (main_lvl_q == LVL1);
            assign msi_gpte_o       = pte;
        end : gen_msi_support

        // Disabled
        else begin : gen_msi_support_disabled

            assign gpaddr_is_msi    = 1'b0;
            assign msi_vpn_o        = '0;
            assign msi_1S_2M_o      = 1'b0;
            assign msi_1S_1G_o      = 1'b0;
            assign msi_gpte_o       = '0;
        end : gen_msi_support_disabled

    endgenerate

    //# IOTLB Update combinational logic
    always_comb begin : iotlb_update
        
        // vpn to be updated in the IOTLB
        up_vpn_o = iova_q[riscv::SVX-1:12];

        up_1S_2M_o = 1'b0;
        up_1S_1G_o = 1'b0;
        up_2S_2M_o = 1'b0;
        up_2S_1G_o = 1'b0;

        // Two-stage
        if(en_2S_i && en_1S_i) begin 

            up_2S_2M_o = (main_lvl_q == LVL2);
            up_2S_1G_o = (main_lvl_q == LVL1);
            up_1S_2M_o = (s1_lvl_q == LVL2);
            up_1S_1G_o = (s1_lvl_q == LVL1);
        end

        // stage 1 only
        else if(en_1S_i) begin

            up_1S_2M_o = (main_lvl_q == LVL2);
            up_1S_1G_o = (main_lvl_q == LVL1);
        end

        // stage 2 only
        else if (en_2S_i) begin
            
            up_2S_2M_o = (main_lvl_q == LVL2);
            up_2S_1G_o = (main_lvl_q == LVL1);
        end

        up_pscid_o = iotlb_update_pscid_q;
        up_gscid_o = iotlb_update_gscid_q;

        // set the global mapping bit
        if(en_2S_i) begin   // if stage 2 is enabled
            up_1S_content_o = leaf_1Spte_q | ({63'b0, global_mapping_q} << 5);
            up_2S_content_o = pte;
        end
        
        else begin
            up_1S_content_o = pte | ({63'b0, global_mapping_q} << 5);
            up_2S_content_o = '0;
        end
    end

    logic [(rv_iommu::CAUSE_LEN-1):0] cause_q, cause_n;

    assign bad_gpaddr_o = ptw_error_2S_o ? ((ptw_stage_q == STAGE_2_INTERMED) ? gpa_x_q[riscv::GPLEN-1:0] : gpaddr_q) : '0;

    //# Page table walker
    always_comb begin : ptw
        automatic logic [riscv::PLEN-1:0] pptr;

        // Default assignments
        // Wires
        final_gpa               = '0;
        pptr                    = '0;

        // Output signals
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0010; 
        mem_req_o.aw.addr       = '0;           // Physical address to access
        mem_req_o.aw.len        = 8'b0;                 // 1 beat per burst only
        mem_req_o.aw.size       = 3'b011;               // 64 bits (8 bytes) per beat
        mem_req_o.aw.burst      = axi_pkg::BURST_INCR; // Fixed start address
        mem_req_o.aw.lock       = '0;
        mem_req_o.aw.cache      = '0;
        mem_req_o.aw.prot       = '0;
        mem_req_o.aw.qos        = '0;
        mem_req_o.aw.region     = '0;
        mem_req_o.aw.atop       = '0;
        mem_req_o.aw.user       = '0;

        mem_req_o.aw_valid      = 1'b0;                 // PTW will never write to memory

        // W
        mem_req_o.w.data        = '0;
        mem_req_o.w.strb        = '0;
        mem_req_o.w.last        = '0;
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;                 // PTW will never write to memory

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar.id         = 4'b0000;          
        mem_req_o.ar.addr       = {{riscv::XLEN-riscv::PLEN{1'b0}}, ptw_pptr_q};           // Physical address to access
        mem_req_o.ar.len        = 8'b0;                 // 1 beat per burst only
        mem_req_o.ar.size       = 3'b011;               // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR; // Fixed start address
        mem_req_o.ar.lock       = '0;
        mem_req_o.ar.cache      = '0;
        mem_req_o.ar.prot       = '0;
        mem_req_o.ar.qos        = '0;
        mem_req_o.ar.region     = '0;
        mem_req_o.ar.user       = '0;

        mem_req_o.ar_valid      = 1'b0;                 // to init a request

        // R
        mem_req_o.r_ready       = 1'b0;                 // to signal read completion
        
        ptw_error_o             = 1'b0;
        ptw_error_2S_o          = 1'b0;
        ptw_error_2S_int_o      = 1'b0;
        cause_code_o            = '0;
        update_o                = 1'b0;
        gpaddr_is_msi_o         = 1'b0;
        
        // Next state values
        main_lvl_n              = main_lvl_q;
        s1_lvl_n                = s1_lvl_q;
        ptw_pptr_n              = ptw_pptr_q;
        gpa_x_n                 = gpa_x_q;
        state_n                 = state_q;
        ptw_stage_n             = ptw_stage_q;
        leaf_1Spte_n            = leaf_1Spte_q;
        global_mapping_n        = global_mapping_q;
        iotlb_update_pscid_n    = iotlb_update_pscid_q;
        iotlb_update_gscid_n    = iotlb_update_gscid_q;
        iova_n                  = iova_q;
        gpaddr_n                = gpaddr_q;
        cause_n                 = cause_q;
        pf_excep_n              = pf_excep_q;

        case (state_q)

            // Check for possible misses to trigger PTW
            IDLE: begin
                // by default we start with the top-most page table
                main_lvl_n          = LVL1;
                s1_lvl_n            = LVL1;
                global_mapping_n    = 1'b0;
                gpaddr_n            = '0;
                leaf_1Spte_n        = '0;
                pf_excep_n          = 1'b0;

                // check for possible IOTLB miss
                if (init_ptw_i && !edge_trigger_q) begin

                    state_n = MEM_ACCESS;

                    // Determine walk configuration
                    case ({en_1S_i, en_2S_i})

                        // Stage 2 only: Start in unique S2-L1
                        2'b01: begin
                            
                            ptw_stage_n = STAGE_2_FINAL;
                        
                            gpaddr_n    = req_iova_i[riscv::SVX-1:0];
                            ptw_pptr_n  = {iohgatp_ppn_i[riscv::PPNW-1:2], req_iova_i[riscv::SVX-1:30], 3'b0};                 
                        end 

                        // Stage 1 only: Start in S1-L1
                        2'b10: begin
                            
                            ptw_stage_n = STAGE_1;

                            // pptr for S1-L1
                            ptw_pptr_n  = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};
                        end

                        // Two-stage: start in S2-L1
                        2'b11: begin
                            ptw_stage_n = STAGE_2_INTERMED;

                            //# GPA_1
                            // Translate iosatp. Segments of the GVA are used as offset
                            pptr[riscv::GPLEN-1:0] = {iosatp_ppn_i[riscv::GPPNW-1:0], req_iova_i[riscv::SV-1:30], 3'b0};
                            gpa_x_n = pptr[riscv::GPLEN-1:0];

                            // pptr for first S2-L1
                            ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                        end

                        // Both stages Bare (should never reach here)
                        default: begin
                            state_n = IDLE;
                        end
                    endcase

                    // register PSCID, GSCID and IOVA
                    iotlb_update_pscid_n    = pscid_i;
                    iotlb_update_gscid_n    = gscid_i;
                    iova_n                  = req_iova_i;
                end
            end

            // Perform memory access with address hold in ptw_pptr_q
            MEM_ACCESS: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;
                
                // wait for AXI Bus to accept the request
                if (mem_resp_i.ar_ready) begin
                    state_n = PROC_PTE;
                end
            end

            // Process normal PTEs
            PROC_PTE: begin
                // we wait for RVALID to start reading
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                        
                    // We need to save global configuration for non-leaf PTEs marked as global
                    if (pte.g && ptw_stage_q == STAGE_1)
                        global_mapping_n = 1'b1;

                    // Invalid PTE
                    // "If pte.v = 0, or if pte.r = 0 and pte.w = 1, stop and raise a page-fault exception corresponding to the original access type".
                    if (!pte.v || (!pte.r && pte.w)) begin
                        pf_excep_n    = 1'b1;
                        state_n         = ERROR;
                    end

                    //# Valid PTE
                    else begin : valid_pte
                        state_n = IDLE;

                        //# Leaf PTE
                        if (pte.r || pte.x) begin : leaf_pte
                            case (ptw_stage_q)
                                
                                // Result of S1-L1 for 1G superpages, S1-L2 for 2M superpages and S1-L3 for 4k pages
                                STAGE_1: begin

                                    //# FINAL GPA
                                    final_gpa = {pte.ppn[riscv::GPPNW-1:0], iova_q[11:0]};

                                    // update according to the size of the page
                                    if (main_lvl_q == LVL2)
                                        final_gpa[20:0] = iova_q[20:0];
                                    if (main_lvl_q == LVL1)
                                        final_gpa[29:0] = iova_q[29:0];

                                    // Save leaf first-stage PTE to update in IOTLB
                                    leaf_1Spte_n = pte;

                                    // If second-stage translation is enabled
                                    if (en_2S_i) begin
                                        state_n = MEM_ACCESS;
                                        
                                        // Save first-stage level where leaf PTE was found
                                        s1_lvl_n = main_lvl_q;

                                        // save FINAL GPA
                                        gpaddr_n = final_gpa;

                                        // Proceed with final second-stage translation
                                        ptw_stage_n = STAGE_2_FINAL;

                                        // pptr for final S2-L1
                                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], final_gpa[riscv::SVX-1:30], 3'b0};
                                        main_lvl_n = LVL1;
                                    end

                                    // GPA is an MSI address (even if Stage 2 is disabled)
                                    if (gpaddr_is_msi) begin
                                        gpaddr_is_msi_o = 1'b1;
                                        state_n         = IDLE;
                                    end
                                end

                                // result of any S2-L1 for 1G superpages, S2-L2 for 2M superpages and S2-L3 for 4K pages,
                                // but the last
                                STAGE_2_INTERMED: begin
                                    state_n = MEM_ACCESS;
                                    ptw_stage_n = STAGE_1;

                                    // Restore first-stage walk level
                                    main_lvl_n = s1_lvl_q;

                                    pptr = {pte.ppn, gpa_x_q[11:0]};

                                    // Consider case of superpages
                                    if (main_lvl_q == LVL2)
                                        pptr[20:0] = gpa_x_q[20:0];
                                    if (main_lvl_q == LVL1)
                                        pptr[29:0] = gpa_x_q[29:0];

                                    // pptr for S1-L1, S1-L2 or S1-L3
                                    ptw_pptr_n = pptr;
                                end
                                default:;
                            endcase

                            //# Valid translation found (either 1G, 2M or 4K entry): Update IOTLB
                            // IOTLB is updated only if PTE checks are passed, 
                            // so that these checks do not need to be performed again on an IOTLB hit

                            // When Stage 2 is disabled and the GPA (SPA) is an MSI address, IOTLB is not updated yet and
                            // MSI translation process is invoked
                            if ((ptw_stage_q == STAGE_2_FINAL) || (!en_2S_i && !gpaddr_is_msi)) begin
                                
                                update_o = 1'b1;
                            end

                            // "(1): If i > 0 and pte.vpn[i − 1 : 0] != 0, this is a misaligned superpage."
                            // "     Stop and raise a page-fault exception corresponding to the original access type."
                            // "(2): When a virtual page is accessed and the A bit is clear, or is written and the D bit is clear,"
                            // "     a page-fault exception is raised."
                            // "(3): For G-stage address translation, all memory accesses are considered to be user-level accesses," 
                            // "     as though executed in U-mode."
                            if ((main_lvl_q == LVL1 && |pte.ppn[17:0] != 1'b0   ) ||       // 1G
                                (main_lvl_q == LVL2 && |pte.ppn[8:0] != 1'b0    ) ||       // 2M
                                (!pte.a || !pte.r || (is_store_i && !pte.d)    ) ||
                                (ptw_stage_q != STAGE_1 && !pte.u              )) begin
                                
                                pf_excep_n          = 1'b1;
                                state_n             = ERROR;
                                ptw_stage_n         = ptw_stage_q;
                                update_o            = 1'b0;
                            end
                        end : leaf_pte
                        
                        //# non-leaf PTE
                        else begin : non_leaf_pte
                            if (main_lvl_q == LVL1) begin

                                main_lvl_n = LVL2;
                                case (ptw_stage_q)

                                    // Result of S1-L1
                                    STAGE_1: begin

                                        // Second-stage enabled: Construct GPA_2
                                        if (en_2S_i) begin
                                            ptw_stage_n = STAGE_2_INTERMED;
                                            s1_lvl_n = LVL2;    // save first-stage level

                                            //# GPA_2
                                            pptr[riscv::GPLEN-1:0] = {pte.ppn[riscv::GPPNW-1:0], iova_q[29:21], 3'b0};
                                            gpa_x_n = pptr[riscv::GPLEN-1:0];

                                            // pptr for second S2-L1
                                            ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                                            // restart second-stage walk level
                                            main_lvl_n = LVL1;
                                        end 
                                        
                                        // Second-stage disabled
                                        else begin
                                            // pptr for S1-L2
                                            ptw_pptr_n = {pte.ppn, iova_q[29:21], 3'b0};
                                        end
                                    end

                                    // Result of any S2-L1 but the last
                                    STAGE_2_INTERMED: begin
                                            // pptr for any S2-L2 but the last
                                            ptw_pptr_n = {pte.ppn, gpa_x_q[29:21], 3'b0};
                                    end

                                    // Result of last S2-L1
                                    STAGE_2_FINAL: begin
                                            // pptr for last S2-L2
                                            ptw_pptr_n = {pte.ppn, gpaddr_q[29:21], 3'b0};
                                    end
                                    default:;
                                endcase
                            end

                            if (main_lvl_q == LVL2) begin
                                
                                main_lvl_n  = LVL3;
                                unique case (ptw_stage_q)

                                    // Result of S1-L2
                                    STAGE_1: begin

                                        // Second-stage enabled: Construct GPA_3
                                        if (en_2S_i) begin
                                            ptw_stage_n = STAGE_2_INTERMED;
                                            s1_lvl_n = LVL3;

                                            //# GPA_3
                                            pptr[riscv::GPLEN-1:0] = {pte.ppn[riscv::GPPNW-1:0], iova_q[20:12], 3'b0};
                                            gpa_x_n = pptr[riscv::GPLEN-1:0];

                                            // pptr for third S2-L1
                                            ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                                            // restart second-stage walk level
                                            main_lvl_n = LVL1;
                                        end 
                                        
                                        // Second-stage disabled
                                        else begin
                                            // pptr for S1-L3
                                            ptw_pptr_n = {pte.ppn, iova_q[20:12], 3'b0};
                                        end
                                    end

                                    // Result S2-L2 but the last
                                    STAGE_2_INTERMED: begin
                                            // pptr for any S2-L3 but the last
                                            ptw_pptr_n = {pte.ppn, gpa_x_q[20:12], 3'b0};
                                    end

                                    // Result of last S2-L2
                                    STAGE_2_FINAL: begin
                                            // pptr for last S2-L3
                                            ptw_pptr_n = {pte.ppn, gpaddr_q[20:12], 3'b0};
                                    end
                                    default:;
                                endcase
                            end

                            state_n = MEM_ACCESS;

                            // "For non-leaf PTEs, the D, A, and U bits are reserved for future standard use."
                            // "Until their use is defined by a standard extension, they MUST be cleared by software for forward compatibility."
                            if(pte.a || pte.d || pte.u) begin
                                pf_excep_n  = 1'b1;
                                state_n     = ERROR;
                                ptw_stage_n = ptw_stage_q;
                            end

                            //  "Otherwise, this PTE is a pointer to the next level of the page table. Let i = i − 1."
                            //  "If i < 0, stop and raise a page-fault exception corresponding to the original access type."
                            if (main_lvl_q == LVL3) begin
                                pf_excep_n  = 1'b1;
                                state_n     = ERROR;
                                ptw_stage_n = ptw_stage_q;
                            end
                        end : non_leaf_pte
                    end : valid_pte

                    // Bits [63:54] are reserved for standard use and must be cleared by SW if the corresponding extension is not implemented
                    if ((|pte.reserved) != 1'b0) begin
                        pf_excep_n    = 1'b1;
                        state_n         = ERROR;  // GPPN bits [44:29] MUST be all zero
                        ptw_stage_n     = ptw_stage_q;
                        update_o        = 1'b0;
                    end

                    // "For Sv39x4 (...) GPA's bits 63:41 must all be zeros, or else a guest-page-fault exception occurs."
                    if (ptw_stage_q == STAGE_1 && (|pte.ppn[riscv::PPNW-1:riscv::GPPNW]) != 1'b0) begin
                        pf_excep_n      = 1'b1;
                        state_n         = ERROR;  // GPPN bits [44:29] MUST be all zero
                        ptw_stage_n     = STAGE_2_INTERMED;    // to throw guest page fault
                        update_o        = 1'b0;
                    end
                    
                    /*
                        # Note about IOPMP faults for PTW accesses:
                        IOPMP access faults are reported as failing AXI transactions. If accessing (reading) a PTE
                        violates an IOPMP check, the read transaction is responded with an AXI error in the R channel.
                        Custom data can be placed in the RDATA bus to differentiate IOPMP access faults from other 
                        AXI errors.
                    */

                    // Check for AXI errors
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        cause_n = rv_iommu::PT_DATA_CORRUPTION;
                        state_n = ERROR;

                        update_o = 1'b0;
                    end
                end
            end

            // Propagate error to IOMMU
            // We do need to propagate the bad GPA
            ERROR: begin
                state_n     = IDLE;
                ptw_error_o = 1'b1;

                // Set cause code and flags
                if (pf_excep_q) begin
                    if (ptw_stage_q != STAGE_1) begin
                        ptw_error_2S_o   = 1'b1;
                        if (is_store_i) cause_code_o = rv_iommu::STORE_GUEST_PAGE_FAULT;
                        else            cause_code_o = rv_iommu::LOAD_GUEST_PAGE_FAULT;
                    end
                    else begin
                        if (is_store_i) cause_code_o = rv_iommu::STORE_PAGE_FAULT;
                        else            cause_code_o = rv_iommu::LOAD_PAGE_FAULT;
                    end
                end
                else cause_code_o = cause_q;
                ptw_error_2S_int_o = (ptw_stage_q == STAGE_2_INTERMED) ? 1'b1 : 1'b0;
            end
        endcase
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q                 <= IDLE;
            ptw_stage_q             <= STAGE_1;
            main_lvl_q              <= LVL1;
            s1_lvl_q                <= LVL1;
            iotlb_update_pscid_q    <= '0;
            iotlb_update_gscid_q    <= '0;
            iova_q                  <= '0;
            gpaddr_q                <= '0;
            ptw_pptr_q              <= '0;
            gpa_x_q                 <= '0;
            global_mapping_q        <= 1'b0;
            leaf_1Spte_q            <= '0;
            cause_q                 <= '0;
            pf_excep_q              <= 1'b0;
            edge_trigger_q          <= 1'b0;


        end else begin
            state_q                 <= state_n;
            ptw_stage_q             <= ptw_stage_n;
            ptw_pptr_q              <= ptw_pptr_n;
            gpa_x_q                 <= gpa_x_n;
            main_lvl_q              <= main_lvl_n;
            s1_lvl_q                <= s1_lvl_n;
            iotlb_update_pscid_q    <= iotlb_update_pscid_n;
            iotlb_update_gscid_q    <= iotlb_update_gscid_n;
            iova_q                  <= iova_n;
            gpaddr_q                <= gpaddr_n;
            global_mapping_q        <= global_mapping_n;
            leaf_1Spte_q            <= leaf_1Spte_n;
            cause_q                 <= cause_n;
            pf_excep_q              <= pf_excep_n;
            edge_trigger_q          <= edge_trigger_n;
        end
    end

endmodule
