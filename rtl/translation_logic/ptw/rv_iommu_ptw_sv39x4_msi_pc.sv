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
//
// Description: RISC-V IOMMU Hardware Page Table Walker (PTW). Translation scheme Sv39x4.
//              This module is an adaptation of the CVA6 Sv39 MMU developed by 
//              David Schaffenrath and Florian Zaruba; and the CVA6 Sv39x4 TLB 
//              developed by Bruno Sá.
//              Includes MSI translation support.
//              Includes support for CDW implicit translations when walking the PDT.

/* verilator lint_off WIDTH */

module rv_iommu_ptw_sv39x4_msi_pc #(
    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
) (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Error signaling
    output logic                                ptw_active_o,           // Set when PTW is walking memory
    output logic                                ptw_error_o,            // set when an error occurred (excluding access errors)
    output logic                                ptw_error_2S_o,         // set when the fault occurred in stage 2
    output logic                                ptw_error_2S_int_o,     // set when an error occurred in stage 2 during stage 1 translation
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_o,

    input  logic                    en_1S_i,        // Enable signal for first-stage translation. Defined by DC/PC
    input  logic                    en_2S_i,        // Enable signal for second-stage translation. Defined by DC only
    input  logic                    is_store_i,     // Indicate whether this translation was triggered by a store or a load
    input  logic                    is_rx_i,        // Indicate whether the access is read-for-execute

    input  axi_rsp_t   mem_resp_i,
    output axi_req_t    mem_req_o,

    // to IOTLB, update logic
    output logic                    update_o,
    output logic                    up_1S_2M_o,
    output logic                    up_1S_1G_o,
    output logic                    up_2S_2M_o,
    output logic                    up_2S_1G_o,
    output logic                    up_is_msi_o,
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
    input  logic                                    msi_en_i,
    input  logic [(riscv::PPNW-1):0]                msiptp_ppn_i,
    input  logic [(rv_iommu::MSI_MASK_LEN-1):0]     msi_addr_mask_i,
    input  logic [(rv_iommu::MSI_PATTERN_LEN-1):0]  msi_addr_pattern_i,
    output logic                                    bare_translation_o,

    // CDW implicit translations (Second-stage only)
    input  logic                        cdw_implicit_access_i,
    input  logic [(riscv::GPPNW-1):0]   pdt_gppn_i,
    output logic                        cdw_done_o,
    output logic                        flush_cdw_o,

    // from IOTLB, to monitor misses
    input  logic                    iotlb_access_i,
    input  logic                    iotlb_hit_i,

    // from DC/PC
    input  logic [riscv::PPNW-1:0]  iosatp_ppn_i,  // ppn from iosatp
    input  logic [riscv::PPNW-1:0]  iohgatp_ppn_i, // ppn from iohgatp (may be forwarded by the CDW)

    output logic [riscv::GPLEN-1:0] bad_gpaddr_o    // to return the GPA in case of second-stage error
);

    // PTW states
    enum logic[2:0] {
      IDLE,             // 000
      MEM_ACCESS,       // 001
      PTE_LOOKUP,       // 010
      PROPAGATE_ERROR   // 011
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

    // To cast input memory port to MSI PTE data
    rv_iommu::msi_wt_pte_t msi_pte;
    assign msi_pte = rv_iommu::msi_wt_pte_t'(mem_resp_i.r.data);

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
    logic [riscv::PLEN-1:0] gpa_x_q, gpa_x_n;
    
    // MSI address translation
    logic msi_translation_q, msi_translation_n;
    logic iova_is_imsic_addr, gpaddr_is_imsic_addr;

    // CDW implicit accesses
    logic cdw_implicit_access_q, cdw_implicit_access_n;

    // To save final GPA
    logic [riscv::GPLEN-1:0] final_gpa;

    // To signal page faults / guest page faults
    logic pf_excep_q, pf_excep_n;

    // input IOVA (GPA) is the address of a virtual IMSIC
    assign iova_is_imsic_addr =   (!en_1S_i && msi_en_i && is_store_i &&
                                   ((req_iova_i[(riscv::GPLEN-1):12] & ~msi_addr_mask_i) == (msi_addr_pattern_i & ~msi_addr_mask_i)));
    // GPA is the address of a virtual IMSIC
    assign gpaddr_is_imsic_addr = (en_1S_i && msi_en_i && is_store_i &&
                                   ((pte.ppn[riscv::GPPNW-1:0] & ~msi_addr_mask_i) == (msi_addr_pattern_i & ~msi_addr_mask_i)));

    // PTW walking
    assign ptw_active_o    = (state_q != IDLE);

    //# IOTLB Update combinational logic
    always_comb begin : iotlb_update
        
        // vpn to be updated in the IOTLB
        up_vpn_o = {{41-riscv::SVX{1'b0}}, iova_q[riscv::SVX-1:12]};
        up_is_msi_o  = 1'b0;

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

        if(msi_translation_q)    up_is_msi_o  = 1'b1;

        up_pscid_o = iotlb_update_pscid_q;
        up_gscid_o = iotlb_update_gscid_q;

        // set the global mapping bit
        if(en_2S_i) begin   // if stage 2 is enabled
            up_1S_content_o = leaf_1Spte_q | (global_mapping_q << 5);
            up_2S_content_o = pte;
        end 
        
        else begin
            // If stage 2 is disabled and GPA (SPA) is an MSI address, first-stage PTE is stored in gpte
            if (msi_translation_q) begin
                up_1S_content_o = leaf_1Spte_q | (global_mapping_q << 5);
                up_2S_content_o = pte;
            end
            else begin
                up_1S_content_o = pte | (global_mapping_q << 5);
                up_2S_content_o = '0;
            end
        end
    end

    logic [(rv_iommu::CAUSE_LEN-1):0] cause_q, cause_n;

    assign bad_gpaddr_o = ptw_error_2S_o ? ((ptw_stage_q == STAGE_2_INTERMED) ? gpa_x_q[riscv::GPLEN-1:0] : gpaddr_q) : '0;

    //# Page table walker
    always_comb begin : ptw
        automatic logic [riscv::PLEN-1:0] gpa_x;
        // default assignments
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0010; 
        mem_req_o.aw.addr       = '0;           // Physical address to access
        mem_req_o.aw.len        = 8'b0;                 // 1 beat per burst only
        mem_req_o.aw.size       = 3'b011;               // 64 bits (8 bytes) per beat
        mem_req_o.aw.burst      = axi_pkg::BURST_FIXED; // Fixed start address
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
        mem_req_o.ar.id                     = 4'b0000;          
        mem_req_o.ar.addr[riscv::PLEN-1:0]  = ptw_pptr_q;           // Physical address to access
        mem_req_o.ar.len                    = 8'b0;                 // 1 beat per burst only
        mem_req_o.ar.size                   = 3'b011;               // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst                  = axi_pkg::BURST_FIXED; // Fixed start address
        mem_req_o.ar.lock                   = '0;
        mem_req_o.ar.cache                  = '0;
        mem_req_o.ar.prot                   = '0;
        mem_req_o.ar.qos                    = '0;
        mem_req_o.ar.region                 = '0;
        mem_req_o.ar.user                   = '0;

        mem_req_o.ar_valid      = 1'b0;                 // to init a request
        mem_req_o.r_ready       = 1'b0;                 // to signal read completion
        
        ptw_error_o             = 1'b0;
        ptw_error_2S_o          = 1'b0;
        ptw_error_2S_int_o      = 1'b0;
        cause_code_o            = '0;
        update_o                = 1'b0;
        cdw_done_o              = 1'b0;
        flush_cdw_o             = 1'b0;
        bare_translation_o      = 1'b0;
        
        main_lvl_n              = main_lvl_q;
        s1_lvl_n                = s1_lvl_q;
        ptw_pptr_n              = ptw_pptr_q;
        gpa_x_n                 = gpa_x_q;
        state_n                 = state_q;
        ptw_stage_n             = ptw_stage_q;
        leaf_1Spte_n            = leaf_1Spte_q;
        global_mapping_n        = global_mapping_q;
        msi_translation_n       = msi_translation_q;
        iotlb_update_pscid_n    = iotlb_update_pscid_q;
        iotlb_update_gscid_n    = iotlb_update_gscid_q;
        iova_n                  = iova_q;
        gpaddr_n                = gpaddr_q;
        gpa_x                   = ptw_pptr_q;
        final_gpa               = gpaddr_q;
        cause_n                 = cause_q;
        cdw_implicit_access_n   = cdw_implicit_access_q;

        case (state_q)

            // Check for possible misses to trigger PTW
            IDLE: begin
                // by default we start with the top-most page table
                main_lvl_n          = LVL1;
                s1_lvl_n            = LVL1;
                global_mapping_n    = 1'b0;
                msi_translation_n   = 1'b0;
                gpaddr_n            = '0;
                leaf_1Spte_n        = '0;
                pf_excep_n          = 1'b0;

                // check for possible IOTLB miss
                if ((iotlb_access_i & ~iotlb_hit_i) || cdw_implicit_access_i) begin

                    // Two-stage: start in S2-L1
                    if (en_1S_i && en_2S_i) begin

                        ptw_stage_n = STAGE_2_INTERMED;

                        //# GPA_1
                        // Translate iosatp. Segments of the GVA are used as offset
                        gpa_x = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};
                        gpa_x_n = gpa_x;

                        // pptr for first S2-L1
                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], gpa_x[riscv::SVX-1:30], 3'b0};
                    end

                    // Stage 2 only: Start in unique S2-L1
                    else if ((!en_1S_i && en_2S_i)) begin
                        
                        // Save the GPA
                        if (!cdw_implicit_access_i) gpaddr_n = req_iova_i[riscv::SVX-1:0];
                        else                        gpaddr_n = {pdt_gppn_i[riscv::GPPNW-1:0], 12'b0};

                        // MSI Address translation
                        if (iova_is_imsic_addr) begin
                            ptw_pptr_n = {msiptp_ppn_i, 12'b0} | (rv_iommu::extract_imsic_num(req_iova_i[(riscv::VLEN-1):12], msi_addr_mask_i) << 4);
                            msi_translation_n = 1'b1;   // signal next cycle
                            main_lvl_n         = LVL3;
                            s1_lvl_n        = LVL3;
                        end

                        // normal second-stage translation
                        else begin
                            ptw_stage_n = STAGE_2_FINAL;

                            // pptr for unique S2-L1
                            if (!cdw_implicit_access_i) ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], req_iova_i[riscv::SVX-1:30], 3'b0};
                            else                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pdt_gppn_i[riscv::GPPNW-1:18], 3'b0};
                        end
                    end
                    
                    // Stage 1 only: Start in S1-L1
                    else if (en_1S_i) begin
                        ptw_stage_n = STAGE_1;

                        // pptr for S1-L1
                        ptw_pptr_n  = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};
                    end

                    // MSI Address translation may be invoked even if no stage is enabled
                    else if (iova_is_imsic_addr) begin
                        ptw_pptr_n          = {msiptp_ppn_i, 12'b0} | {rv_iommu::extract_imsic_num(req_iova_i[(riscv::VLEN-1):12], msi_addr_mask_i), 4'b0};
                        msi_translation_n   = 1'b1;   // signal next cycle
                    end

                    if (en_1S_i || en_2S_i || iova_is_imsic_addr) begin

                        // register PSCID, GSCID and IOVA
                        iotlb_update_pscid_n   = pscid_i;
                        iotlb_update_gscid_n   = gscid_i;
                        iova_n = (cdw_implicit_access_i) ? ({pdt_gppn_i, 12'b0}) : (req_iova_i);
                        cdw_implicit_access_n  = cdw_implicit_access_i;
                        state_n                = MEM_ACCESS;
                    end

                    // If no stage is enabled and the input address is not associated with an IMSIC,
                    // then signal external logic that translation is complete without updating IOTLB
                    else bare_translation_o = 1'b1;
                end
            end

            // Perform memory access with address hold in ptw_pptr_q
            MEM_ACCESS: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;
                
                // wait for AXI Bus to accept the request
                if (mem_resp_i.ar_ready) begin
                    state_n     = PTE_LOOKUP;
                end
            end

            // Process the incoming memory data (hold in pte)
            PTE_LOOKUP: begin
                // we wait for RVALID to start reading
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;

                    //# MSI address translation
                    if (msi_translation_q) begin : msi_translation
                        state_n = IDLE;

                        update_o = 1'b1;

                        // MSI Translation faults: No priorities/order is defined by the spec.
                        // We stick to the translation process specified in section 2.3.

                        // "If msipte.V == 0, then stop and report "MSI PTE not valid" (cause = 262)"
                        // This implementation only supports standard MSI PTE formats (msi_pte.c = 0)
                        if (!msi_pte.v || msi_pte.c) begin
                            update_o = 1'b0;
                            cause_n = rv_iommu::MSI_PTE_INVALID;
                            state_n = PROPAGATE_ERROR;
                        end

                        // "If any bits or encoding that are reserved for future standard use are set within msipte," 
                        // "stop and report "MSI PTE misconfigured" (cause = 263)."
                        if ((|msi_pte.reserved_1) || (|msi_pte.reserved_2)) begin
                            update_o = 1'b0;
                            cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                            state_n = PROPAGATE_ERROR;
                        end

                        // "If the transaction is an Untranslated or Translated read-for-execute"
                        // "then stop and report Instruction access fault (cause = 1)."
                        if (is_rx_i) begin
                            update_o = 1'b0;
                            cause_n = rv_iommu::INSTR_ACCESS_FAULT;
                            state_n = PROPAGATE_ERROR;
                        end

                        // TODO: For now, only write-through mode for MSI translation is supported. Further on, implement MRIF mode.
                        if (msi_pte.m != rv_iommu::WRITE_THROUGH) begin
                            update_o = 1'b0;
                            cause_n = rv_iommu::TRANS_TYPE_DISALLOWED;
                            state_n = PROPAGATE_ERROR;
                        end

                        // MSI translation successful
                    end : msi_translation

                    //# Normal address translation
                    else begin : normal_translation
                        
                        // We need to save global configuration for non-leaf PTEs marked as global
                        if (pte.g && ptw_stage_q == STAGE_1)
                            global_mapping_n = 1'b1;

                        // Invalid PTE
                        // "If pte.v = 0, or if pte.r = 0 and pte.w = 1, stop and raise a page-fault exception corresponding to the original access type".
                        if (!pte.v || (!pte.r && pte.w)) begin
                            pf_excep_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;
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

                                        // GPA is an IMSIC address (even if Stage 2 is disabled)
                                        if (gpaddr_is_imsic_addr) begin
                                            state_n = MEM_ACCESS;
                                            ptw_pptr_n = {msiptp_ppn_i, 12'b0} | {rv_iommu::extract_imsic_num(pte.ppn[riscv::GPPNW-1:0], msi_addr_mask_i), 4'b0};
                                            msi_translation_n = 1'b1;
                                            main_lvl_n = LVL3;
                                            s1_lvl_n = LVL3;
                                        end
                                    end

                                    // result of any S2-L1 for 1G superpages, S2-L2 for 2M superpages and S2-L3 for 4K pages,
                                    // but the last
                                    STAGE_2_INTERMED: begin
                                        state_n = MEM_ACCESS;
                                        ptw_stage_n = STAGE_1;

                                        // Restore first-stage walk level
                                        main_lvl_n = s1_lvl_q;

                                        gpa_x = {pte.ppn[riscv::GPPNW-1:0], gpa_x_q[11:0]};

                                        // Consider case of superpages
                                        if (main_lvl_q == LVL2)
                                            gpa_x[20:0] = gpa_x_q[20:0];
                                        if (main_lvl_q == LVL1)
                                            gpa_x[29:0] = gpa_x_q[29:0];

                                        // pptr for S1-L1, S1-L2 or S1-L3
                                        ptw_pptr_n = gpa_x;
                                    end
                                    default:;
                                endcase

                                //# Valid translation found (either 1G, 2M or 4K entry): Update IOTLB
                                // IOTLB is updated only if PTE checks are passed, 
                                // so that these checks do not need to be performed again on an IOTLB hit

                                // Do not update IOTLB for CDW implicit accesses
                                // When Stage 2 is disabled and the GPA (SPA) is an MSI address, IOTLB is not updated yet and
                                // MSI translation process is invoked
                                if ((ptw_stage_q == STAGE_2_FINAL) || (!en_2S_i && !gpaddr_is_imsic_addr)) begin
                                        if (!cdw_implicit_access_q) update_o = 1'b1;
                                        else                        cdw_done_o = 1'b1;
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
                                    
                                    pf_excep_n        = 1'b1;
                                    state_n             = PROPAGATE_ERROR;
                                    ptw_stage_n         = ptw_stage_q;
                                    update_o            = 1'b0;
                                    cdw_done_o          = 1'b0;
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
                                                gpa_x = {pte.ppn, iova_q[29:21], 3'b0};
                                                gpa_x_n = gpa_x;

                                                // pptr for second S2-L1
                                                ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], gpa_x[riscv::SVX-1:30], 3'b0};
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
                                                gpa_x = {pte.ppn, iova_q[20:12], 3'b0};
                                                gpa_x_n = gpa_x;

                                                // pptr for third S2-L1
                                                ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], gpa_x[riscv::SVX-1:30], 3'b0};
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
                                    state_n     = PROPAGATE_ERROR;
                                    ptw_stage_n = ptw_stage_q;
                                end

                                //  "Otherwise, this PTE is a pointer to the next level of the page table. Let i = i − 1."
                                //  "If i < 0, stop and raise a page-fault exception corresponding to the original access type."
                                if (main_lvl_q == LVL3) begin
                                    pf_excep_n  = 1'b1;
                                    state_n     = PROPAGATE_ERROR;
                                    ptw_stage_n = ptw_stage_q;
                                end
                            end : non_leaf_pte
                        end : valid_pte

                        // Bits [63:54] are reserved for standard use and must be cleared by SW if the corresponding extension is not implemented
                        if ((|pte.reserved) != 1'b0) begin
                            pf_excep_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;  // GPPN bits [44:29] MUST be all zero
                            ptw_stage_n     = ptw_stage_q;
                            update_o        = 1'b0;
                            cdw_done_o      = 1'b0;
                        end

                        // "For Sv39x4 (...) GPA's bits 63:41 must all be zeros, or else a guest-page-fault exception occurs."
                        if (ptw_stage_q == STAGE_1 && (|pte.ppn[riscv::PPNW-1:riscv::GPPNW]) != 1'b0) begin
                            pf_excep_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;  // GPPN bits [44:29] MUST be all zero
                            ptw_stage_n     = STAGE_2_INTERMED;    // to throw guest page fault
                            update_o        = 1'b0;
                            cdw_done_o      = 1'b0;
                        end
                    end : normal_translation
                    
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
                        state_n = PROPAGATE_ERROR;

                        update_o = 1'b0;
                        cdw_done_o  = 1'b0;
                    end
                end
            end

            // Propagate error to IOMMU
            // We do need to propagate the bad GPA
            PROPAGATE_ERROR: begin
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
                flush_cdw_o = cdw_implicit_access_q;
            end

            default: begin
                state_n = IDLE;
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
            msi_translation_q       <= 1'b0;
            leaf_1Spte_q            <= '0;
            cause_q                 <= '0;
            cdw_implicit_access_q   <= 1'b0;
            pf_excep_q              <= 1'b0;

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
            msi_translation_q       <= msi_translation_n;
            leaf_1Spte_q            <= leaf_1Spte_n;
            cause_q                 <= cause_n;
            cdw_implicit_access_q   <= cdw_implicit_access_n;
            pf_excep_q              <= pf_excep_n;
        end
    end

endmodule

/* verilator lint_on WIDTH */
