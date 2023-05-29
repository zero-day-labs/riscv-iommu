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
// Date: 08/03/2023
//
// Description: RISC-V IOMMU MSI Interrupt Generation Module.

//! NOTES:
/*
    -   Interrupt generation is triggered on a possitive transition of cip or fip.
    -   The IOMMU must not send MSIs for interrupt vectors with mask M = 1. These messages must be saved and later sent if
        the corresponding mask is cleared to 0.
    -   A register could be used for each source to save messages from vectors with M = 1 (Remember that the same vector 
        can be used by different sources. That's why we can have more than one pending message per vector).
*/

module iommu_msi_ig #(
    parameter int unsigned N_INT_VEC = 16,

    // DO NOT MODIFY
    parameter int unsigned LOG2_INTVEC = $clog2(N_INT_VEC)
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic msi_ig_enabled_i,

    // Interrupt pending bits
    input  logic cip_i,
    input  logic fip_i,

    // icvec
    input  logic[(LOG2_INTVEC-1):0]   civ_i,
    input  logic[(LOG2_INTVEC-1):0]   fiv_i,

    // MSI config table
    input  logic [53:0] msi_addr_x_i[16],
    input  logic [31:0] msi_data_x_i[16],
    input  logic        msi_vec_masked_x_i[16],

    // MSI write error
    output logic        msi_write_error_o,

    // AXI Master interface to write to memory
    input  ariane_axi_soc::resp_t       mem_resp_i,
    output ariane_axi_soc::req_t        mem_req_o
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

    // To detect rising edge transition of cip/fip
    logic   edged_cip_q, edged_cip_n;
    logic   edged_fip_q, edged_fip_n;

    // Control signal to indicate interrupt source
    logic   is_cq_int_q, is_cq_int_n;

    // Pending interrupts
    logic [(N_INT_VEC-1):0] pending_q, pending_n;

    always_comb begin : int_generation_fsm

        // Default values
        // AXI parameters
        // AW
        /* verilator lint_off WIDTH */
        mem_req_o.aw.id         = 4'b0010;
        mem_req_o.aw.addr       = (is_cq_int_q) ? ({msi_addr_x_i[civ_i], 2'b0}) : ({msi_addr_x_i[fiv_i], 2'b0});
        mem_req_o.aw.len        = 8'd0;         // MSI writes only 32 bits
        mem_req_o.aw.size       = 3'b010;       // 4-bytes beat
        mem_req_o.aw.burst      = axi_pkg::BURST_FIXED;
        mem_req_o.aw.lock       = '0;
        mem_req_o.aw.cache      = '0;
        mem_req_o.aw.prot       = '0;
        mem_req_o.aw.qos        = '0;
        mem_req_o.aw.region     = '0;
        mem_req_o.aw.atop       = '0;
        mem_req_o.aw.user       = '0;

        mem_req_o.aw_valid      = 1'b0;

        // W
        mem_req_o.w.data        = (is_cq_int_q) ? (msi_data_x_i[civ_i]) : (msi_data_x_i[fiv_i]); // set accordingly to the cause
        /* verilator lint_on WIDTH */
        mem_req_o.w.strb        = '1;
        mem_req_o.w.last        = 1'b0;
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar.id         = 4'b0011;
        mem_req_o.ar.addr       = '0;                   // we never read here
        mem_req_o.ar.len        = '0;
        mem_req_o.ar.size       = 3'b011;
        mem_req_o.ar.burst      = axi_pkg::BURST_FIXED;
        mem_req_o.ar.lock       = '0;
        mem_req_o.ar.cache      = '0;
        mem_req_o.ar.prot       = '0;
        mem_req_o.ar.qos        = '0;
        mem_req_o.ar.region     = '0;
        mem_req_o.ar.user       = '0;

        mem_req_o.ar_valid      = 1'b0;                 // we never read here

        // R
        mem_req_o.r_ready       = 1'b0;                 // we never read here

        msi_write_error_o       = 1'b0;

        state_n         = state_q;
        wr_state_n      = wr_state_q;
        is_cq_int_n     = is_cq_int_q;
        edged_cip_n     = edged_cip_q;
        edged_fip_n     = edged_fip_q;
        pending_n       = pending_q;

        case (state_q)
            
            // Monitor interrupt-pending bits. Select corresponding vector (addr, data and mask).
            IDLE: begin

                // If the IOMMU does not support or use MSI as IG mechanism, do nothing
                if (msi_ig_enabled_i) begin

                    // Send CQ pending messages if the mask was cleared
                    if (pending_q[civ_i] && !msi_vec_masked_x_i[civ_i]) begin
                            is_cq_int_n         = 1'b1;
                            pending_n[civ_i]    = 1'b0;
                            state_n             = WRITE;
                    end

                    // Send FQ pending messages if the mask was cleared
                    else if (pending_q[fiv_i] && !msi_vec_masked_x_i[fiv_i]) begin
                            is_cq_int_n         = 1'b0;
                            pending_n[fiv_i]    = 1'b0;
                            state_n             = WRITE;
                    end

                    // CQ Interrupt
                    else if (cip_i && !edged_cip_q) begin
                        
                        // We do not attribute cip_i directly to avoid missing 
                        // any IP bit transition while sending another interrupt.
                        edged_cip_n = 1'b1;

                        // cip bit was set in the last cycle, send MSI if vector is not masked
                        if (!msi_vec_masked_x_i[civ_i]) begin
                            is_cq_int_n = 1'b1;
                            state_n     = WRITE;
                        end

                        // if vector is masked, then save request
                        else begin
                            pending_n[civ_i]    = 1'b1;
                        end
                    end

                    // FQ Interrupt
                    else if (fip_i && !edged_fip_q) begin

                        // We do not attribute fip_i directly to avoid missing 
                        // any IP bit transition while sending another interrupt.
                        edged_fip_n = 1'b1;

                        // fip bit was set in the last cycle, send MSI if vector is not masked
                        if (!msi_vec_masked_x_i[fiv_i]) begin
                            is_cq_int_n = 1'b0;
                            state_n     = WRITE;
                        end

                        // if vector is masked, then save request for FQ
                        else begin
                            pending_n[fiv_i]    = 1'b1;
                        end
                    end

                    // Clear edged IP bits when input is clear
                    if (!cip_i && edged_cip_q) begin
                        edged_cip_n = 1'b0;
                    end
                    if (!fip_i && edged_fip_q) begin
                        edged_fip_n = 1'b0;
                    end
                end
            end 

            // Write MSI to the corresponding address
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
                        mem_req_o.w.last    = 1'b1;

                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end

                    // Check response code
                    B_RESP: begin
                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            state_n             = IDLE;
                            wr_state_n  = AW_REQ;

                            // TODO: IOPMP access faults are reported as AXI faults. We need a way to
                            // TODO: differentiate these faults from normal AXI faults.
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                // AXI error
                                state_n = ERROR;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // We may receive an AXI or access error when writing
            ERROR: begin
                msi_write_error_o   = 1'b1;
                state_n             = IDLE;
            end

            default: state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : sequential_logic
        
        if (~rst_ni) begin
            // Reset values
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;
            is_cq_int_q     <= 1'b0;
            edged_cip_q     <= 1'b0;
            edged_fip_q     <= 1'b0;
            pending_q       <= '0;
        end

        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;
            is_cq_int_q     <= is_cq_int_n;
            edged_cip_q     <= edged_cip_n;
            edged_fip_q     <= edged_fip_n;
            pending_q       <= pending_n;
        end
    end
    
endmodule