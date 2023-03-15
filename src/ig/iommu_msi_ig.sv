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
    Date: 08/03/2023

    Description: RISC-V IOMMU MSI Interrupt Generation Module.
*/

//! NOTES:
/*
    -   Interrupt generation is triggered on a possitive transition of cip or fip.
    -   Since we only have two possible interrupt sources for now, we use some bits to monitor possitive 
        transitions of cip or fip independently, so if a transition of fip occurs while processing a CQ interrupt,
        it is not lost.
    -   The IOMMU must not send MSIs for interrupt vectors with mask M = 1. These messages must be saved and later sent if
        the corresponding mask is cleared to 0.
    -   A register could be used for each source to save messages from vectors with M = 1 (Remember that the same vector 
        can be used by different sources. That's why we can have more than one pending message per vector).
*/

module iommu_msi_ig (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic msi_ig_enabled_i,

    // Interrupt pending bits
    input  logic cip_i,
    input  logic fip_i,

    // Interrupt vectors
    input  logic [3:0]  civ_i,
    input  logic [3:0]  fiv_i,

    // MSI config table
    input  logic [53:0] msi_addr_x_i[16],
    input  logic [31:0] msi_data_x_i[16],
    input  logic        msi_vec_masked_x_i[16],

    // MSI write error
    output logic        msi_write_error_o,

    // AXI Master interface to write to memory
    input  ariane_axi_pkg::resp_t       mem_resp_i,
    output ariane_axi_pkg::req_t        mem_req_o
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

    // CQ interrupt message pending
    logic   cq_pending_q, cq_pending_n;

    // FQ interrupt message pending
    logic   fq_pending_q, fq_pending_n;

    always_comb begin : int_generation_fsm

        // Default values
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0010;
        mem_req_o.aw.addr       = (is_cq_int_q) ? ({msi_addr_x_i[civ_i], 2'b0}) : ({msi_addr_x_i[fiv_i], 2'b0});
        mem_req_o.aw.len        = 8'd0;         // MSI writes only 64 bits
        mem_req_o.aw.size       = 3'b011;       // 8-bytes beat
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
        mem_req_o.ar.atop       = '0;
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
        cq_pending_n    = cq_pending_q;
        fq_pending_n    = fq_pending_q;

        case (state_q)
            
            // Monitor interrupt-pending bits. Select corresponding vector (addr, data and mask).
            IDLE: begin

                // If the IOMMU does not support or use MSI as IG mechanism, do nothing
                if (!msi_ig_enabled_i) begin
                    // Send CQ pending messages if the mask was cleared
                    if (cq_pending_q && !msi_vec_masked_x_i[civ_i]) begin
                            is_cq_int_n     = 1'b1;
                            cq_pending_n    = 1'b0;
                            state_n         = WRITE;
                    end

                    // Send FQ pending messages if the mask was cleared
                    else if (fq_pending_q && !msi_vec_masked_x_i[fiv_i]) begin
                            is_cq_int_n     = 1'b0;
                            fq_pending_n    = 1'b0;
                            state_n         = WRITE;
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

                        // if vector is masked, then save request for CQ
                        else begin
                            cq_pending_n    = 1'b1;
                        end
                    end

                    // FQ Interrupt
                    else if (fip_i && !edged_fip_q) begin

                        // We do not attribute cip_i directly to avoid missing 
                        // any IP bit transition while sending another interrupt.
                        edged_fip_n = 1'b1;

                        // fip bit was set in the last cycle, send MSI if vector is not masked
                        if (!msi_vec_masked_x_i[fiv_i]) begin
                            is_cq_int_n = 1'b0;
                            state_n     = WRITE;
                        end

                        // if vector is masked, then save request for FQ
                        else begin
                            fq_pending_n    = 1'b1;
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

                            // TODO: Here we also need to check for access errors.
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
            is_cq_int_n     <= 1'b0;
            edged_cip_n     <= 1'b0;
            edged_fip_n     <= 1'b0;
            cq_pending_n    <= 1'b0;
            fq_pending_n    <= 1'b0;
        end

        else begin
            state_n         <= state_q;
            wr_state_n      <= wr_state_q;
            is_cq_int_n     <= is_cq_int_q;
            edged_cip_n     <= edged_cip_q;
            edged_fip_n     <= edged_fip_q;
            cq_pending_n    <= cq_pending_q;
            fq_pending_n    <= fq_pending_q;
        end
    end
    
endmodule