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
// Date:    09/12/2023
//
// Description: Handler for MSI translations in MRIF mode
//              Modifies the destination MRIF using read-modify-write operations.
//              Sends a notice MSI using the data provided by the MSI PTE if the IE bit 
//                  corresponding to the interrupt identity being processed is set.
//

/*
    -   This module receives the interrupt identity and the base address of the destination MRIF.
        It computes the address of the IP and IE bits corresponding to the interrupt identity within the MRIF and fetches both DWs.
        Then, it sets the corresponding IP bit and checks whether the IE bit is set.
        Finally, only the IP DW is written back to the MRIF.

    -   If the IE bit was NOT set, the processing ends here, as there is no need to send the 
            notice MSI because the corresponding interrupt is not enabled.

    -   Otherwise, if the IE bit was set, a notice MSI is sent using the input NID and NPPN.
*/

module rv_iommu_mrif_handler #(
    
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

    // Init MRIF processing. MSI data and MRIF cache data are valid.
    input  logic        init_mrif_i,
    // Abort access (discard without fault)
    output logic        ignore_o,

    // Interrupt identity (MSI data)
    input  logic [31:0] int_id_i,

    // MRIF cache data
    input  logic [46:0] mrif_addr_i,
    input  logic [10:0] notice_nid_i,
    input  logic [43:0] notice_ppn_i,

    // Error signaling
    output logic                                error_o,
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_o
);

    // States
    typedef enum logic [2:0] {
        IDLE,           // 000
        MEM_ACCESS,     // 001
        FETCH_MRIF,     // 010
        WRITE_MRIF,     // 011
        WRITE_NOTICE,   // 100
        ERROR           // 101
    } state_mrif_handler_t;
    state_mrif_handler_t state_q, state_n;

    // Write FSM states
    typedef enum logic [1:0] {
        AW_REQ,
        W_DATA,
        B_RESP
    } mrif_write_t;
    mrif_write_t wr_state_q, wr_state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] pptr_q, pptr_n;

    // MRIF IP register
    logic [63:0] mrif_ip_q, mrif_ip_n;
    // MRIF IE register
    logic [63:0] mrif_ie_q, mrif_ie_n;
    // Interrupt ID register
    logic [10:0] int_id_q, int_id_n;
    // Notice PPN register
    logic [43:0] notice_ppn_q, notice_ppn_n;
    // Notice NID register
    logic [43:0] notice_nid_q, notice_nid_n;

    // To wait for last AXI beat
    logic wait_rlast_q, wait_rlast_n;

    // Interrupt identity bit
    logic [63:0]    int_id_bit;
    assign          int_id_bit   = (1 << int_id_q[5:0]);

    assign error_o  = (state_q == ERROR);
    assign cause_o  = rv_iommu::MSI_PT_DATA_CORRUPTION;

    always_comb begin : mrif_handler_comb

        // Default assignments
        // Wires

        // Output signals
        // AXI signals
        // AW
        mem_req_o.aw.id                     = 4'b0011;
        mem_req_o.aw.addr[riscv::PLEN-1:0]  = pptr_q;                  // Variable: MRIF and notice MSI
        mem_req_o.aw.len                    = 8'b0;                    // One beat
        mem_req_o.aw.size                   = 3'b011;                  // Variable: 64 bits for MRIF IP DW, 32 bits for notice MSI
        mem_req_o.aw.burst                  = axi_pkg::BURST_INCR;
        mem_req_o.aw.lock                   = '0;
        mem_req_o.aw.cache                  = '0;
        mem_req_o.aw.prot                   = '0;
        mem_req_o.aw.qos                    = '0;
        mem_req_o.aw.region                 = '0;
        mem_req_o.aw.atop                   = '0;
        mem_req_o.aw.user                   = '0;

        mem_req_o.aw_valid   = 1'b0;

        // W
        mem_req_o.w.data     = '0;
        mem_req_o.w.strb     = '1;
        mem_req_o.w.last     = '0;
        mem_req_o.w.user     = '0;

        mem_req_o.w_valid    = 1'b0;

        // B
        mem_req_o.b_ready    = 1'b0;

        // AR
        mem_req_o.ar.id                     = 4'b0100;
        mem_req_o.ar.addr[riscv::PLEN-1:0]  = pptr_q;               // Physical address to access
        mem_req_o.ar.len                    = 8'b1;                 // Two beats
        mem_req_o.ar.size                   = 3'b011;               // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst                  = axi_pkg::BURST_INCR;  // Incremental addresses
        mem_req_o.ar.lock                   = '0;
        mem_req_o.ar.cache                  = '0;
        mem_req_o.ar.prot                   = '0;
        mem_req_o.ar.qos                    = '0;
        mem_req_o.ar.region                 = '0;
        mem_req_o.ar.user                   = '0;

        mem_req_o.ar_valid  = 1'b0;

        // R
        mem_req_o.r_ready   = 1'b0;

        ignore_o         = 1'b0;

        // Next values
        state_n         = state_q;
        wr_state_n      = wr_state_q;
        wait_rlast_n    = wait_rlast_q;
        mrif_ip_n       = mrif_ip_q;
        mrif_ie_n       = mrif_ie_q;
        int_id_n        = int_id_q;
        notice_ppn_n    = notice_ppn_q;
        pptr_n          = pptr_q;

        case (state_q)

            // Validate the interrupt identity and calculate the offset of the IP and IE DWs within the MRIF
            // Update pptr
            IDLE: begin

                // Trigger MRIF processing
                if (init_mrif_i) begin

                    wait_rlast_n    = 1'b0;

                    // Validate interrupt identity
                    if (!(|int_id_i[31:11])) begin
                        
                        // Offset within the MRIF is determined by the interrupt identity
                        pptr_n          = {mrif_addr_i, int_id_i[10:6], 4'b0};
                        int_id_n        = int_id_i[10:0];   // Propagate MSI data (AWDATA)
                        notice_ppn_n    = notice_ppn_i;     // Propagate notice PPN
                        notice_nid_n    = notice_nid_i;     // Propagate notice NID
                        state_n         = MEM_ACCESS;
                    end
                end
            end

            // Access memory to fetch IP and IE DWs
            MEM_ACCESS: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;
                
                // wait for AXI Bus to accept the request
                if (mem_resp_i.ar_ready) begin
                    state_n = FETCH_MRIF;
                end
            end

            // Register the IP and IE DWs. Set the corresponding IP bit
            FETCH_MRIF: begin
                
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    
                    // Second DW: IE
                    if (mem_resp_i.r.last) begin

                        // Save IE DW
                        mrif_ie_n   = mem_resp_i.r.data;

                        // If the IP bit corresponding to the interrupt ID is already set, there is no need to write back the IP DW to the MRIF
                        if (|(mrif_ip_q & int_id_bit)) begin
                            
                            // If the IE bit corresponding to the interrupt ID is not set, there is no need to send the MSI notice
                            // IE bit set. Send MSI notice
                            if (|(mem_resp_i.r.data & int_id_bit)) begin
                                state_n     = WRITE_NOTICE;
                                wr_state_n  = AW_REQ;
                            end

                            // IE bit clear. Go back to IDLE
                            else begin
                                state_n = IDLE;
                            end
                        end

                        // IP bit is not set, write back the IP DW
                        else begin
                            state_n     = WRITE_MRIF;
                            wr_state_n  = AW_REQ;
                        end
                    end

                    // First DW: IP
                    else begin
                        // Set IP bit and save DW
                        mrif_ip_n = mem_resp_i.r.data;
                    end

                    // Check for AXI errors
                    if (mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
                        wait_rlast_n    = ~mem_resp_i.r.last;
                        state_n         = ERROR;
                    end
                end
            end

            // Write back the IP DW to the MRIF.
            // Check whether the corresponding IE bit is enable
            WRITE_MRIF: begin

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
                        mem_req_o.w.data    = mrif_ip_q | int_id_bit;

                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end

                    // Check response code
                    B_RESP: begin

                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            wr_state_n  = AW_REQ;

                            // Check IE bit to determine whether to send notice MSI
                            state_n = (|(mrif_ie_q & int_id_bit)) ? (WRITE_NOTICE) : (IDLE);

                            // AXI error
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n = ERROR;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            // If the IE bit corresponding to the given interrupt identity was set,
            //  send MSI notice using input NID and NPPN.
            WRITE_NOTICE: begin
                
                case (wr_state_q)

                    // Send request to AW Channel
                    AW_REQ: begin

                        mem_req_o.aw_valid                  = 1'b1;
                        mem_req_o.aw.addr[riscv::PLEN-1:0]  = {notice_ppn_q, 12'b0};    // Notice MSI address
                        mem_req_o.aw.size                   = 3'b010;                   // 32 bits for notice MSI

                        if (mem_resp_i.aw_ready) begin
                            wr_state_n  = W_DATA;
                        end
                    end

                    // Send data through W channel
                    W_DATA: begin
                        
                        mem_req_o.w_valid       = 1'b1;
                        mem_req_o.w.strb        = 8'b0000_1111;
                        mem_req_o.w.last        = 1'b1;
                        mem_req_o.w.data[31:0]  = {21'b0, notice_nid_q};

                        if(mem_resp_i.w_ready) begin
                            wr_state_n  = B_RESP;
                        end
                    end

                    // Check response code
                    B_RESP: begin

                        if (mem_resp_i.b_valid) begin
                            
                            mem_req_o.b_ready   = 1'b1;
                            state_n             = IDLE;

                            // AXI error
                            if (mem_resp_i.b.resp != axi_pkg::RESP_OKAY) begin
                                state_n         = ERROR;
                            end
                        end
                    end

                    default: state_n = IDLE;
                endcase
            end

            ERROR: begin

                mem_req_o.r_ready   = 1'b1;

                // Check whether we have to wait for AXI transmission to end
                if ((wait_rlast_q && mem_resp_i.r.last) || !wait_rlast_q) begin
                    state_n = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase
    end : mrif_handler_comb

    //# MSI-FLAT Sequential Block
    always_ff @(posedge clk_i or negedge rst_ni) begin : mrif_handler_seq

        if (~rst_ni) begin
            state_q         <= IDLE;
            wr_state_q      <= AW_REQ;

            pptr_q          <= '0;
            wait_rlast_q    <= 1'b0;
            mrif_ip_q       <= '0;
            mrif_ie_q       <= '0;
            int_id_q        <= '0;
        end 
        
        else begin
            state_q         <= state_n;
            wr_state_q      <= wr_state_n;

            pptr_q          <= pptr_n;
            wait_rlast_q    <= wait_rlast_n;
            mrif_ip_q       <= mrif_ip_n;
            mrif_ie_q       <= mrif_ie_n;
            int_id_q        <= int_id_n;
            notice_ppn_q    <= notice_ppn_n;
            notice_nid_q    <= notice_nid_n;
        end
    end : mrif_handler_seq
    
endmodule