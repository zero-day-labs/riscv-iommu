// Copyright (c) 2023 University of Minho
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.

/*
    Author: Manuel Rodríguez, University of Minho
    Date: 16/01/2023

    Description: RISC-V IOMMU Hardware PTW (Page Table Walker). Translation scheme Sv39x4.

                This module is an adaptation of the CVA6 Sv39 MMU developed by:
                    -   David Schaffenrath, TU Graz,
                    -   Florian Zaruba, ETH Zurich;
                And the CVA6 Sv39x4 TLB developed by:
                    -   Bruno Sá, University of Minho.
*/

/* verilator lint_off WIDTH */

module iommu_ptw_sv39x4 import ariane_pkg::*; #(
        parameter int unsigned PSCID_WIDTH = 20,
        parameter int unsigned GSCID_WIDTH = 16
) (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Error signaling
    output logic                                ptw_active_o,           // Set when PTW is walking memory
    output logic                                ptw_error_o,            // set when an error occurred (excluding access errors)
    output logic                                ptw_error_stage2_o,     // set when the fault occurred in stage 2
    output logic                                ptw_error_stage2_int_o, // set when an error occurred in stage 2 during stage 1 translation
    output logic [(iommu_pkg::CAUSE_LEN-1):0]   cause_code_o,

    input  logic                    en_stage1_i,            // Enable signal for stage 1 translation. Defined by DC/PC
    input  logic                    en_stage2_i,            // Enable signal for stage 2 translation. Defined by DC only
    input  logic                    is_store_i,             // Indicate whether this translation was triggered by a store or a load
    input  logic                    is_rx_i,                // Indicate whether the access is read-for-execute

    input  ariane_axi_soc::resp_t   mem_resp_i,
    output ariane_axi_soc::req_t    mem_req_o,

    // to IOTLB, update logic
    output logic                    update_o,
    output logic                    up_is_s_2M_o,
    output logic                    up_is_s_1G_o,
    output logic                    up_is_g_2M_o,
    output logic                    up_is_g_1G_o,
    output logic                    up_is_msi_o,
    output logic [riscv::GPPNW-1:0] up_vpn_o,
    output logic [PSCID_WIDTH-1:0]  up_pscid_o,
    output logic [GSCID_WIDTH-1:0]  up_gscid_o,
    output riscv::pte_t             up_content_o,
    output riscv::pte_t             up_g_content_o,

    // IOTLB tags
    input  logic [riscv::VLEN-1:0]                  req_iova_i,
    //? Necessary to propagate? Or can we simply connect the CDTC outputs with the IOTLB update bus?
    input  logic [PSCID_WIDTH-1:0]                  pscid_i,
    input  logic [GSCID_WIDTH-1:0]                  gscid_i,

    // MSI translation
    input  logic                                    msi_en_i,
    input  logic [(riscv::PPNW-1):0]                msiptp_ppn_i,
    input  logic [(iommu_pkg::MSI_MASK_LEN-1):0]    msi_addr_mask_i,
    input  logic [(iommu_pkg::MSI_PATTERN_LEN-1):0] msi_addr_pattern_i,
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

    // // Performance counters
    // output logic                    itlb_miss_o,
    // output logic                    dtlb_miss_o,

    output logic [riscv::GPLEN-1:0] bad_gpaddr_o    // to return the GPA in case of second-stage error
);

    riscv::pte_t pte;
    // register to perform context switch between stages
    riscv::pte_t gpte_q, gpte_n;    // gpte is only used to store final GPA to be updated in the IOTLB
    assign pte = riscv::pte_t'(mem_resp_i.r.data);

    iommu_pkg::msi_wt_pte_t msi_pte;
    assign msi_pte = iommu_pkg::msi_wt_pte_t'(mem_resp_i.r.data);

    // PTW states
    enum logic[2:0] {
      IDLE,             // 000
      WAIT_GRANT,       // 001
      PTE_LOOKUP,       // 010
      PROPAGATE_ERROR   // 011
    } state_q, state_n;

    // Page levels: 3 for Sv39x4
    enum logic [1:0] {
        LVL1, LVL2, LVL3
    } ptw_lvl_q, ptw_lvl_n, gptw_lvl_n, gptw_lvl_q;     // GPTW_LVL is stage-1, PTW_LVL is stage-2

    // define 3 PTW stages
    // STAGE_1 -> Stage-1 normal translation controlled by iosatp
    // STAGE_2_INTERMED -> Converts the stage-1 non-leaf GPA pointers to SPA (controlled by iohgatp)
    // STAGE_2_FINAL -> Converts the stage-1 leaf GPA to SPA (controlled by iohgatp)
    enum logic [1:0] {
        STAGE_1,
        STAGE_2_INTERMED,
        STAGE_2_FINAL
    } ptw_stage_q, ptw_stage_n;

    // global mapping aux signal
    logic global_mapping_q, global_mapping_n;
    // to register PSCID to be updated
    logic [PSCID_WIDTH-1:0]  iotlb_update_pscid_q, iotlb_update_pscid_n;
    // to register GSCID to be updated
    logic [GSCID_WIDTH-1:0]  iotlb_update_gscid_q, iotlb_update_gscid_n;
    // to register the input GVA (VPNs). SV39x4 defines a 39 bit virtual address for first stage
    logic [riscv::VLEN-1:0] iova_q,   iova_n;
    // to register the final leaf GPA (GPPNs). SV39x4 defines a 41 bit GPA for second stage
    logic [riscv::GPLEN-1:0] gpaddr_q, gpaddr_n;
    // 4 byte aligned physical pointer
    logic [riscv::PLEN-1:0] ptw_pptr_q, ptw_pptr_n;     // address used to access (read memory)
    logic [riscv::PLEN-1:0] gptw_pptr_q, gptw_pptr_n;   // contains GPA of non-leaf entries of VS-stage page tables (direct GPA from iovsatp in the first iteration)
    
    // MSI address translation
    logic msi_translation_q, msi_translation_n;
    logic iova_is_imsic_addr, gpaddr_is_imsic_addr;

    // CDW implicit accesses
    logic cdw_implicit_access_q, cdw_implicit_access_n;

    // To save final GPA
    logic [riscv::GPLEN-1:0] gpaddr;

    // To signal page faults / guest page faults
    logic page_fault_q, page_fault_n;

    // input IOVA (GPA) is the address of a virtual IMSIC
    assign iova_is_imsic_addr =   (!en_stage1_i && msi_en_i &&
                                   ((req_iova_i[(riscv::GPLEN-1):12] & ~msi_addr_mask_i) == (msi_addr_pattern_i & ~msi_addr_mask_i)));
    // GPA is the address of a virtual IMSIC
    assign gpaddr_is_imsic_addr = (en_stage1_i && msi_en_i && 
                                   ((pte.ppn[riscv::GPPNW-1:0] & ~msi_addr_mask_i) == (msi_addr_pattern_i & ~msi_addr_mask_i)));

    // PTW walking
    assign ptw_active_o    = (state_q != IDLE);

    //# IOTLB Update combinational logic
    always_comb begin : iotlb_update
        
        // vpn to be updated in the IOTLB
        up_vpn_o = {{41-riscv::SVX{1'b0}}, iova_q[riscv::SVX-1:12]};
        up_is_msi_o  = 1'b0;

        up_is_s_2M_o = 1'b0;
        up_is_s_1G_o = 1'b0;
        up_is_g_2M_o = 1'b0;
        up_is_g_1G_o = 1'b0;

        // Two-stage
        if(en_stage2_i && en_stage1_i) begin 

            up_is_g_2M_o = (ptw_lvl_q == LVL2);
            up_is_g_1G_o = (ptw_lvl_q == LVL1);
            up_is_s_2M_o = (gptw_lvl_q == LVL2);
            up_is_s_1G_o = (gptw_lvl_q == LVL1);
        end

        // stage 1 only
        else if(en_stage1_i) begin

            up_is_s_2M_o = (ptw_lvl_q == LVL2);
            up_is_s_1G_o = (ptw_lvl_q == LVL1);
        end

        // stage 2 only
        else begin
            
            up_is_g_2M_o = (ptw_lvl_q == LVL2);
            up_is_g_1G_o = (ptw_lvl_q == LVL1);
        end

        if(msi_translation_q)    up_is_msi_o  = 1'b1;

        up_pscid_o = iotlb_update_pscid_q;
        up_gscid_o = iotlb_update_gscid_q;

        // set the global mapping bit
        //? Why set the global bit again?
        if(en_stage2_i) begin   // if stage 2 is enabled
            up_content_o = gpte_q | (global_mapping_q << 5);
            up_g_content_o = pte;
        end 
        
        else begin
            // If stage 2 is disabled and GPA (SPA) is an MSI address, first-stage PTE is stored in gpte
            if (msi_translation_q) begin
                up_content_o = gpte_q | (global_mapping_q << 5);
                up_g_content_o = pte;
            end
            else begin
                up_content_o = pte | (global_mapping_q << 5);
                up_g_content_o = '0;
            end
        end
    end

    logic allow_access;
    logic [(iommu_pkg::CAUSE_LEN-1):0] cause_q, cause_n;

    assign bad_gpaddr_o = ptw_error_stage2_o ? ((ptw_stage_q == STAGE_2_INTERMED) ? gptw_pptr_q[riscv::GPLEN-1:0] : gpaddr_q) : '0;

    //# Page table walker
    always_comb begin : ptw
        automatic logic [riscv::PLEN-1:0] pptr;
        // default assignments
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0010;              //? Can we define any value for AR.ID?
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
        mem_req_o.ar.id                     = 4'b0000;              //? Can we define any value for AR.ID?
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
        ptw_error_stage2_o      = 1'b0;
        ptw_error_stage2_int_o  = 1'b0;
        cause_code_o            = '0;
        update_o                = 1'b0;
        cdw_done_o              = 1'b0;
        flush_cdw_o             = 1'b0;
        bare_translation_o      = 1'b0;
        
        ptw_lvl_n               = ptw_lvl_q;
        gptw_lvl_n              = gptw_lvl_q;
        ptw_pptr_n              = ptw_pptr_q;
        gptw_pptr_n             = gptw_pptr_q;
        state_n                 = state_q;
        ptw_stage_n             = ptw_stage_q;
        gpte_n                  = gpte_q;
        global_mapping_n        = global_mapping_q;
        msi_translation_n       = msi_translation_q;
        iotlb_update_pscid_n    = iotlb_update_pscid_q;
        iotlb_update_gscid_n    = iotlb_update_gscid_q;
        iova_n                  = iova_q;
        gpaddr_n                = gpaddr_q;
        pptr                    = ptw_pptr_q;
        gpaddr                  = gpaddr_q;
        cause_n                 = cause_q;
        cdw_implicit_access_n   = cdw_implicit_access_q;

        // itlb_miss_o           = 1'b0;
        // dtlb_miss_o           = 1'b0;

        case (state_q)

            // check for possible misses to trigger PTW
            IDLE: begin
                // by default we start with the top-most page table
                ptw_lvl_n           = LVL1;
                gptw_lvl_n          = LVL1;
                global_mapping_n    = 1'b0;
                msi_translation_n   = 1'b0;
                gpaddr_n            = '0;
                gpte_n              = '0;
                page_fault_n        = 1'b0;

                // check for possible IOTLB miss
                if ((iotlb_access_i & ~iotlb_hit_i) || cdw_implicit_access_i) begin

                    // Two-stage
                    if (en_stage1_i && en_stage2_i) begin
                        // Start in G-L1
                        ptw_stage_n = STAGE_2_INTERMED;
                        // Store GPA to be segmented for all three levels of G-stage translation
                        pptr = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};   //* VS-L1
                        gptw_pptr_n = pptr;
                        // Load memory pointer with hgatp and GPPN[2] to access physical memory
                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                    end

                    // Stage 2 only
                    else if ((!en_stage1_i && en_stage2_i)) begin
                        
                        // Save the GPA in all cases to report if an error occurs
                        if (!cdw_implicit_access_i) gpaddr_n = req_iova_i[riscv::SVX-1:0];
                        else                        gpaddr_n = {pdt_gppn_i[riscv::GPPNW-1:0], 12'b0};

                        // MSI Address translation ( //? Exclude CDW translations? These should not trigger an MSI translation)
                        if (iova_is_imsic_addr) begin
                            ptw_pptr_n = {msiptp_ppn_i, 12'b0} | (iommu_pkg::extract_imsic_num(req_iova_i[(riscv::VLEN-1):12], msi_addr_mask_i) << 4);
                            msi_translation_n = 1'b1;   // signal next cycle
                        end

                        // normal second-stage translation
                        else begin
                            ptw_stage_n = STAGE_2_FINAL;
                            if (!cdw_implicit_access_i) ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], req_iova_i[riscv::SVX-1:30], 3'b0};
                            else                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pdt_gppn_i[riscv::GPPNW-1:18], 3'b0};
                        end
                    end
                    
                    // Stage 1 only
                    else if (en_stage1_i) begin
                        ptw_stage_n = STAGE_1;
                        ptw_pptr_n  = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};
                    end

                    // MSI Address translation may be invoked if no stage is enabled
                    else if (iova_is_imsic_addr) begin
                        ptw_pptr_n          = {msiptp_ppn_i, 12'b0} | {iommu_pkg::extract_imsic_num(req_iova_i[(riscv::VLEN-1):12], msi_addr_mask_i), 4'b0};
                        msi_translation_n   = 1'b1;   // signal next cycle
                    end

                    if (en_stage1_i || en_stage2_i || iova_is_imsic_addr) begin

                        // register PSCID, GSCID and IOVA
                        iotlb_update_pscid_n   = pscid_i;
                        iotlb_update_gscid_n   = gscid_i;
                        if (!cdw_implicit_access_i)
                            iova_n             = req_iova_i;
                        else
                            iova_n             = {pdt_gppn_i, 12'b0};
                        cdw_implicit_access_n  = cdw_implicit_access_i;
                        state_n                = WAIT_GRANT;
                        // iotlb_miss_o        = 1'b1;     // to HPM
                    end

                    // If no stage is enabled and the input address is not associated with an IMSIC,
                    // then signal external logic that translation is complete without updating IOTLB
                    else bare_translation_o = 1'b1;
                end
            end

            // perform memory access with address hold in ptw_pptr_q
            WAIT_GRANT: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;
                
                // wait for AXI Bus to accept the request
                if (mem_resp_i.ar_ready) begin
                    state_n     = PTE_LOOKUP;
                end
            end

            // process the incoming memory data (hold in pte)
            PTE_LOOKUP: begin
                // we wait for RVALID to start reading
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    // RLAST should be set

                    //# MSI address translation
                    if (msi_translation_q) begin
                        state_n = IDLE;
                        
                        // Invalid MSI PTE
                        // "If msipte.V == 0, then stop and report "MSI PTE not valid" (cause = 262)"
                        // This implementation will only support standard MSI PTE formats (msi_pte.c = 0)
                        if (!msi_pte.v || msi_pte.c) begin
                            cause_n = iommu_pkg::MSI_PTE_INVALID;
                            state_n = PROPAGATE_ERROR;
                        end

                        else begin
                            update_o = 1'b1;

                            // TODO: For now, only write-through mode for MSI translation is supported. Further on, implement MRIF mode.
                            if (msi_pte.m != iommu_pkg::WRITE_THROUGH) begin
                                update_o = 1'b0;
                                cause_n = iommu_pkg::TRANS_TYPE_DISALLOWED;
                                state_n = PROPAGATE_ERROR;
                            end

                            // "If any bits or encoding that are reserved for future standard use are set within msipte," 
                            // "stop and report "MSI PTE misconfigured" (cause = 263)."
                            if ((|msi_pte.reserved_1) || (|msi_pte.reserved_2))begin
                                update_o = 1'b0;
                                cause_n = iommu_pkg::MSI_PTE_MISCONFIGURED;
                                state_n = PROPAGATE_ERROR;
                            end

                            // "If the transaction is an Untranslated or Translated read-for-execute"
                            // "then stop and report Instruction access fault (cause = 1)."
                            if (is_rx_i) begin
                                update_o = 1'b0;
                                cause_n = iommu_pkg::INSTR_ACCESS_FAULT;
                                state_n = PROPAGATE_ERROR;
                            end

                            // MSI translation successful
                        end
                    end

                    //# Normal address translation
                    else begin
                        
                        // check if the global mapping bit is set
                        if (pte.g && ptw_stage_q == STAGE_1)
                            global_mapping_n = 1'b1;

                        // Invalid PTE
                        // "If pte.v = 0, or if pte.r = 0 and pte.w = 1, stop and raise a page-fault exception corresponding to the original access type".
                        if (!pte.v || (!pte.r && pte.w)) begin
                            page_fault_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;
                        end

                        //# Valid PTE
                        else begin
                            state_n = IDLE;

                            //# Leaf PTE
                            if (pte.r || pte.x) begin
                                case (ptw_stage_q)
                                    
                                    //# S1-L1 for 1G superpages, S1-L2 for 2M superpages and S1-L3 for 4k pages
                                    STAGE_1: begin

                                        // construct FINAL GPA
                                        gpaddr = {pte.ppn[riscv::GPPNW-1:0], iova_q[11:0]};
                                        // update according to the size of the page
                                        if (ptw_lvl_q == LVL2)
                                            gpaddr[20:0] = iova_q[20:0];
                                        if(ptw_lvl_q == LVL1)
                                            gpaddr[29:0] = iova_q[29:0];
                                        gpte_n = pte;                   // save GPA to update in TLB

                                        // If second-stage translation is enabled
                                        if (en_stage2_i) begin
                                            state_n = WAIT_GRANT;
                                            gptw_lvl_n = ptw_lvl_q;         // VS lvl = G lvl (for superpage cases)
                                            gpaddr_n = gpaddr;              // register FINAL GPA

                                            // Proceed with final second-stage translation
                                            ptw_stage_n = STAGE_2_FINAL;
                                            ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], gpaddr[riscv::SVX-1:30], 3'b0};
                                            ptw_lvl_n = LVL1;
                                        end

                                        // GPA is an IMSIC address (even if Stage 2 is disabled)
                                        if (gpaddr_is_imsic_addr) begin
                                            state_n = WAIT_GRANT;
                                            ptw_pptr_n = {msiptp_ppn_i, 12'b0} | {iommu_pkg::extract_imsic_num(pte.ppn[riscv::GPPNW-1:0], msi_addr_mask_i), 4'b0};
                                            msi_translation_n = 1'b1;
                                        end
                                    end

                                    // triggered when valid G-stage PTE is found, without being the last level of VS
                                    //# S2-L1 for 1G superpages, S2-L2 for 2M superpages and S2-L3 for 4K pages
                                    STAGE_2_INTERMED: begin
                                        state_n = WAIT_GRANT;
                                        ptw_stage_n = STAGE_1;
                                        ptw_lvl_n = gptw_lvl_q;     // equalized to avoid comparing two types of level
                                        pptr = {pte.ppn[riscv::GPPNW-1:0], gptw_pptr_q[11:0]};  // join lvlx PPN with lvlx GPA's offset
                                        // Consider case of superpages
                                        if (ptw_lvl_q == LVL2)
                                            pptr[20:0] = gptw_pptr_q[20:0];
                                        if(ptw_lvl_q == LVL1)
                                            pptr[29:0] = gptw_pptr_q[29:0];
                                        ptw_pptr_n = pptr;
                                    end
                                    default:;
                                endcase

                                //# Valid translation found (either 1G, 2M or 4K entry): Update IOTLB
                                // IOTLB is updated only if PTE checks are passed, 
                                // so that these checks do not need to be performed again on an IOTLB hit

                                // Do not update IOTLB for CDW implicit accesses
                                // When Stage 2 is disabled and the GPA (SPA) is an MSI address, IOTLB is not updated yet and
                                // MSI translation process is invoked
                                if ((ptw_stage_q == STAGE_2_FINAL) || (!en_stage2_i && !gpaddr_is_imsic_addr)) begin
                                        if (!cdw_implicit_access_q) update_o = 1'b1;
                                        else                        cdw_done_o = 1'b1;
                                end

                                // "(1): If i > 0 and pte.vpn[i − 1 : 0] != 0, this is a misaligned superpage."
                                // "     Stop and raise a page-fault exception corresponding to the original access type."
                                // "(2): When a virtual page is accessed and the A bit is clear, or is written and the D bit is clear,"
                                // "     a page-fault exception is raised."
                                // "(3): For G-stage address translation, all memory accesses are considered to be user-level accesses," 
                                // "     as though executed in U-mode."
                                if ((ptw_lvl_q == LVL1 && |pte.ppn[17:0] != 1'b0   ) ||       // 1G
                                    (ptw_lvl_q == LVL2 && |pte.ppn[8:0] != 1'b0    ) ||       // 2M
                                    (!pte.a || !pte.r || (is_store_i && !pte.d)    ) ||
                                    (ptw_stage_q != STAGE_1 && !pte.u              )) begin
                                    
                                    page_fault_n        = 1'b1;
                                    state_n             = PROPAGATE_ERROR;
                                    ptw_stage_n         = ptw_stage_q;
                                    update_o            = 1'b0;
                                    cdw_done_o          = 1'b0;
                                end

                                // TODO: Check user bit for second-stage translation
                            end
                            
                            //# non-leaf PTE
                            else begin
                                if (ptw_lvl_q == LVL1) begin
                                    // we are in the second level now
                                    ptw_lvl_n = LVL2;
                                    case (ptw_stage_q)

                                        //# S1-L1
                                        STAGE_1: begin
                                            if (en_stage2_i) begin
                                                ptw_stage_n = STAGE_2_INTERMED;
                                                gpte_n = pte;   // PTE representing the GPA base pointer
                                                gptw_lvl_n = LVL2;  // update VS level
                                                pptr = {pte.ppn, iova_q[29:21], 3'b0};     // join GPA base pointer with VPN[1] => GPA lvl2
                                                gptw_pptr_n = pptr;     // update GPA for new level
                                                ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                                                ptw_lvl_n = LVL1;       // restart G-stage level
                                            end else begin
                                                ptw_pptr_n = {pte.ppn, iova_q[29:21], 3'b0};
                                            end
                                        end

                                        //# S2-L1 (GPA_n)
                                        STAGE_2_INTERMED: begin
                                                ptw_pptr_n = {pte.ppn, gptw_pptr_q[29:21], 3'b0};   // pointer received from G-L1, to be used with GPPN[1]
                                        end

                                        //# S2-L1 (final GPA)
                                        STAGE_2_FINAL: begin
                                                ptw_pptr_n = {pte.ppn, gpaddr_q[29:21], 3'b0};
                                        end
                                        default:;
                                    endcase
                                end

                                if (ptw_lvl_q == LVL2) begin
                                    // here we received a pointer to the third level
                                    ptw_lvl_n  = LVL3;
                                    unique case (ptw_stage_q)

                                        //# S1-L2
                                        STAGE_1: begin
                                            if (en_stage2_i) begin
                                                ptw_stage_n = STAGE_2_INTERMED;
                                                gpte_n = pte;
                                                gptw_lvl_n = LVL3;
                                                pptr = {pte.ppn, iova_q[20:12], 3'b0};
                                                gptw_pptr_n = pptr;
                                                ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};
                                                ptw_lvl_n = LVL1;
                                            end else begin
                                                ptw_pptr_n = {pte.ppn, iova_q[20:12], 3'b0};
                                            end
                                        end

                                        //# S2-L2 (GPA_n)
                                        STAGE_2_INTERMED: begin
                                                ptw_pptr_n = {pte.ppn, gptw_pptr_q[20:12], 3'b0};   // pointer received from G-L2, to be used with GPPN[1]
                                        end

                                        //# S2-L2 (final GPA)
                                        STAGE_2_FINAL: begin
                                                ptw_pptr_n = {pte.ppn, gpaddr_q[20:12], 3'b0};
                                        end
                                        default:;
                                    endcase
                                end

                                state_n = WAIT_GRANT;

                                // "For non-leaf PTEs, the D, A, and U bits are reserved for future standard use."
                                // "Until their use is defined by a standard extension, they MUST be cleared by software for forward compatibility."
                                if(pte.a || pte.d || pte.u) begin
                                    page_fault_n    = 1'b1;
                                    state_n = PROPAGATE_ERROR;
                                    ptw_stage_n = ptw_stage_q;
                                end

                                //  "Otherwise, this PTE is a pointer to the next level of the page table. Let i = i − 1."
                                //  "If i < 0, stop and raise a page-fault exception corresponding to the original access type."
                                if (ptw_lvl_q == LVL3) begin
                                    page_fault_n    = 1'b1;
                                    state_n = PROPAGATE_ERROR;
                                    ptw_stage_n = ptw_stage_q;
                                end
                            end
                        end

                        // Bits [63:54] are reserved for standard use and must be cleared by SW if the corresponding extension is not implemented
                        // Svnapot and Svpbmt are not implemented
                        if ((|pte.reserved) != 1'b0) begin
                            page_fault_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;  // GPPN bits [44:29] MUST be all zero
                            ptw_stage_n     = ptw_stage_q;
                            update_o        = 1'b0;
                            cdw_done_o      = 1'b0;
                        end

                        // "For Sv39x4 (...) GPA's bits 63:41 must all be zeros, or else a guest-page-fault exception occurs."
                        if (ptw_stage_q == STAGE_1 && (|pte.ppn[riscv::PPNW-1:riscv::GPPNW]) != 1'b0) begin
                            page_fault_n    = 1'b1;
                            state_n         = PROPAGATE_ERROR;  // GPPN bits [44:29] MUST be all zero
                            ptw_stage_n     = STAGE_2_INTERMED;    // to throw guest page fault
                            update_o        = 1'b0;
                            cdw_done_o      = 1'b0;
                        end
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
                        cause_n = iommu_pkg::PT_DATA_CORRUPTION;
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
                if (page_fault_q) begin
                    if (ptw_stage_q != STAGE_1) begin
                        ptw_error_stage2_o   = 1'b1;
                        if (is_store_i) cause_code_o = iommu_pkg::STORE_GUEST_PAGE_FAULT;
                        else            cause_code_o = iommu_pkg::LOAD_GUEST_PAGE_FAULT;
                    end
                    else begin
                        if (is_store_i) cause_code_o = iommu_pkg::STORE_PAGE_FAULT;
                        else            cause_code_o = iommu_pkg::LOAD_PAGE_FAULT;
                    end
                end
                else cause_code_o = cause_q;
                ptw_error_stage2_int_o = (ptw_stage_q == STAGE_2_INTERMED) ? 1'b1 : 1'b0;
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
            ptw_lvl_q               <= LVL1;
            gptw_lvl_q              <= LVL1;
            iotlb_update_pscid_q    <= '0;
            iotlb_update_gscid_q    <= '0;
            iova_q                  <= '0;
            gpaddr_q                <= '0;
            ptw_pptr_q              <= '0;
            gptw_pptr_q             <= '0;
            global_mapping_q        <= 1'b0;
            msi_translation_q       <= 1'b0;
            gpte_q                  <= '0;
            cause_q                 <= '0;
            cdw_implicit_access_q   <= 1'b0;
            page_fault_q            <= 1'b0;

        end else begin
            state_q                 <= state_n;
            ptw_stage_q             <= ptw_stage_n;
            ptw_pptr_q              <= ptw_pptr_n;
            gptw_pptr_q             <= gptw_pptr_n;
            ptw_lvl_q               <= ptw_lvl_n;
            gptw_lvl_q              <= gptw_lvl_n;
            iotlb_update_pscid_q    <= iotlb_update_pscid_n;
            iotlb_update_gscid_q    <= iotlb_update_gscid_n;
            iova_q                  <= iova_n;
            gpaddr_q                <= gpaddr_n;
            global_mapping_q        <= global_mapping_n;
            msi_translation_q       <= msi_translation_n;
            gpte_q                  <= gpte_n;
            cause_q                 <= cause_n;
            cdw_implicit_access_q   <= cdw_implicit_access_n;
            page_fault_q            <= page_fault_n;
        end
    end

endmodule

/* verilator lint_on WIDTH */
