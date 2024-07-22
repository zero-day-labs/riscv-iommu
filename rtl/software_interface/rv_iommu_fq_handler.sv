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
// Date: 16/02/2023
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Fault Queue (FQ) handler module.
//              This module registers a new fault record into the FQ 
//              upon any translation-related fault

//! NOTES:
/*
    -   FSM triggered by the occurrence of a fault/event raised when processing transactions (attention with DTF bit!).
    -   // TODO: Implement support for faults originated from PCIe Message Requests (Future Work)
    -   Guest page faults caused by implicit memory accesses for first-stage address translation and 
        PDT Walk when Stage 2 is not Bare must be identified. 
        For the former case, we have the ptw_error_stage2_int_o signal from the PTW, which identifies faults 
        occurred during second-stage translations performed to find the final leaf GPA. 
        For the latter case, we can re-use the flush_cdw_o, which is set by the PTW to flush the CDW 
        when it requested an implicit second-stage translation to walk the PDT. To avoid identifing DC.fsc.pdtp
        translations as implicit accesses, the external condition should be:
        # is_implicit = ptw_error_stage2_int_o | (flush_cdw_o & ~is_ddt_walk)
*/

module rv_iommu_fq_handler #(
    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Regmap
    input  logic [riscv::PPNW-1:0]  fq_base_ppn_i,      // Base address of the FQ in memory (Should be aligned. See Spec)
    input  logic [4:0]              fq_size_i,          // Size of the FQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

    input  logic                    fq_en_i,            // FQ enable bit from fqcsr, handled by SW
    input  logic                    fq_ie_i,            // FQ interrupt enable bit from fqcsr, handled by SW

    // INFO: Indexes are incremented by 1 each time a fault is read or written.
    input  logic [31:0]             fq_head_i,          // FQ head index (SW reads the next entry from fq_base + fq_head * 32 bytes)
    input  logic [31:0]             fq_tail_i,          // FQ tail index (IOMMU writes the next FQ entry to fq_base + fq_tail * 32 bytes)
    output logic [31:0]             fq_tail_o,

    output logic                    fq_on_o,            // FQ active bit. Indicates to SW whether the FQ is active or not
    output logic                    busy_o,             // FQ busy bit. Indicates SW that the FQ is in the middle of a state transition, 
                                                        //              so it has to wait to write to fqcsr.

    input logic                     fq_mf_i,             
    input logic                     fq_of_i,  

    output logic                    error_wen_o,        // To enable write of corresponding error bit to regmap
    output logic                    fq_mf_o,            // Set when a memory fault occurred during FQ access
    output logic                    fq_of_o,            // The execution of a command lead to a timeout 
    output logic                    fq_ip_o,            // To set ipsr.fip register if a fault occurs and fq_ie is set

    // Event data
    input  logic                                event_valid_i,      // a fault/event has occurred
    input  logic [rv_iommu::TTYP_LEN-1:0]       trans_type_i,       // transaction type
    input  logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_i,       // Fault code as defined by IOMMU and Priv Spec
    input  logic [riscv::VLEN-1:0]              iova_i,             // to report if transaction has an IOVA
    input  logic [riscv::SVX-1:0]               gpaddr_i,           // to report bits [63:2] of the GPA in case of a Guest Page Fault
    input  logic [23:0]                         did_i,              // device_id associated with the transaction
    input  logic                                pv_i,               // to indicate if transaction has a valid process_id
    input  logic [19:0]                         pid_i,              // process_id associated with the transaction
    input  logic                                is_supervisor_i,    // indicate if transaction has supervisor privilege (only if pid valid)
    input  logic                                is_guest_pf_i,      // indicate if event is a guest page fault
    input  logic                                is_implicit_i,      // Guest page fault caused by implicit access for 1st-stage addr translation

    // Memory Bus
    input  axi_rsp_t   mem_resp_i,
    output axi_req_t    mem_req_o,

    output logic                    is_full_o
);

    // FSM States
    enum logic [1:0] {
        IDLE,
        WRITE,
        ERROR
    }   state_q, state_n;

    // Write FSM states
    enum logic [1:0] {
        AW_REQ,
        W_DATA,
        B_RESP
    }   wr_state_q, wr_state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] fq_pptr_q, fq_pptr_n;

    // To mask the input tail index according to the size of the CQ
    logic [31:0]    masked_tail;
    assign          masked_tail = fq_tail_i & ~({32{1'b1}} << (fq_size_i+1));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic fq_en_q, fq_en_n;
    assign busy_o = (fq_en_i != fq_en_q);

    /* 
        INFO: When the fqon bit reads 0, the IOMMU guarantees:
            (i)  That there are no in-flight implicit writes to the FQ in progress;
            (ii) No new fault records will be written to the fault-queue.
    */
    assign fq_on_o = (fq_en_q | fq_en_i);

    // To check if any error bit was cleared by SW
    logic   error_vector;
    assign  error_vector    = (fq_mf_i | fq_of_i);

    // FQ Record register to save event data
    rv_iommu::fq_record_t fq_entry_q, fq_entry_n;

    // Counter to send all four FQ record DWs
    logic [1:0] wr_cnt_q, wr_cnt_n;

    // Signal to indicate that the FQ is currently writing a new record
    logic is_idle;
    assign is_idle = (wr_state_q == B_RESP);
    logic is_empty;

    // Wires to connect FIFO output
    logic [rv_iommu::TTYP_LEN-1:0]      trans_type;   
    logic [(rv_iommu::CAUSE_LEN-1):0]   cause_code;   
    logic [riscv::VLEN-1:0]             iova;         
    logic [riscv::SVX-1:0]              gpaddr;       
    logic [23:0]                        did;          
    logic                               pv;           
    logic [19:0]                        pid;          
    logic                               is_supervisor;
    logic                               is_guest_pf;  
    logic                               is_implicit;

    // FIFO edge-triggered push control
    logic edge_trigger_q, edge_trigger_n;

    // NOTE:    data is pushed into the FIFO when event_valid_i is set. Thus, this signal must be set 
    //          only one cycle after a fault/event occurred. Since it is directly driven by AXVALID, the
    //          Error Slave should be able to respond in one cycle
    fifo_v3 #(
        .FALL_THROUGH   (1),
        .DEPTH          (4),
        .DATA_WIDTH     (rv_iommu::TTYP_LEN + rv_iommu::CAUSE_LEN + riscv::VLEN + riscv::SVX + 24 + 20 + 4)
    ) i_fifo_fq (
        .clk_i      ( clk_i           ),
        .rst_ni     ( rst_ni          ),
        .flush_i    ( 1'b0            ),
        .testmode_i ( 1'b0            ),
        .full_o     ( is_full_o       ),
        .empty_o    ( is_empty        ),
        .usage_o    (                 ),
        .data_i     ( {trans_type_i, cause_code_i, iova_i, gpaddr_i, did_i, pv_i, pid_i, is_supervisor_i, is_guest_pf_i, is_implicit_i}),
        .push_i     ( event_valid_i & !edge_trigger_q ),
        .data_o     ( {trans_type, cause_code, iova, gpaddr, did, pv, pid, is_supervisor, is_guest_pf, is_implicit} ),
        .pop_i      ( is_idle ) // W transaction has finished
    );

    // FIFO edge-triggered push control
    always_comb begin : fifo_push_control

        // Default
        edge_trigger_n = edge_trigger_q;

        // Edged signal
        if (!edge_trigger_q && event_valid_i)
            edge_trigger_n = 1'b1;

        // End of edged signal
        if (edge_trigger_q && !event_valid_i)
            edge_trigger_n = 1'b0;

    end : fifo_push_control

    // Fault Queue handler FSM
    always_comb begin : rv_iommu_fq_handler
        
        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0001;
        mem_req_o.aw.addr       = {{riscv::XLEN-riscv::PLEN{1'b0}}, fq_pptr_q};
        mem_req_o.aw.len        = 8'd3;         // FQ records are 32-bytes wide
        mem_req_o.aw.size       = 3'b011;
        mem_req_o.aw.burst      = axi_pkg::BURST_INCR;
        mem_req_o.aw.lock       = '0;
        mem_req_o.aw.cache      = '0;
        mem_req_o.aw.prot       = '0;
        mem_req_o.aw.qos        = '0;
        mem_req_o.aw.region     = '0;
        mem_req_o.aw.atop       = '0;
        mem_req_o.aw.user       = '0;

        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w.data        = '0;                   // Must be set on each transfer
        mem_req_o.w.strb        = '1;
        mem_req_o.w.last        = 1'b0;                 // Must be set in the last transfer
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar.id         = 4'b0011;
        mem_req_o.ar.addr       = '0;                   // IOMMU never reads from FQ
        mem_req_o.ar.len        = '0;
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;
        mem_req_o.ar.lock       = '0;
        mem_req_o.ar.cache      = '0;
        mem_req_o.ar.prot       = '0;
        mem_req_o.ar.qos        = '0;
        mem_req_o.ar.region     = '0;
        mem_req_o.ar.user       = '0;

        mem_req_o.ar_valid      = 1'b0;                 // IOMMU never reads from FQ

        // R
        mem_req_o.r_ready       = 1'b0;                 // IOMMU never reads from FQ

        fq_tail_o   = fq_tail_i;
        fq_mf_o     = fq_mf_i;
        fq_of_o     = fq_of_i;

        error_wen_o = 1'b0;
        fq_ip_o     = 1'b0;

        state_n     = state_q;
        wr_state_n  = wr_state_q;
        fq_pptr_n   = fq_pptr_q;
        fq_entry_n  = fq_entry_q;
        wr_cnt_n    = wr_cnt_q;
        fq_en_n     = fq_en_q;

        case (state_q)

            // Monitor possible faults/events
            // Set FQ entry according to the fault and type of transaction
            IDLE: begin

                if (fq_en_i) begin

                    // FQ was recently enabled by SW. Clear fq_tail, fq_mf, and fq_of
                    if (!fq_en_q) begin
                        fq_tail_o   = '0;
                        fq_mf_o     = 1'b0;
                        fq_of_o     = 1'b0;
                        error_wen_o = 1'b1;

                        fq_en_n     = 1'b1;
                    end
                
                    else if ((event_valid_i & !edge_trigger_q) || !is_empty) begin

                        state_n     = WRITE;
                        wr_state_n  = AW_REQ;

                        fq_entry_n.iotval2  = '0;
                        fq_entry_n.iotval   = '0;
                        fq_entry_n.did      = '0;
                        fq_entry_n.ttyp     = trans_type;
                        fq_entry_n.priv     = 1'b0;
                        fq_entry_n.pv       = 1'b0;
                        fq_entry_n.pid      = '0;
                        fq_entry_n.cause    = cause_code;

                        // If TTYP = 0 or fault occurred due to a PCIe Msg Request, nothing is reported in iotval/iotval2
                        // The DID, PV, PID, and PRIV fields are 0 if TTYP is 0
                        if (trans_type != rv_iommu::NONE) begin
                            fq_entry_n.did      = did;
                            fq_entry_n.pid      = (pv) ? (pid) : ('0);
                            fq_entry_n.priv     = pv & is_supervisor;
                            fq_entry_n.pv       = pv;

                            if (trans_type != rv_iommu::PCIE_MSG_REQ)
                                fq_entry_n.iotval   = iova;
                        end

                        // The only case where TTYP = 0 known until now is for an IOMMU-generated MSI write access fault
                        else begin
                                fq_entry_n.iotval   = iova;
                        end
                        
                        // If the CAUSE is a guest-page fault then bits 63:2 of the GPA are reported in iotval2[63:2].
                        if (is_guest_pf) begin

                                fq_entry_n.iotval2      = {23'b0, gpaddr};    // zero-extended GPA
                                fq_entry_n.iotval2[0]   = is_implicit;        // Guest page fault was caused by an implicit access
                                fq_entry_n.iotval2[1]   = 1'b0;               // Always zero since A/D update of bits is not implemented
                            end

                        // Set pptr with the paddr of the next entry
                        fq_pptr_n = ({fq_base_ppn_i, 12'b0}) | ({{riscv::PLEN-32{1'b0}}, masked_tail} << 5);

                        // If a fault that must be reported occurs and the FQ is full, set fq_of and signal error
                        if (fq_tail_i == fq_head_i - 1) begin
                            fq_of_o     = 1'b1;
                            error_wen_o = 1'b1;
                            fq_ip_o     = fq_ie_i;
                            state_n     = ERROR;
                        end
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (fq_en_q) begin
                    fq_en_n = 1'b0;
                end
            end

            // Remember to increment fq_tail after writting to FQ
            WRITE: begin
                case (wr_state_q)

                    // Send request to AW Channel
                    AW_REQ: begin
                        mem_req_o.aw_valid  = 1'b1;

                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                            wr_cnt_n    = '0;
                        end
                    end

                    // Send data through W channel
                    W_DATA: begin
                        case (wr_cnt_q)
                            2'b00: mem_req_o.w.data    = fq_entry_q[63:0];
                            2'b01: mem_req_o.w.data    = fq_entry_q[127:64];
                            2'b10: mem_req_o.w.data    = fq_entry_q[191:128];
                            2'b11: begin
                                mem_req_o.w.data    = fq_entry_q[255:192];
                                mem_req_o.w.last    = 1'b1;
                            end
                        endcase
                        
                        mem_req_o.w_valid   = 1'b1;

                        if(mem_resp_i.w_ready) begin
                            wr_cnt_n    = wr_cnt_q + 1;     // only increment counter after receiving WREADY

                            if (&wr_cnt_q) begin
                                wr_state_n  = B_RESP;
                            end
                        end
                    end

                    // Check response code
                    // Here we can also receive IOPMP access faults. However, these are considered as AXI errors.
                    B_RESP: begin
                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            fq_ip_o             = fq_ie_i;  // When a new record is written and fie is set, set ipsr.fip
                            error_wen_o         = 1'b1;

                            wr_state_n          = AW_REQ;   // reset WR FSM
                            
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                // AXI error
                                state_n         = ERROR;
                                fq_mf_o         = 1'b1;
                            end

                            // After writing FQ record we can go back to IDLE
                            else begin
                                fq_tail_o   = (fq_tail_i + 1) & ~({32{1'b1}} << (fq_size_i+1));    // Increment fqt
                                state_n     = IDLE;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // When an error occurs, the FQ stops generating faults until SW clear all error bits
            // If FQ IE is set, the ipsr.fip must be set
            ERROR: begin
                if (!error_vector)
                    state_n = IDLE;
            end

            default: state_n = IDLE;
        endcase
    end

    //# Sequential logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            // Reset values
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            fq_pptr_q       <= '0;
            fq_entry_q      <= '0;
            fq_en_q         <= 1'b0;
            wr_cnt_q        <= '0;
            edge_trigger_q  <= 1'b0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            fq_pptr_q       <= fq_pptr_n;
            fq_entry_q      <= fq_entry_n;
            fq_en_q         <= fq_en_n;
            wr_cnt_q        <= wr_cnt_n;
            edge_trigger_q  <= edge_trigger_n;
        end
    end

endmodule
