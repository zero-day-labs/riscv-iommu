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
// Author:  Manuel Rodríguez <manuel.cederog@gmail.com>
// Date:    07/12/2023
//
// Description: RISC-V IOMMU MSI Page Table Walker.
//              Fetches and validates MSI PTEs in FLAT mode or MRIF mode.
//              For MSI PTEs in flat mode, it updates the IOTLB.
//              For MSI PTEs in MRIF mode, it updates the MRIF cache.
//

/*
    -   This module integrates MSI FLAT logic and MSI MRIF logic in a decoupled manner. Two FSMs:
            MSI-FLAT and MSI-MRIF, each with one combinational logic block and one sequential logic block.
    -   The first FSM (MSI-FLAT) fetches and validates the first 64 bits of MSI PTEs.
            If the MSI PTE is in FLAT mode, the FSM updates the IOTLB with the fetched PTE and the first-stage 
            data provided by the PTW, if is the case. The it goes back to IDLE. 
            The second beat of the AXI transfer is ignored (RREADY must remain set one cycle)
    -   If the MSI PTE is in MRIF mode, the MSI-FLAT FSM sets a signal to trigger the MSI-MRIF FSM.
            When triggered, the MSI-MRIF FSM validates the 128 bits of the MSI PTE and the address of the access.
            Some of the PT checks do not raise translation faults when failed. The transaction is simply discarded.
            If all checks are OK, the FSM updates the MRIF cache.
*/

