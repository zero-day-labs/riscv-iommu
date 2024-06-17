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
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Command Queue (CQ) handler module.
//              This module fetches, decodes and executes commands
//              issued by software into the CQ

module rv_iommu_cq_handler #(
    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
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

    input  logic                    cq_mf_i,            // Error bit status 
    input  logic                    cmd_to_i,    
    input  logic                    cmd_ill_i,
    input  logic                    fence_w_ip_i, 

    output logic                    error_wen_o,        // To enable write of corresponding error bit to regmap
    output logic                    cq_mf_o,            // Set when a memory fault occurred during CQ access
    output logic                    cmd_to_o,           // The execution of a command lead to a timeout //! Future work for PCIe ATS
    output logic                    cmd_ill_o,          // Illegal or unsupported command was fetched from CQ
    output logic                    fence_w_ip_o,       // Set to indicate completion of an IOFENCE command
    output logic                    cq_ip_o,            // To set cip bit in ipsr register if a fault occurs and cq_ie is set

    input  logic                    wsi_en_i,           // Indicates if the IOMMU supports and uses WSI generation

    // DDTC Invalidation
    output logic                        flush_ddtc_o,   // Flush DDTC
    output logic                        flush_dv_o,     // Indicates if device_id is valid
    output logic [23:0]                 flush_did_o,    // device_id to tag entries to be flushed

    // PDTC Invalidation
    output logic                        flush_pdtc_o,   // Flush PDTC
    output logic                        flush_pv_o,     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
    output logic [19:0]                 flush_pid_o,    // process_id to be flushed if PV = 1

    // IOTLB Invalidation
    output logic                        flush_vma_o,    // Flush first-stage PTEs cached entries in IOTLB
    output logic                        flush_gvma_o,   // Flush second-stage PTEs cached entries in IOTLB 
    output logic                        flush_av_o,     // Address valid
    output logic                        flush_gv_o,     // GSCID valid
    output logic                        flush_pscv_o,   // PSCID valid
    output logic [riscv::GPPNW-1:0]     flush_vpn_o,    // IOVA to tag entries to be flushed
    output logic [15:0]                 flush_gscid_o,  // GSCID (Guest physical address space identifier) to tag entries to be flushed
    output logic [19:0]                 flush_pscid_o,  // PSCID (Guest virtual address space identifier) to tag entries to be flushed

    // Memory Bus
    input  axi_rsp_t   mem_resp_i,
    output axi_req_t    mem_req_o
);

    // FSM states
    enum logic [2:0] {
        IDLE,           // 000
        FETCH,          // 001
        REGISTER,       // 010
        DECODE,         // 011
        WRITE,          // 100
        ERROR           // 101
    }   state_q, state_n;

    // Write FSM states
    enum logic [1:0] {
        AW_REQ,
        W_DATA,
        B_RESP
    }   wr_state_q, wr_state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] cq_pptr_q, cq_pptr_n;

    // To mask the input head index according to the size of the CQ
    logic [31:0]    masked_head;
    assign          masked_head = cq_head_i & ~({32{1'b1}} << (cq_size_i+1));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic cq_en_q, cq_en_n;
    assign busy_o = (cq_en_i != cq_en_q);

    /* 
        INFO: When the cqon bit reads 0, the IOMMU guarantees:
              (i)  That no implicit memory accesses to the command queue are in-flight;
              (ii) The command-queue will not generate new implicit loads to the queue memory.
    */
    assign cq_on_o = (cq_en_q | cq_en_i);

    // To check if any error bit was cleared by SW
    logic   error_vector;
    assign  error_vector    = (cq_mf_i | cmd_to_i | cmd_ill_i);

    // Set ipsr.cie if any error bit is set
    assign cq_ip_o  = ((cq_mf_o | cmd_to_o | cmd_ill_o | fence_w_ip_o) & cq_ie_i);

    // CQ entry register
    logic [127:0]   cmd_q, cmd_n;

    // Cast read bus to receive CQ entries from memory
    rv_iommu::cq_entry_t       cq_entry;
    rv_iommu::cq_iotinval_t    cmd_iotinval;
    rv_iommu::cq_iofence_t     cmd_iofence;
    rv_iommu::cq_iodirinval_t  cmd_iodirinval;

    assign cq_entry         = rv_iommu::cq_entry_t'(cmd_q);
    assign cmd_iotinval     = rv_iommu::cq_iotinval_t'(cmd_q);
    assign cmd_iofence      = rv_iommu::cq_iofence_t'(cmd_q);
    assign cmd_iodirinval   = rv_iommu::cq_iodirinval_t'(cmd_q);


    //# Combinational Logic
    always_comb begin : rv_iommu_cq_handler
        
        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0000;
        mem_req_o.aw.addr       = {{riscv::XLEN-riscv::PLEN{1'b0}}, cq_pptr_q};
        mem_req_o.aw.len        = 8'b0;
        mem_req_o.aw.size       = 3'b010;
        mem_req_o.aw.burst      = axi_pkg::BURST_INCR;
        mem_req_o.aw.lock       = '0;
        mem_req_o.aw.cache      = '0;
        mem_req_o.aw.prot       = '0;
        mem_req_o.aw.qos        = '0;
        mem_req_o.aw.region     = '0;
        mem_req_o.aw.atop       = '0;
        mem_req_o.aw.user       = '0;

        mem_req_o.aw_valid      = 1'b0;                 // IOMMU may write to memory when executing IOFENCE.C

        // W
        mem_req_o.w.data        = {32'b0, cmd_iofence.data};
        mem_req_o.w.strb        = '1;
        mem_req_o.w.last        = 1'b1;
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;                 // IOMMU may write to memory when executing IOFENCE.C

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar.id         = 4'b0010;              
        mem_req_o.ar.addr       = {{riscv::XLEN-riscv::PLEN{1'b0}}, cq_pptr_q}; // Physical address to access
        mem_req_o.ar.len        = 8'd1;                                         // CQ entries are 16-bytes wide (2 beats)
        mem_req_o.ar.size       = 3'b011;                                       // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;                          // Incremental start address
        mem_req_o.ar.lock       = '0;
        mem_req_o.ar.cache      = '0;
        mem_req_o.ar.prot       = '0;
        mem_req_o.ar.qos        = '0;
        mem_req_o.ar.region     = '0;
        mem_req_o.ar.user       = '0;

        mem_req_o.ar_valid      = 1'b0;                 // to init a request

        // R
        mem_req_o.r_ready       = 1'b0;                 // to signal read completion

        flush_vma_o             = 1'b0;
        flush_gvma_o            = 1'b0;
        flush_av_o              = 1'b0;
        flush_gv_o              = 1'b0;
        flush_pscv_o            = 1'b0;
        flush_vpn_o             = '0;
        flush_gscid_o           = '0;
        flush_pscid_o           = '0;

        flush_ddtc_o            = 1'b0;
        flush_dv_o              = 1'b0;
        flush_did_o             = '0;
        flush_pdtc_o            = 1'b0;
        flush_pv_o              = 1'b0;
        flush_pid_o             = '0;

        error_wen_o             = 1'b0;

        cq_head_o               = cq_head_i;
        cq_mf_o                 = cq_mf_i;
        cmd_ill_o               = cmd_ill_i;
        cmd_to_o                = cmd_to_i;
        fence_w_ip_o            = fence_w_ip_i;

        state_n                 = state_q;
        wr_state_n              = wr_state_q;
        cq_pptr_n               = cq_pptr_q;
        cq_en_n                 = cq_en_q;
        cmd_n                   = cmd_q;

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
                        error_wen_o     = 1'b1;

                        cq_en_n = 1'b1;
                    end
                
                    else if (cq_tail_i != masked_head) begin

                        // Set pptr with the paddr of the next entry
                        cq_pptr_n = {cq_base_ppn_i, 12'b0} | ({{riscv::PLEN-32{1'b0}}, masked_head} << 4);
                        state_n = FETCH;
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (cq_en_q) begin
                    cq_en_n = 1'b0;
                end
            end

            FETCH: begin
                // send request to AXI bus
                mem_req_o.ar_valid = 1'b1;
                // wait for the WAIT_GRANT
                if (mem_resp_i.ar_ready) begin
                    state_n     = REGISTER;
                end
            end

            REGISTER: begin
                // wait for RVALID
                if (mem_resp_i.r_valid) begin
                    mem_req_o.r_ready   = 1'b1;

                    if (mem_resp_i.r.last) begin
                        cmd_n[127:64]   = mem_resp_i.r.data;
                        cq_head_o = (cq_head_i + 1) & ~({32{1'b1}} << (cq_size_i+1));  // head is incremented after fetching a command
                        state_n         = DECODE;
                    end
                    else cmd_n[63:0]    = mem_resp_i.r.data;

                    // Check for AXI transmission errors
                    // Here we can also receive IOPMP faults. However, these are considered as AXI errors.
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin

                        state_n         = ERROR;
                        cq_mf_o         = 1'b1;
                        error_wen_o     = 1'b1;
                    end
                end
            end

            DECODE: begin

                state_n = IDLE;
                case (cq_entry.opcode)

                    /*
                        IOTINVAL.VMA ensures that previous stores made to the first-stage page tables by the harts are
                        observed by the IOMMU before all subsequent implicit reads from IOMMU to the corresponding
                        first-stage page tables.

                        IOTINVAL.GVMA ensures that previous stores made to the second-stage page tables are observed
                        before all subsequent implicit reads from IOMMU to the corresponding second-stage page tables.
                    */
                    rv_iommu::IOTINVAL: begin

                        flush_av_o      = cmd_iotinval.av;
                        flush_gv_o      = cmd_iotinval.gv;
                        flush_vpn_o     = cmd_iotinval.addr[riscv::GPPNW-1:0];    // ADDR[63:12]
                        flush_gscid_o   = cmd_iotinval.gscid;
                        flush_pscid_o   = cmd_iotinval.pscid;

                        // "A command is determined to be illegal if a reserved bit is set to 1"
                        // "Setting PSCV to 1 with IOTINVAL.GVMA is illegal"
                        if ((|cmd_iotinval.reserved_1) || (|cmd_iotinval.reserved_2) || 
                            (|cmd_iotinval.reserved_3) || (|cmd_iotinval.reserved_4) ||
                            (cmd_iotinval.func3 == rv_iommu::GVMA && cmd_iotinval.pscv)) begin
                            
                            cmd_ill_o       = 1'b1;
                            error_wen_o     = 1'b1;
                            state_n         = ERROR;
                        end

                        // Check func3 to determine if command is VMA or GVMA
                        else if (cmd_iotinval.func3 == rv_iommu::VMA) begin
                            flush_vma_o     = 1'b1;
                            flush_pscv_o    = cmd_iotinval.pscv;
                        end

                        else if (cmd_iotinval.func3 == rv_iommu::GVMA) begin
                            flush_gvma_o    = 1'b1;
                        end

                    end

                    /*
                        A IOFENCE.C command completion, as determined by cqh advancing past the index of the IOFENCE.C
                        command in the CQ, guarantees that all previous commands fetched from the CQ have been
                        completed and committed.
                    */
                    rv_iommu::IOFENCE: begin
                        /*
                            INFO:
                            I think this command makes sense when implementing ATS commands, or any other command that
                            could take several cycles to execute. In this scenario, the FSM may execute subsequent commands
                            while the other completes, and the IOFENCE would wait for all fetched commands to be completed.
                            Since all implemented commands in this version are executed immediately, there's no need to wait for now
                        */

                        // "A command is determined to be illegal if a reserved bit is set to 1"
                        if ((|cmd_iofence.reserved_1) || (|cmd_iofence.reserved_2)) begin
                            
                            cmd_ill_o   = 1'b1;
                            error_wen_o = 1'b1;
                            state_n     = ERROR;
                        end

                        // Valid IOFENCE.C command
                        else begin

                            // "If AV=1, the IOMMU writes DATA to memory at a 4-byte aligned address ADDR[63:2] * 4"
                            if(cmd_iofence.av) begin
                                cq_pptr_n   = {cmd_iofence.addr[riscv::PLEN-1-2:0], 2'b0};
                                wr_state_n  = AW_REQ;
                                state_n     = WRITE;
                            end

                            // Set cqcsr.fence_w_ip if IOMMU supports and uses WSIs
                            if (cmd_iofence.wsi && wsi_en_i) begin
                                fence_w_ip_o    = 1'b1;
                                error_wen_o     = 1'b1;
                            end
                        end

                        // TODO: Check PR and PW bits
                    end

                    /*
                        IODIR.INVAL_DDT guarantees that any previous stores made by a RISC-V hart to the DDT are observed
                        before all subsequent implicit reads from IOMMU to DDT.

                        IODIR.INVAL_PDT guarantees that any previous stores made by a RISC-V hart to the PDT are observed
                        before all subsequent implicit reads from IOMMU to PDT.
                    */
                    rv_iommu::IODIR: begin

                        flush_dv_o  = cmd_iodirinval.dv;
                        flush_did_o = cmd_iodirinval.did;

                        // "A command is determined to be illegal if a reserved bit is set to 1"
                        // "The PID operand is reserved for IODIR.INVAL_DDT"
                        // "The DV operand must be 1 for IODIR.INVAL_PDT"
                        if ((|cmd_iodirinval.reserved_1) || (|cmd_iodirinval.reserved_2)    || 
                            (|cmd_iodirinval.reserved_3) || (|cmd_iodirinval.reserved_4)    ||
                            (cmd_iodirinval.func3 == rv_iommu::DDT && |cmd_iodirinval.pid)  ||
                            (cmd_iodirinval.func3 == rv_iommu::PDT && !cmd_iodirinval.dv)     ) begin
                            
                            cmd_ill_o   = 1'b1;
                            error_wen_o = 1'b1;
                            state_n     = ERROR;
                        end

                        // Check func3 to determine if command is INVAL_DDT or INVAL_PDT
                        else if (cmd_iodirinval.func3 == rv_iommu::DDT) begin
                            flush_ddtc_o    = 1'b1;
                            flush_pdtc_o    = 1'b1;
                        end

                        else if (cmd_iodirinval.func3 == rv_iommu::PDT) begin
                            flush_pdtc_o    = 1'b1;
                            flush_pv_o      = 1'b1;
                            flush_pid_o     = cmd_iodirinval.pid;
                        end
                    end

                    rv_iommu::ATS: begin
                        // TODO: Future Work. Considered illegal in this implementation
                        cmd_ill_o   = 1'b1;
                        error_wen_o = 1'b1;
                        state_n     = ERROR;
                    end

                    default: begin
                        // "A command is determined to be illegal if it uses a reserved encoding"
                        cmd_ill_o   = 1'b1;
                        error_wen_o = 1'b1;
                        state_n     = ERROR;
                    end
                    
                endcase
            end

            // Write DATA (32-bit) to ADDR[63:2] * 4
            WRITE: begin
                
                case (wr_state_q)

                    // Send request to AW Channel
                    AW_REQ: begin
                        mem_req_o.aw_valid  = 1'b1;

                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end

                    // Send data through W channel
                    W_DATA: begin
                        mem_req_o.w_valid   = 1'b1;

                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end

                    // Check response code
                    // Here we can also receive IOPMP faults. However, these are considered as AXI errors.
                    B_RESP: begin
                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                // AXI error
                                state_n         = ERROR;
                                cq_mf_o         = 1'b1;
                                error_wen_o     = 1'b1;
                            end

                            // After writing DATA to ADDR[63:2]*4 there is nothing else to do for IOFENCE.C
                            else state_n = IDLE;
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // When an error occurs, the CQ stops processing commands until SW clear all error bits
            // If CQ IE is set, the cip bit in the ipsr must be set
            ERROR: begin

                mem_req_o.r_ready   = 1'b1;     // Discard all incoming beats to end AXI transaction
                
                if (!error_vector)
                    state_n = IDLE;
            end

            default: state_n = IDLE;
        endcase
    end

    //# Sequential Logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        
        // Reset
        if (~rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            cq_en_q         <= 1'b0;
            cmd_q           <= '0;
            cq_pptr_q       <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            cq_en_q         <= cq_en_n;
            cmd_q           <= cmd_n;
            cq_pptr_q       <= cq_pptr_n;
        end
    end
    
endmodule