// Copyright (c) 2022 University of Minho
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

//# Disabled verilator_lint_off WIDTH

module iommu_ptw_sv39x4 import ariane_pkg::*; #(
        parameter int PSCID_WIDTH = 1,
        parameter int GSCID_WIDTH = 1,
        parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Error signaling
    output logic                    ptw_active_o,           // Set when PTW is walking memory
    output logic                    ptw_error_o,            // set when an error occurred (excluding access errors)
    output logic                    ptw_error_stage2_o,     // set when the fault occurred in stage 2
    output logic                    ptw_error_stage2_int_o, // set when an error occurred in stage 2 during stage 1 translation
    output logic                    ptw_iopmp_excep_o,      // set when an (IO)PMP access exception occured
    // TODO: Integrate IOPMP developed by ETH

    input  logic                    en_stage1_i,            // Enable signal for stage 1 translation. Defined by DC/PC
    input  logic                    en_stage2_i,            // Enable signal for stage 2 translation. Defined by DC only
    input  logic                    is_store_i,             // Indicate whether this translation was triggered by a store or a load

    // PTW memory interface
    input  dcache_req_o_t           mem_resp_i,             // Response port from memory
    output dcache_req_i_t           mem_req_o,              // Request port to memory

    // to IOTLB, update logic
    // TODO: Update signals will be grouped in a packed struct after validation with cocotb
    output  logic                    update_o,
    output  logic                    up_is_s_2M_o,
    output  logic                    up_is_s_1G_o,
    output  logic                    up_is_g_2M_o,
    output  logic                    up_is_g_1G_o,
    output  logic [riscv::GPPNW-1:0] up_vpn_o,
    output  logic [PSCID_WIDTH-1:0]  up_pscid_o,
    output  logic [GSCID_WIDTH-1:0]  up_gscid_o,
    output riscv::pte_t              up_content_o,
    output riscv::pte_t              up_g_content_o,

    // output tlb_update_sv39x4_t      itlb_update_o,
    // output tlb_update_sv39x4_t      dtlb_update_o,

    output logic [riscv::VLEN-1:0]  iotlb_update_iova_o,

    // from DC/PC
    input  logic [PSCID_WIDTH-1:0]   pscid_i,
    input  logic [GSCID_WIDTH-1:0]   gscid_i,
    
    // permission checks (//? I think should be performed outside the PTW)
    // input  logic                     sum_i,         // Supervisor Memory Access for User pages
    // input  logic [1:0]               priv_mode_i,   // transaction privilege mode
    //? I think ENS bit checking should be performed by external translation logic since it has nothing to do with PTEs

    // from IOTLB, to monitor misses
    input  logic                    iotlb_access_i,
    input  logic                    iotlb_hit_i,
    input  logic [riscv::VLEN-1:0]  req_iova_i,

    // from DC/PC file
    input  logic [riscv::PPNW-1:0]  iosatp_ppn_i,  // ppn from iosatp
    input  logic [riscv::PPNW-1:0]  iohgatp_ppn_i, // ppn from iohgatp

    /*
    The MXR (Make eXecutable Readable) bit modifies the privilege with which loads access virtual memory. 
    When MXR=0, only loads from pages marked readable will succeed. When MXR=1, loads from pages marked 
    either readable or executable (R=1 or X=1) will succeed.

    The SUM (permit Supervisor User Memory access) bit modifies the privilege with which S-mode
    loads and stores access virtual memory. When SUM=0, S-mode memory accesses to pages that are
    accessible by U-mode will fault. When SUM=1, these accesses are permitted.
    Note that S-mode can never execute instructions from user pages, regardless of the state of SUM.
    */
    input  logic                    mxr_i,
    input  logic                    vmxr_i,

    // TODO: include HPM
    // // Performance counters
    // output logic                    itlb_miss_o,
    // output logic                    dtlb_miss_o,

    // (IO)PMP
    input  riscv::pmpcfg_t [15:0]   pmpcfg_i,
    input  logic [15:0][riscv::PLEN-3:0] pmpaddr_i,
    output logic [riscv::GPLEN-1:0] bad_gpaddr_o
);

    // input registers to receive data from memory i guess
    logic data_rvalid_q;
    logic [63:0] data_rdata_q;

    riscv::pte_t pte;
    // register to perform context switch between stages
    riscv::pte_t gpte_q, gpte_d;    // gpte is only used to store GPA to be updated in the IOTLB
    assign pte = riscv::pte_t'(data_rdata_q);

    // PTW states
    enum logic[2:0] {
      IDLE,
      WAIT_GRANT,
      PTE_LOOKUP,
      PROPAGATE_ERROR,
      PROPAGATE_ACCESS_ERROR
    } state_q, state_d;

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
    } ptw_stage_q, ptw_stage_d;

    // global mapping aux signal
    logic global_mapping_q, global_mapping_n;
    // latched tag signal
    logic tag_valid_n,      tag_valid_q;
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

    // Assignments
    assign iotlb_update_iova_o  = iova_q;
    // PTW walking
    assign ptw_active_o    = (state_q != IDLE);
    // directly output the correct physical address
    assign mem_req_o.address_index = ptw_pptr_q[DCACHE_INDEX_WIDTH-1:0];
    assign mem_req_o.address_tag   = ptw_pptr_q[DCACHE_INDEX_WIDTH+DCACHE_TAG_WIDTH-1:DCACHE_INDEX_WIDTH];
    // we are never going to kill this request
    assign mem_req_o.kill_req      = '0;
    // we are never going to write with the HPTW
    assign mem_req_o.data_wdata    = 64'b0;

    //# IOTLB Update combinational logic
    always_comb begin : iotlb_update
        
        // vpn to be updated in the IOTLB
        up_vpn_o = {{41-riscv::SVX{1'b0}}, iova_q[riscv::SVX-1:12]};

        // update page size in the IOTLB according to the level where the leaf PTE was found
        // LVL3 is 4K, LVL2 is 2M, LVL1 is 1G
        if(en_stage2_i && en_stage1_i) begin    // two-stage enabled
            up_is_s_2M_o = (gptw_lvl_q == LVL2);
            up_is_s_1G_o = (gptw_lvl_q == LVL1);
            up_is_g_2M_o = (ptw_lvl_q == LVL2);
            up_is_g_1G_o = (ptw_lvl_q == LVL1);
        end
        else if(en_stage1_i) begin              // stage 1 only
            up_is_s_2M_o = (ptw_lvl_q == LVL2);
            up_is_s_1G_o = (ptw_lvl_q == LVL1);
            up_is_g_2M_o = 1'b0;
            up_is_g_1G_o = 1'b0;
        end 
        else begin                              // stage 2 only
            up_is_s_2M_o = 1'b0;
            up_is_s_1G_o = 1'b0;
            up_is_g_2M_o = (ptw_lvl_q == LVL2);
            up_is_g_1G_o = (ptw_lvl_q == LVL1);
        end

        // Originally two ASIDs were considered: asid and vs_asid
        up_pscid_o = iotlb_update_pscid_q;

        // GSCID to be updated
        up_gscid_o = iotlb_update_gscid_q;

        // set the global mapping bit
        //? Why set the global bit again?
        if(en_stage2_i) begin   // if stage 2 is enabled
            up_content_o = gpte_q | (global_mapping_q << 5);
            up_g_content_o = pte;
        end else begin          // stage 2 disabled
            up_content_o = pte | (global_mapping_q << 5);
            up_g_content_o = '0;
        end
    end

    // data memory request port
    assign mem_req_o.tag_valid      = tag_valid_q;

    logic allow_access;

    // G stage error occurs whenever ptw_stage_q != STAGE_1 in the PROP_ERR state
    assign bad_gpaddr_o = ptw_error_stage2_o ? ((ptw_stage_q == STAGE_2_INTERMED) ? gptw_pptr_q[riscv::GPLEN:0] : gpaddr_q) : 'b0;

    // TODO: Insert ETH IOPMP
    pmp #(
        .PLEN       ( riscv::PLEN            ),
        .PMP_LEN    ( riscv::PLEN - 2        ),
        .NR_ENTRIES ( ArianeCfg.NrPMPEntries )
    ) i_pmp_ptw (
        .addr_i        ( ptw_pptr_q         ),
        // PTW access are always checked as if in S-Mode...
        .priv_lvl_i    ( riscv::PRIV_LVL_S  ),
        // ...and they are always loads
        .access_type_i ( riscv::ACCESS_READ ),
        // Configuration
        .conf_addr_i   ( pmpaddr_i          ),
        .conf_i        ( pmpcfg_i           ),
        .allow_o       ( allow_access       )
    );

    //# Page table walker
    always_comb begin : ptw
        automatic logic [riscv::PLEN-1:0] pptr;
        automatic logic [riscv::GPLEN-1:0] gpaddr;
        // default assignments
        // PTW memory interface
        tag_valid_n            = 1'b0;
        mem_req_o.data_req     = 1'b0;
        mem_req_o.data_be      = 8'hFF;
        mem_req_o.data_size    = 2'b11;
        mem_req_o.data_we      = 1'b0;
        ptw_error_o            = 1'b0;
        ptw_error_stage2_o     = 1'b0;
        ptw_error_stage2_int_o = 1'b0;
        ptw_iopmp_excep_o      = 1'b0;
        update_o               = 1'b0;
        ptw_lvl_n              = ptw_lvl_q;
        gptw_lvl_n             = gptw_lvl_q;
        ptw_pptr_n             = ptw_pptr_q;
        gptw_pptr_n            = gptw_pptr_q;
        state_d                = state_q;
        ptw_stage_d            = ptw_stage_q;
        gpte_d                 = gpte_q;
        global_mapping_n       = global_mapping_q;

        // input registers
        iotlb_update_pscid_n   = iotlb_update_pscid_q;
        iotlb_update_gscid_n   = iotlb_update_gscid_q;
        iova_n                 = iova_q;
        gpaddr_n               = gpaddr_q;
        pptr                   = ptw_pptr_q;
        gpaddr                 = gpaddr_q;

        // itlb_miss_o           = 1'b0;
        // dtlb_miss_o           = 1'b0;

        case (state_q)

            // check for possible misses to trigger PTW
            IDLE: begin
                // by default we start with the top-most page table
                ptw_lvl_n        = LVL1;
                gptw_lvl_n       = LVL1;
                global_mapping_n = 1'b0;
                gpaddr_n         = '0;
                gpte_d           = '0;

                // check for possible IOTLB miss
                if ((en_stage1_i | en_stage2_i) & iotlb_access_i & ~iotlb_hit_i) begin
                    if (en_stage1_i && en_stage2_i) begin   // VS && G
                        // Start in G-L1
                        ptw_stage_d = STAGE_2_INTERMED;
                        // Store GPA to be segmented for all three levels of G-stage translation
                        pptr = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};   //* VS-L1
                        gptw_pptr_n = pptr;
                        // Load memory pointer with hgatp and GPPN[2] to access physical memory
                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], pptr[riscv::SVX-1:30], 3'b0};

                    end else if (!en_stage1_i && en_stage2_i) begin     // G only
                        // Start in final G-L1 stage
                        ptw_stage_d = STAGE_2_FINAL;
                        gpaddr_n = req_iova_i[riscv::SVX-1:0]; // virtual address is a valid GPA
                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], req_iova_i[riscv::SVX-1:30], 3'b0};

                    end else begin                      // S/VS only
                        ptw_stage_d = STAGE_1;
                        ptw_pptr_n  = {iosatp_ppn_i, req_iova_i[riscv::SV-1:30], 3'b0};
                    end
                    // register PSCID, GSCID and IOVA
                    iotlb_update_pscid_n   = pscid_i;
                    iotlb_update_gscid_n   = gscid_i;
                    iova_n                 = req_iova_i;
                    state_d                = WAIT_GRANT;
                    // iotlb_miss_o        = 1'b1;     // to HPM
                end
            end

            // perform memory access with address hold in ptw_pptr_q
            WAIT_GRANT: begin
                // send request to memory
                mem_req_o.data_req = 1'b1;
                // wait for the WAIT_GRANT
                if (mem_resp_i.data_gnt) begin
                    // send the tag valid signal to request bus, one cycle later
                    tag_valid_n = 1'b1;
                    state_d     = PTE_LOOKUP;
                end
            end

            // process the incoming memory data (hold in pte)
            PTE_LOOKUP: begin
                // we wait for the valid signal
                if (data_rvalid_q) begin

                    // check if the global mapping bit is set
                    if (pte.g && ptw_stage_q == STAGE_1)
                        global_mapping_n = 1'b1;

                    //# Invalid PTE
                    // If pte.v = 0, or if pte.r = 0 and pte.w = 1, stop and raise a page-fault exception.
                    if (!pte.v || (!pte.r && pte.w))
                        state_d = PROPAGATE_ERROR;
                        

                    //# Valid PTE
                    else begin
                        state_d = IDLE;

                        //# Leaf PTE
                        if (pte.r || pte.x) begin
                            case (ptw_stage_q)
                                
                                //# S1-L1 for 1G superpages, S1-L2 for 2M superpages and S1-L3 for 4k pages
                                STAGE_1: begin
                                    // If corresponding G stage translation is enabled
                                    if (en_stage2_i) begin
                                        state_d = WAIT_GRANT;
                                        ptw_stage_d = STAGE_2_FINAL;    // final stage-2 walk
                                        gpte_d = pte;                   // save GPA to update in TLB
                                        gptw_lvl_n = ptw_lvl_q;         // VS lvl = G lvl (for superpage cases)
                                        gpaddr = {pte.ppn[riscv::GPPNW-1:0], iova_q[11:0]};    // construct FINAL GPA
                                        // update according to the size of the page (LVL3 = 4K page)
                                        if (ptw_lvl_q == LVL2)
                                            gpaddr[20:0] = iova_q[20:0];
                                        if(ptw_lvl_q == LVL1)
                                            gpaddr[29:0] = iova_q[29:0];
                                        gpaddr_n = gpaddr;              // register FINAL GPA

                                        // Set memory address ptr for last G-stage walk
                                        ptw_pptr_n = {iohgatp_ppn_i[riscv::PPNW-1:2], gpaddr[riscv::SVX-1:30], 3'b0};     // 
                                        ptw_lvl_n = LVL1;       // register PTW level
                                    end
                                end

                                // triggered when valid G-stage PTE is found, without being the last level of VS
                                //# S2-L1 for 1G superpages, S2-L2 for 2M superpages and S2-L3 for 4K pages
                                STAGE_2_INTERMED: begin
                                    state_d = WAIT_GRANT;
                                    ptw_stage_d = STAGE_1;
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

                            //# Valid translation found (either 1G, 2M or 4K entry)

                            //# Update IOTLB
                            //? I think the HW PTW should be only responsible of locating the missing SPA (PTE) associated with the IOVA that caused the miss in the IOTLB.
                            // IOTLB is updated only if found a leaf PTE in the final stage-2, or if stage 2 is disabled and a leaf PTE was found

                            // "If i > 0 and pte.vpn[i − 1 : 0] != 0, this is a misaligned superpage."
                            // "Stop and raise a page-fault exception corresponding to the original access type."
                            if (ptw_lvl_q == LVL1 && pte.ppn[17:0] != '0) begin         // 1G
                                state_d             = PROPAGATE_ERROR;
                                ptw_stage_d         = ptw_stage_q;
                                update_o = 1'b0;
                            end 
                            else begin
                                if (ptw_lvl_q == LVL2 && pte.ppn[8:0] != '0) begin      // 2M
                                state_d             = PROPAGATE_ERROR;
                                ptw_stage_d         = ptw_stage_q;
                                update_o = 1'b0;
                                end
                                else if((ptw_stage_q == STAGE_2_FINAL) || !en_stage2_i) begin
                                    update_o = 1'b1;
                                end
                            end

                        //     // TODO: For now we let SW handle the update of A and D bits. Later, hardware support will be implemented
                        //     /*
                        //         A fault is generated if:
                        //             - Access flag is not set;
                        //             - Page is not readable;
                        //             - S-mode transaction. PTE has U=1 and SUM=0;
                        //             - S-mode transaction. PTE has U=1 and x=1;
                        //     */
                        //     if (!pte.a || !pte.r || (priv_mode_i == riscv::PRIV_LVL_S && pte.u && (!sum_i || pte.x))) begin
                        //         state_d   = PROPAGATE_ERROR;
                        //         ptw_stage_d = ptw_stage_q;
                        //     end else begin
                        //         if((ptw_stage_q == STAGE_2_FINAL) || !en_stage2_i)
                        //             update_o = 1'b1;
                        //     end
                        //     // Request is a store: perform some additional checks
                        //     // If the request was a store and the page is not write-able, raise an error
                        //     // the same applies if the dirty flag is not set (for now...)
                        //     if (is_store && (!pte.w || !pte.d)) begin
                        //         dtlb_update_o.valid = 1'b0;
                        //         state_d   = PROPAGATE_ERROR;
                        //         ptw_stage_d = ptw_stage_q;
                        //     end

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
                                            ptw_stage_d = STAGE_2_INTERMED;
                                            gpte_d = pte;   // PTE representing the GPA base pointer
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
                                endcase
                            end

                            if (ptw_lvl_q == LVL2) begin
                                // here we received a pointer to the third level
                                ptw_lvl_n  = LVL3;
                                unique case (ptw_stage_q)

                                    //# S1-L2
                                    STAGE_1: begin
                                        if (en_stage2_i) begin
                                            ptw_stage_d = STAGE_2_INTERMED;
                                            gpte_d = pte;
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

                            state_d = WAIT_GRANT;

                            // "For non-leaf PTEs, the D, A, and U bits are reserved for future standard use."
                            // "Until their use is defined by a standard extension, they MUST be cleared by software for forward compatibility."
                            if(pte.a || pte.d || pte.u) begin
                                state_d = PROPAGATE_ERROR;
                                ptw_stage_d = ptw_stage_q;
                            end

                            //  "Otherwise, this PTE is a pointer to the next level of the page table."
                            //  "Let i = i − 1. If i < 0, stop and raise a page-fault exception corresponding to the original access type."
                            if (ptw_lvl_q == LVL3) begin
                              // Should already be the last level page table => Error
                              ptw_lvl_n   = LVL3;
                              state_d = PROPAGATE_ERROR;
                              ptw_stage_d = ptw_stage_q;
                            end
                        end
                    end

                    // "For Sv39x4 (...) GPA's bits 63:41 must all be zeros, or else a guest-page-fault exception occurs."
                    if (ptw_stage_q == STAGE_1 && (|pte.ppn[riscv::PPNW-1:riscv::GPPNW]) != 1'b0) begin
                        state_d = PROPAGATE_ERROR;  // GPPN bits [44:29] MUST be all zero
                        ptw_stage_d = ptw_stage_q;
                        update_o = 1'b0;
                    end

                    // Check if this access was actually allowed from a PMP perspective
                    if (!allow_access) begin
                        update_o = 1'b0;
                        // we have to return the failed address in bad_addr
                        ptw_pptr_n = ptw_pptr_q;
                        ptw_stage_d = ptw_stage_q;
                        state_d = PROPAGATE_ACCESS_ERROR;
                    end
                end
            end

            // Propagate error to MMU/LSU
            PROPAGATE_ERROR: begin
                state_d     = IDLE;
                ptw_error_o = 1'b1;
                ptw_error_stage2_o   = (ptw_stage_q != STAGE_1) ? 1'b1 : 1'b0;
                ptw_error_stage2_int_o = (ptw_stage_q == STAGE_2_INTERMED) ? 1'b1 : 1'b0;
            end

            PROPAGATE_ACCESS_ERROR: begin
                state_d     = IDLE;
                ptw_iopmp_excep_o = 1'b1;
            end

            default: begin
                state_d = IDLE;
            end
        endcase
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q            <= IDLE;
            ptw_stage_q        <= STAGE_1;
            ptw_lvl_q          <= LVL1;
            gptw_lvl_q         <= LVL1;
            tag_valid_q        <= 1'b0;
            iotlb_update_pscid_q  <= '0;
            iotlb_update_gscid_q  <= '0;
            iova_q            <= '0;
            gpaddr_q           <= '0;
            ptw_pptr_q         <= '0;
            gptw_pptr_q        <= '0;
            global_mapping_q   <= 1'b0;
            data_rdata_q       <= '0;
            gpte_q             <= '0;
            data_rvalid_q      <= 1'b0;

        end else begin
            state_q            <= state_d;
            ptw_stage_q        <= ptw_stage_d;
            ptw_pptr_q         <= ptw_pptr_n;
            gptw_pptr_q        <= gptw_pptr_n;
            ptw_lvl_q          <= ptw_lvl_n;
            gptw_lvl_q         <= gptw_lvl_n;
            tag_valid_q        <= tag_valid_n;
            iotlb_update_pscid_q  <= iotlb_update_pscid_n;
            iotlb_update_gscid_q  <= iotlb_update_gscid_n;
            iova_q            <= iova_n;
            gpaddr_q           <= gpaddr_n;
            global_mapping_q   <= global_mapping_n;
            data_rdata_q       <= mem_resp_i.data_rdata;
            gpte_q             <= gpte_d;
            data_rvalid_q      <= mem_resp_i.data_rvalid;
        end
    end

endmodule
//# Disabled verilator_lint_on WIDTH
