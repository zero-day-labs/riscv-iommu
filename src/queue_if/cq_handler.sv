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
// Date: 15/02/2023
//
// Description: RISC-V IOMMU Command Queue (CQ) handler module.
//              This module fetches, decodes and executes commands
//              issued by software into the CQ

//! NOTES:
/*
    -   I think the verification of the base_ppn alignment must be performed at initialization, and not by this module.
        For Nº of entries <= 7, the base PPN must be aligned to 4KiB, so bits [11:0] must be 0.
        For Nº of entries  > 7, the MSB index increases by one for each level (for 8 -> [12:0]; for 9 -> [13:0]; etc).
    -   Invalidations are performed by the TLBs through combinational logic in one single cycle.
    -   Registers that are handled both by SW and HW have an input port and an output port.
    !-   IOMMU support for WSI (caps.IGS) or enable of WSI (fctl.WSI) must be checked externally before setting cqcsr.fence_w_ip
*/

module cq_handler import ariane_pkg::*; #(
    parameter int unsigned DEVICE_ID_WIDTH = 24,
    parameter int unsigned PROCESS_ID_WIDTH  = 20,
    parameter int unsigned PSCID_WIDTH = 20,
    parameter int unsigned GSCID_WIDTH = 16,
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Regmap
    input  logic [riscv::PPNW-1:0]  cq_base_ppn_i,      // Base address of the CQ in memory (Should be aligned. See Spec)
    input  logic [4:0]              cq_size_i,          // Size of the CQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

    input  logic                    cq_en_i,            // CQ enable bit from cqcsr, handled by SW
    input  logic                    cq_ie_i,            // CQ interrupt enable bit from cqcsr, handled by SW

    // INFO: Indexes are incremented by 1 each time a cmd is read or written. The tail register may be used by the IOMMU to monitor SW writes to CQ
    input  logic [31:0]             cq_tail_i,          // CQ tail index (SW writes the next CQ entry to cq_base + cq_tail * 16 bytes)
    input  logic [31:0]             cq_head_i,          // CQ head index (the IOMMU reads the next entry from cq_base + cq_head * 16 bytes)
    output logic [31:0]             cq_head_o,

    output logic                    cq_on_o,            // CQ active bit. Indicates to SW whether the CQ is active or not
    output logic                    busy_o,             // CQ busy bit. Indicates SW that the CQ is in the middle of a state transition, 
                                                        //              so it has to wait to write to cqcsr.

    input logic                     cq_mf_i,             
    input logic                     cmd_to_i,    
    input logic                     cmd_ill_i,   

    output logic                    error_o,            // To enable write of corresponding error bit to regmap
    output logic                    cq_mf_o,            // Set when a memory fault occurred during CQ access
    output logic                    cmd_to_o,           // The execution of a command lead to a timeout //! Future work for PCIe ATS
    output logic                    cmd_ill_o,          // Illegal or unsupported command was fetched from CQ
    output logic                    fence_w_ip_o,       // Set to indicate completion of an IOFENCE command
    output logic                    cq_ip_o,            // To set cip bit in ipsr register if a fault occurs and cq_ie is set

    // DDTC Invalidation
    output logic                        flush_ddtc_o,   // Flush DDTC
    output logic                        flush_dv_o,     // Indicates if device_id is valid
    output logic [DEVICE_ID_WIDTH-1:0]  flush_did_o,    // device_id to tag entries to be flushed

    // PDTC Invalidation
    output logic                        flush_pdtc_o,   // Flush PDTC
    output logic                        flush_pv_o,     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
    output logic [PROCESS_ID_WIDTH-1:0] flush_pid_o,    // process_id to be flushed if PV = 1

    // IOTLB Invalidation
    output logic                        flush_vma_o,    // Flush first-stage PTEs cached entries in IOTLB
    output logic                        flush_gvma_o,   // Flush second-stage PTEs cached entries in IOTLB 
    output logic                        flush_av_o,     // Address valid
    output logic                        flush_gv_o,     // GSCID valid
    output logic                        flush_pscv_o,   // PSCID valid
    output logic [riscv::VLEN-1:0]      flush_vpn_o,    // IOVA to tag entries to be flushed
    output logic [GSCID_WIDTH-1:0]      flush_gscid_o,  // GSCID (Guest physical address space identifier) to tag entries to be flushed
    output logic [PSCID_WIDTH-1:0]      flush_pscid_o   // PSCID (Guest virtual address space identifier) to tag entries to be flushed

    // Memory Bus
    input  dcache_req_o_t           mem_resp_i,             // Response port from memory
    output dcache_req_i_t           mem_req_o               // Request port to memory
);

    // FSM states
    enum logic [1:0] {
        IDLE,
        FETCH,
        DECODE,
        ERROR
    }   state_q, state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] cq_pptr_q, cq_pptr_n;

    // To mask the input head index according to the size of the CQ
    logic [31:0]    masked_head;
    assign          masked_head = (cq_size_i <= 7) ? (cq_head_i & 32'b1111_1111) : (cq_head_i & ~({32{1'b1}} << (cq_size_i+1)));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic cq_en_q, cq_en_n;
    assign busy_o = (cq_en_i != cq_en_q);

    /* 
        INFO: When the cqon bit reads 0, the IOMMU guarantees: 
              (i)  That no implicit memory accesses to the command queue are in-flight;
              (ii) The command-queue will not generate new implicit loads to the queue memory.
    */
    assign cq_on_o = ~(!cq_en_q && !cq_en_i);

    // To check if any error bit was cleared by SW
    logic   error_vector;
    assign  error_vector    = (cq_mf_i | cmd_to_i | cmd_ill_i);

    // To enable write of error bits to regmap
    assign  error_o         = (cq_mf_o | cmd_to_o | cmd_ill_o);

    // Cast read bus to receive CQ entries from memory
    iommu_pkg::cq_entry_t       cq_entry;
    iommu_pkg::cq_iotinval_t    cmd_iotinval;
    iommu_pkg::cq_iofence_t     cmd_iofence;
    iommu_pkg::cq_iodirinval_t  cmd_iodirinval;

    assign cq_entry         = iommu_pkg::cq_entry_t'(data_rdata_q);
    assign cmd_iotinval     = iommu_pkg::cq_iotinval_t'(data_rdata_q);
    assign cmd_iofence      = iommu_pkg::cq_iofence_t'(data_rdata_q);
    assign cmd_iodirinval   = iommu_pkg::cq_iodirinval_t'(data_rdata_q);

    // TODO: Change to AXI Master memory interface
    // Memory signals
    logic data_rvalid_q;
    logic [63:0] data_rdata_q;

    // directly output the correct physical address
    assign mem_req_o.address_index = cq_pptr_q[DCACHE_INDEX_WIDTH-1:0];
    assign mem_req_o.address_tag   = cq_pptr_q[DCACHE_INDEX_WIDTH+DCACHE_TAG_WIDTH-1:DCACHE_INDEX_WIDTH];
    // we are never going to kill this request
    assign mem_req_o.kill_req      = '0;
    // we are never going to write with the HPTW
    assign mem_req_o.data_wdata    = 64'b0;
    // data memory request port
    assign mem_req_o.tag_valid     = tag_valid_q;

    //# Combinational Logic
    always_comb begin : cq_handler
        
        // Default values
        mem_req_o.data_req  = 1'b0;
        mem_req_o.data_be   = 8'hFF;
        mem_req_o.data_size = 2'b11;
        mem_req_o.data_we   = 1'b0;

        flush_vma_o         = 1'b0;
        flush_gvma_o        = 1'b0;
        flush_av_o          = 1'b0;
        flush_gv_o          = 1'b0;
        flush_pscv_o        = 1'b0;
        flush_vpn_o         = '0;
        flush_gscid_o       = '0;
        flush_pscid_o       = '0;

        flush_ddtc_o        = 1'b0;
        flush_dv_o          = 1'b0;
        flush_did_o         = '0;
        flush_pdtc_o        = 1'b0;
        flush_pv_o          = 1'b0;
        flush_pid_o         = '0;

        cq_head_o           = cq_head_i;
        cq_mf_o             = cq_mf_i;
        cmd_ill_o           = cmd_ill_i;
        cmd_to_o            = cmd_to_i;
        fence_w_ip_o        = fence_w_ip_i;

        state_n             = state_q;
        cq_pptr_n           = cq_pptr_q;
        cq_en_n             = cq_en_q;

        case (state_q)

            // CQ fetch is automatically triggered when head != tail and CQ is enabled
            IDLE: begin

                if (cq_en_i) begin

                    // CQ was recently enabled by SW. Set cq_head, cq_mf, cmd_ill, cmd_to and fence_w_ip to zero
                    if (!cq_en_q) begin
                        cq_head_o       = '0;
                        cq_mf_o         = 1'b0;
                        cmd_ill_o       = 1'b0;
                        cmd_to_o        = 1'b0;
                        fence_w_ip_o    = 1'b0;

                        cq_en_n = 1'b1;
                    end
                
                    else if (cq_tail_i != masked_head) begin

                        // Set pptr with the paddr of the next entry
                        if (cq_size_i <= 7) cq_pptr_n = {cq_base_ppn_i, 12'b0} | {masked_head, 4'b0};
                        else                cq_pptr_n = {cq_base_ppn_i << (cq_size_i+5)} | {masked_head, 4'b0};

                        state_n = FETCH;
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (cq_en_q) begin
                    cq_en_n = 1'b0;
                end
            end

            FETCH: begin
                // send request to memory
                mem_req_o.data_req = 1'b1;
                // wait for the WAIT_GRANT
                if (mem_resp_i.data_gnt) begin
                    // send the tag valid signal to request bus, one cycle later
                    tag_valid_n = 1'b1;
                    state_n     = DECODE;
                end
            end

            DECODE: begin
                // we wait for the valid signal
                if (data_rvalid_q) begin
                    state_n = IDLE;
                    cq_head_o = cq_head_i + 1;

                    //! PSEUDOCODE
                    //! Here we should check for memory access errors.
                    //! In case of an error, abort execution and set cq_mf
                    if (memory_fetch_error || pmp_access_error) begin
                        state_n = ERROR;
                        cq_mf_o = 1'b1;
                        cq_head_o = cq_head_i;
                    end
                    //!
                    else begin
                        case (cq_entry.opcode)

                            /*
                                IOTINVAL.VMA ensures that previous stores made to the first-stage page tables by the harts are
                                observed by the IOMMU before all subsequent implicit reads from IOMMU to the corresponding
                                first-stage page tables.

                                IOTINVAL.GVMA ensures that previous stores made to the second-stage page tables are observed
                                before all subsequent implicit reads from IOMMU to the corresponding second-stage page tables.
                            */
                            IOTINVAL: begin

                                flush_av_o      = cmd_iotinval.av;
                                flush_gv_o      = cmd_iotinval.gv;
                                flush_vpn_o     = cmd_iotinval.addr;    // ADDR[63:12]
                                flush_gscid_o   = cmd_iotinval.gscid;
                                flush_pscid_o   = cmd_iotinval.pscid;

                                // "A command is determined to be illegal if a reserved bit is set to 1"
                                // "Setting PSCV to 1 with IOTINVAL.GVMA is illegal"
                                if ((|cmd_iotinval.reserved_1) || (|cmd_iotinval.reserved_2) || 
                                    (|cmd_iotinval.reserved_3) || (|cmd_iotinval.reserved_4) ||
                                    (cmd_iotinval.func3 == iommu_pkg::GVMA && cmd_iotinval.pscv)) begin
                                    
                                    cmd_ill_o   = 1'b1;
                                    cq_head_o   = cq_head_i;
                                    state_n     = ERROR;
                                end

                                // Check func3 to determine if command is VMA or GVMA
                                else if (cmd_iotinval.func3 == iommu_pkg::VMA) begin
                                    flush_vma_o     = 1'b1;
                                    flush_pscv_o    = cmd_iotinval.pscv;
                                end

                                else if (cmd_iotinval.func3 == iommu_pkg::GVMA) begin
                                    flush_gvma_o    = 1'b1;
                                end

                            end

                            /*
                                A IOFENCE.C command completion, as determined by cqh advancing past the index of the IOFENCE.C
                                command in the CQ, guarantees that all previous commands fetched from the CQ have been
                                completed and committed.

                            */
                            IOFENCE: begin
                                /*
                                    INFO:
                                    I think this command makes sense when implementing ATS commands, or any other command that
                                    could take several cycles to execute. In this scenario, the FSM may execute subsequent commands
                                    while the other completes, and the IOFENCE would wait for all fetched commands to be completed.
                                    Since all implemented commands in this version are executed immediately, there's no need to wait for now
                                */

                                // "A command is determined to be illegal if a reserved bit is set to 1"
                                if ((|cmd_iofence.reserved_1) || (|cmd_iotinval.reserved_2)) begin
                                    
                                    cmd_ill_o   = 1'b1;
                                    cq_head_o   = cq_head_i;
                                    state_n     = ERROR;
                                end

                                if(cmd_iofence.av) begin

                                    // TODO: Write DATA (32-bit) to ADDR[63:2] * 4
                                    cq_pptr_n = {cmd_iofence.addr, 2'b0};
                                end

                                else begin
                                    fence_w_ip_o = cmd_iofence.wsi;
                                end

                                // TODO: Check PR and PW bits
                            end

                            /*
                                IODIR.INVAL_DDT guarantees that any previous stores made by a RISC-V hart to the DDT are observed
                                before all subsequent implicit reads from IOMMU to DDT.

                                IODIR.INVAL_PDT guarantees that any previous stores made by a RISC-V hart to the PDT are observed
                                before all subsequent implicit reads from IOMMU to PDT.
                            */
                            IOTDIR: begin

                                flush_dv_o  = cmd_iodirinval.dv;
                                flush_did_o = cmd_iodirinval.did;

                                // "A command is determined to be illegal if a reserved bit is set to 1"
                                // "PID operand is reserved for IODIR.INVAL_PDT"
                                if ((|cmd_iodirinval.reserved_1) || (|cmd_iodirinval.reserved_2) || 
                                    (|cmd_iodirinval.reserved_3) || (|cmd_iodirinval.reserved_4) ||
                                    (cmd_iodirinval.func3 == iommu_pkg::DDT && |cmd_iodirinval.pid)) begin
                                    
                                    cmd_ill_o   = 1'b1;
                                    cq_head_o   = cq_head_i;
                                    state_n     = ERROR;
                                end

                                // Check func3 to determine if command is INVAL_DDT or INVAL_PDT
                                else if (cmd_iodirinval.func3 == iommu_pkg::DDT) begin
                                    flush_ddtc_o    = 1'b1;
                                    flush_pdtc_o    = 1'b1;
                                end

                                else if (cmd_iodirinval.func3 == iommu_pkg::PDT) begin
                                    flush_pdtc_o    = 1'b1;
                                    flush_pv_o      = 1'b1;
                                    flush_pid_o     = cmd_iodirinval.pid;
                                end
                            end

                            ATS: begin
                                // TODO: Future Work
                            end

                            default: begin
                                // "A command is determined to be illegal if it uses a reserved encoding"
                                cmd_ill_o   = 1'b1;
                                cq_head_o   = cq_head_i;
                                state_n     = ERROR;
                            end
                        endcase
                    end
                end
            end

            // When an error occurs, the CQ stops processing commands until SW clear all error bits
            // If CQ IE is set, the cip bit in the ipsr must be set
            ERROR: begin
                if (!error_vector)
                    state_n = IDLE;

                if (cq_ie_i)
                    cq_ip_o = 1'b1;
            end

            default: state_n = IDLE;
        endcase
    end

    //# Sequential Logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        
        // Reset
        if (~rst_ni) begin
            state_q         <= IDLE;
            data_rdata_q    <= '0;
            data_rvalid_q   <= 1'b0;
            cq_en_q         <= 1'b0;
        end

        else begin
            state_q         <= state_n;
            data_rdata_q    <= mem_resp_i.data_rdata;
            data_rvalid_q   <= mem_resp_i.data_rvalid;
            cq_en_q         <= cq_en_n;
        end
    end
    
endmodule