module rv_iommu_msiptw #(

    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans    = rv_iommu::MSI_DISABLED,

    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
) (
    input  logic    clk_i,                  // Clock
    input  logic    rst_ni,                 // Asynchronous reset active low

    // Memory interface
    input  axi_rsp_t    mem_resp_i,
    output axi_req_t    mem_req_o,

    // Trigger MSI translation
    input  logic init_msi_trans_i,
    // MSI PTW is active
    output logic msiptw_active_o,
    // Abort access (discard without fault)
    output logic ignore_o,

    // Request IOVA
    input  logic [riscv::VLEN-1:0]      req_iova_i,
    // First-stage translation enable
    input  logic                        en_1S_i,
    // The translation is read-for-execute
    input  logic                        is_rx_i,

    // First-stage data provided by PTW
    input  logic [(riscv::GPPNW-1):0]   vpn_i,
    input  logic [19:0]                 pscid_i,
    input  logic [15:0]                 gscid_i,
    input  logic                        is_1S_2M_i,
    input  logic                        is_1S_1G_i,
    input  riscv::pte_t                 gpte_i,

    // MSI PT base PPN
    input  logic [(riscv::PPNW-1):0]    msiptp_ppn_i,
    // MSI address mask
    input  logic [riscv::GPPNW-1:0]     msi_addr_mask_i,

    // Generic update ports
    output logic [(riscv::GPPNW-1):0]   vpn_o,
    output logic [19:0]                 pscid_o,
    output logic [15:0]                 gscid_o,
    output logic                        is_1S_2M_o,
    output logic                        is_1S_1G_o,
    output riscv::pte_t                 content_1S_o,

    // IOTLB update ports
    output logic                        iotlb_update_o,
    output rv_iommu::msi_pte_flat_t     iotlb_msi_content_o,

    // MRIFC update ports
    output logic                        mrifc_update_o,
    output rv_iommu::mrifc_entry_t      mrifc_msi_content_o,

    // Error signaling
    output logic                                error_o,
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_o
);

    // States
    // MSI-FLAT FSM
    typedef enum logic[1:0] {
        IDLE,             // 000
        MEM_ACCESS,       // 001
        FLAT_PROC_PTE,    // 010
        FLAT_ERROR        // 011
    } state_flat_t;
    state_flat_t flat_state_q, flat_state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] pptr_q, pptr_n;

    // To cast input memory port to MSI PTE data
    // MSI-FLAT
    rv_iommu::msi_pte_flat_t msi_pte_flat;
    assign msi_pte_flat = rv_iommu::msi_pte_flat_t'(mem_resp_i.r.data);

    // Fault code
    logic [(rv_iommu::CAUSE_LEN-1):0] flat_cause_q, flat_cause_n;

    // To know whether we have to wait for the AXI transaction to complete on errors
    logic flat_wait_rlast_q, flat_wait_rlast_n;

    // Trigger MRIF-MSI FSM
    logic init_msi_mrif;

    // Registers to propagate first-stage data
    logic [(riscv::GPPNW-1):0]   vpn_q,         vpn_n;
    logic [19:0]                 pscid_q,       pscid_n;
    logic [15:0]                 gscid_q,       gscid_n;
    logic                        is_1S_2M_q,    is_1S_2M_n;
    logic                        is_1S_1G_q,    is_1S_1G_n;
    riscv::pte_t                 gpte_q,        gpte_n;

    // Generic update ports
    assign vpn_o          = vpn_q;
    assign pscid_o        = pscid_q;
    assign gscid_o        = gscid_q;
    assign is_1S_2M_o     = is_1S_2M_q;
    assign is_1S_1G_o     = is_1S_1G_q;
    assign content_1S_o   = gpte_q;

    // IOTLB update ports
    assign iotlb_msi_content_o  = msi_pte_flat;

    //# MSI-FLAT Combinational Block
    always_comb begin : flat_comb

        // Default assignments
        // Wires
        init_msi_mrif   = 1'b0;

        // Output signals
        // AXI signals
        // AW
        mem_req_o.aw.id      = 4'b0011;
        mem_req_o.aw.addr    = '0;
        mem_req_o.aw.len     = 8'b0;
        mem_req_o.aw.size    = 3'b011;
        mem_req_o.aw.burst   = axi_pkg::BURST_INCR;
        mem_req_o.aw.lock    = '0;
        mem_req_o.aw.cache   = '0;
        mem_req_o.aw.prot    = '0;
        mem_req_o.aw.qos     = '0;
        mem_req_o.aw.region  = '0;
        mem_req_o.aw.atop    = '0;
        mem_req_o.aw.user    = '0;

        mem_req_o.aw_valid    = 1'b0;

        // W
        mem_req_o.w.data     = '0;
        mem_req_o.w.strb     = '0;
        mem_req_o.w.last     = '0;
        mem_req_o.w.user     = '0;

        mem_req_o.w_valid    = 1'b0;

        // B
        mem_req_o.b_ready    = 1'b0;

        // AR
        mem_req_o.ar.id      = 4'b0011;
        mem_req_o.ar.addr    = {{riscv::XLEN-riscv::PLEN{1'b0}}, pptr_q};   // Physical address to access
        mem_req_o.ar.len     = 8'b1;                                        // Two beats
        mem_req_o.ar.size    = 3'b011;                                      // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst   = axi_pkg::BURST_INCR;                         // Incremental addresses
        mem_req_o.ar.lock    = '0;
        mem_req_o.ar.cache   = '0;
        mem_req_o.ar.prot    = '0;
        mem_req_o.ar.qos     = '0;
        mem_req_o.ar.region  = '0;
        mem_req_o.ar.user    = '0;

        mem_req_o.ar_valid  = 1'b0;

        // R
        mem_req_o.r_ready   = 1'b1;

        iotlb_update_o      = 1'b0;

        // Next values
        pptr_n              = pptr_q;
        flat_state_n        = flat_state_q;
        flat_wait_rlast_n   = flat_wait_rlast_q;
        flat_cause_n        = flat_cause_q;
        vpn_n               = vpn_q;
        pscid_n             = pscid_q;
        gscid_n             = gscid_q;
        is_1S_2M_n          = is_1S_2M_q;
        is_1S_1G_n          = is_1S_1G_q;
        gpte_n              = gpte_q;

        case (flat_state_q)

            // Wait for an external signal coming from translation logic to indicate that an MSI translation must be performed
            // When triggered, update the physical pointer with the address of the MSI PTE
            IDLE: begin

                flat_wait_rlast_n   = 1'b0;
                
                // Translation logic requested MSI translation
                if (init_msi_trans_i && !msiptw_active_o) begin

                    // "If the transaction is an Untranslated or Translated read-for-execute"
                    // "then stop and report Instruction access fault (cause = 1)."
                    if (is_rx_i) begin
                        flat_cause_n = rv_iommu::INSTR_ACCESS_FAULT;
                        flat_state_n = FLAT_ERROR;
                    end

                    // Set pptr and propagate first-stage data
                    else begin
                        
                        // First-stage translation enabled. Tags come from PTW. Propagate first-stage data
                        if (en_1S_i) begin
                            
                            automatic logic [riscv::GPPNW-1:0] imsic_num;
                            imsic_num = rv_iommu::extract_imsic_num(gpte_i.ppn[(riscv::GPPNW-1):0], msi_addr_mask_i);

                            pptr_n      = {msiptp_ppn_i, 12'b0} | 
                                            ({{riscv::PLEN-riscv::GPPNW{1'b0}}, imsic_num} << 4);

                            // First-stage parameters
                            vpn_n       = vpn_i;        // GVA
                            is_1S_2M_n  = is_1S_2M_i;
                            is_1S_1G_n  = is_1S_1G_i;
                            gpte_n      = gpte_i;
                        end
                        
                        // First-stage translation disabled. Tags come directly from translation logic
                        else begin
                            
                            automatic logic [riscv::GPPNW-1:0] imsic_num;
                            imsic_num = rv_iommu::extract_imsic_num(req_iova_i[(riscv::GPLEN-1):12], msi_addr_mask_i);

                            pptr_n      = {msiptp_ppn_i, 12'b0} | 
                                            ({{riscv::PLEN-riscv::GPPNW{1'b0}}, imsic_num} << 4);

                            // First-stage parameters
                            vpn_n       = req_iova_i[(riscv::GPLEN-1):12];  // GPA
                            is_1S_2M_n  = 1'b0;
                            is_1S_1G_n  = 1'b0;
                            gpte_n      = '0;
                        end
                        
                        pscid_n         = pscid_i;
                        gscid_n         = gscid_i;

                        flat_state_n    = MEM_ACCESS;
                    end
                end
            end

            // Access memory to fetch MSI PTE (2 x 64 bits)
            MEM_ACCESS: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;
                
                // wait for AXI Bus to accept the request
                if (mem_resp_i.ar_ready) begin
                    flat_state_n = FLAT_PROC_PTE;
                end
            end

            // Validate MSI PTE and check for errors.
            // If PTE is in FLAT mode, check reserved fields and update IOTLB.
            // If PTE is in MRIF mode, trigger MSI-MRIF FSM.
            FLAT_PROC_PTE: begin
                
                // wait for RVALID to start reading
                if (mem_resp_i.r_valid) begin

                    flat_wait_rlast_n   = 1'b1;

                    // "If msipte.V == 0, then stop and report "MSI PTE not valid" (cause = 262)"
                    // This implementation only supports standard MSI PTE formats (msi_pte.c = 0)
                    if (!msi_pte_flat.v || msi_pte_flat.c) begin
                        flat_cause_n = rv_iommu::MSI_PTE_INVALID;
                        flat_state_n = FLAT_ERROR;
                    end

                    // Check for AXI errors
                    else if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        flat_cause_n = rv_iommu::MSI_PT_DATA_CORRUPTION;
                        flat_state_n = FLAT_ERROR;
                    end

                    // Valid MSI PTE
                    else begin

                        // Parse MSI PTE mode
                        case (msi_pte_flat.m)

                            // MRIF mode: Check for support and trigger MRIF handler
                            rv_iommu::MRIF: begin

                                // MRIF support included
                                if (MSITrans == rv_iommu::MSI_FLAT_MRIF) begin
                                    // trigger MSI-MRIF FSM
                                    init_msi_mrif       = 1'b1;
                                    flat_wait_rlast_n   = 1'b0;
                                    flat_state_n        = IDLE;
                                end

                                // MRIF support NOT included: raise fault
                                else begin
                                    flat_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                    flat_state_n = FLAT_ERROR;
                                end
                            end 

                            // FLAT mode: Validate PTE and update IOTLB
                            rv_iommu::FLAT: begin
                                
                                // "If any bits or encoding that are reserved for future standard use are set within msipte," 
                                // "stop and report "MSI PTE misconfigured" (cause = 263)."
                                if ((|msi_pte_flat.__rsv_1) || (|msi_pte_flat.__rsv_2)) begin
                                    flat_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                    flat_state_n = FLAT_ERROR;
                                end

                                // Update IOTLB and go to IDLE
                                else begin
                                    iotlb_update_o      = 1'b1;
                                    flat_wait_rlast_n   = 1'b0;
                                    flat_state_n        = IDLE;
                                end
                            end 

                            // reserved modes (fault)
                            default: begin
                                flat_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                                flat_state_n = FLAT_ERROR;
                            end
                        endcase
                    end
                end
            end

            // Propagate error code to the translation logic
            FLAT_ERROR: begin

                // Check whether we have to wait for AXI transmission to end
                if ((flat_wait_rlast_q && mem_resp_i.r.last) || !flat_wait_rlast_q) begin
                    flat_state_n = IDLE;
                end
            end
        endcase
    end : flat_comb

    //# MSI-FLAT Sequential Block
    always_ff @(posedge clk_i or negedge rst_ni) begin : flat_seq
        if (~rst_ni) begin
            flat_state_q        <= IDLE;
            flat_wait_rlast_q   <= 1'b0;
            pptr_q              <= '0;
            flat_cause_q        <= '0;
            vpn_q               <= '0;
            pscid_q             <= '0;
            gscid_q             <= '0;
            is_1S_2M_q          <= 1'b0;
            is_1S_1G_q          <= 1'b0;
            gpte_q              <= '0;
        end 
        
        else begin
            flat_state_q        <= flat_state_n;
            flat_wait_rlast_q   <= flat_wait_rlast_n;
            pptr_q              <= pptr_n;
            flat_cause_q        <= flat_cause_n;
            vpn_q               <= vpn_n;
            pscid_q             <= pscid_n;
            gscid_q             <= gscid_n;
            is_1S_2M_q          <= is_1S_2M_n;
            is_1S_1G_q          <= is_1S_1G_n;
            gpte_q              <= gpte_n;
        end
    end : flat_seq

    //# MSI-MRIF

    // States
    typedef enum logic[1:0] {
       MRIF_PTE,         // 00
       NOTICE_PTE,       // 01
       MRIF_ERROR        // 10
    } state_mrif_t;

    //# MSI-MRIF

    // States
    typedef enum logic[1:0] {
       MRIF_PTE,         // 00
       NOTICE_PTE,       // 01
       MRIF_ERROR        // 10
    } state_mrif_t;

    state_mrif_t mrif_state_q, mrif_state_n;

    generate
    // MRIF support enabled
    if (MSITrans == rv_iommu::MSI_FLAT_MRIF) begin : gen_mrif_support

        // Read ports
        rv_iommu::msi_pte_mrif_t msi_pte_mrif;
        rv_iommu::msi_pte_notice_t msi_pte_notice;
        assign msi_pte_mrif     = rv_iommu::msi_pte_mrif_t'(mem_resp_i.r.data);
        assign msi_pte_notice   = rv_iommu::msi_pte_notice_t'(mem_resp_i.r.data);

        // Fault code
        logic [(rv_iommu::CAUSE_LEN-1):0] mrif_cause_q, mrif_cause_n;

        // To wait for last AXI beat
        logic mrif_wait_rlast_q, mrif_wait_rlast_n;

        // Destination MRIF address register
        logic [46:0] mrif_addr_q, mrif_addr_n;

        // MRIFC update ports
        assign mrifc_msi_content_o.addr = mrif_addr_q;
        assign mrifc_msi_content_o.nid  = {msi_pte_notice.nid_10, msi_pte_notice.nid_9_0};
        assign mrifc_msi_content_o.nppn = msi_pte_notice.nppn;

        // MSI PTW active flag
        assign msiptw_active_o = (flat_state_q != IDLE) | (mrif_state_q != MRIF_PTE);

        // Error
        assign error_o = (flat_state_q == FLAT_ERROR) | (mrif_state_q == MRIF_ERROR);
        assign cause_o = (flat_state_q == FLAT_ERROR) ? (flat_cause_q) : ((mrif_state_q == MRIF_ERROR) ? (mrif_cause_q) : ('0));
    
        //# MSI-MRIF Combinational Block
        always_comb begin : mrif_comb

            // Default assignments
            // Wires

            // Output values
            mrifc_update_o      = 1'b0;
            ignore_o            = 1'b0;

            // Next values
            mrif_state_n        = mrif_state_q;
            mrif_cause_n        = mrif_cause_q;
            mrif_addr_n         = mrif_addr_q;
            mrif_wait_rlast_n   = mrif_wait_rlast_q;

            case (mrif_state_q)

                // Validate the first 64 bits of the PTE. Check access address
                MRIF_PTE: begin

                    // An MSI PTE in MRIF mode was fetched. Validate PTE
                    if (init_msi_mrif) begin

                        mrif_wait_rlast_n = 1'b0;
                        
                        // Check first 64 bits of the MSI PTE
                        if ((|msi_pte_mrif.__rsv_1) || (|msi_pte_mrif.__rsv_2)) begin
                            mrif_wait_rlast_n   = 1'b1;
                            mrif_cause_n        = rv_iommu::MSI_PTE_MISCONFIGURED;
                            mrif_state_n        = MRIF_ERROR;
                        end

                        // Check bits [11:0] of the access address (this implementation does not support BE accesses)
                        else if ((|req_iova_i[11:0])) begin
                            // this check does not generate faults, the transfer is discarded
                            ignore_o         = 1'b1;
                            mrif_state_n    = MRIF_PTE;
                        end

                        // Everything OK
                        else begin
                            mrif_addr_n     = msi_pte_mrif.addr;
                            mrif_state_n    = NOTICE_PTE;
                        end
                    end
                end

                // Validate the last 64 bits of the PTE
                // Update MRIF cache
                NOTICE_PTE: begin

                    if (mem_resp_i.r_valid) begin
                        
                        // Check last 64 bits of the MSI PTE
                        if ((|msi_pte_notice.__rsv_1) || (|msi_pte_notice.__rsv_2)) begin
                            mrif_cause_n = rv_iommu::MSI_PTE_MISCONFIGURED;
                            mrif_state_n = MRIF_ERROR;
                        end

                        // Everything OK, update MRIF cache
                        else begin
                            mrifc_update_o  = 1'b1;
                            mrif_state_n    = MRIF_PTE;
                        end
                    end
                end

                // Propagate fault code to the translation logic
                MRIF_ERROR: begin

                    // Check whether we have to wait for AXI transmission to end
                    if ((mrif_wait_rlast_q && mem_resp_i.r.last) || !mrif_wait_rlast_q) begin
                        mrif_state_n = MRIF_PTE;
                    end
                end

                default: mrif_state_n = MRIF_PTE;
            endcase

            // Check for AXI transmission errors
            // Exclude transmission errors from MSI-FLAT FSM
            if ((((mrif_state_q == MRIF_PTE) && init_msi_mrif) | (mrif_state_q == NOTICE_PTE) ) && 
                (mem_resp_i.r_valid) && (mem_resp_i.r.resp != axi_pkg::RESP_OKAY                )) begin

                mrifc_update_o      = 1'b0;
                mrif_wait_rlast_n   = ~mem_resp_i.r.last;
                mrif_cause_n        = rv_iommu::MSI_PT_DATA_CORRUPTION;
                mrif_state_n        = MRIF_ERROR;
            end
        end : mrif_comb

        //# MSI-MRIF Sequential Block
        always_ff @(posedge clk_i or negedge rst_ni) begin : mrif_seq
            if (~rst_ni) begin
                mrif_state_q        <= MRIF_PTE;
                mrif_wait_rlast_q   <= 1'b0;
                mrif_cause_q        <= '0;
                mrif_addr_q         <= '0;
            end 
            
            else begin
                mrif_state_q        <= mrif_state_n;
                mrif_wait_rlast_q   <= mrif_wait_rlast_n;
                mrif_cause_q        <= mrif_cause_n;
                mrif_addr_q         <= mrif_addr_n;
            end
        end : mrif_seq
    end : gen_mrif_support

    // MRIF support disabled
    else begin : gen_mrif_support_disabled

        assign mrifc_update_o   = 1'b0;
        assign ignore_o         = 1'b0;

        assign mrifc_msi_content_o  = '0;

        assign msiptw_active_o      = (flat_state_q != IDLE);

        assign error_o              = (flat_state_q == FLAT_ERROR);
        assign cause_o              = (flat_state_q == FLAT_ERROR) ? (flat_cause_q) : ('0);

    end : gen_mrif_support_disabled
    endgenerate

endmodule
