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
// Date: 15/08/2023
//
// Description: AXI4 Boundary Checker module for RISC-V IOMMU: 
//              Checks whether an AXI transaction crosses a 4-kiB address boundary, 
//              which is illegal in AXI4 transactions.

/* verilator lint_off WIDTH */

module axi4_boundary_check (
    // AxVALID
    input  logic                    request_i,
    // AxADDR
    input  logic [riscv::VLEN-1:0]  addr_i,
    // AxBURST
    input  axi_pkg::burst_t         burst_type_i,
    // AxLEN
    input  axi_pkg::len_t           burst_length_i,
    // AxSIZE
    input  axi_pkg::size_t          n_bytes_i,

    // To indicate valid requests or boundary violations
    output logic                    allow_request_o,
    output logic                    bound_violation_o
); 

    always_comb begin : boundary_check

        allow_request_o   = 1'b0;
        bound_violation_o = 1'b0;

        // Request received
        if (request_i) begin

            // Consider burst type, N of beats and size of the beat (always 64 bits) to calculate number of bytes accessed:
            case (burst_type_i)

                // BURST_FIXED: The final address is Start Addr + 8 (ex: ARADDR + 8)
                axi_pkg::BURST_FIXED: begin
                    // May be optimized with bitwise AND
                    if (((addr_i & 12'hfff) + (1'b1 << n_bytes_i)) < (1'b1 << 12)) begin
                        allow_request_o   = 1'b1;     // Allow transaction
                    end

                    // Boundary violation
                    else begin
                        bound_violation_o = 1'b1;
                    end
                end

                // BURST_WRAP: The final address is the Wrap Boundary (Lower address) + size of the transfer
                axi_pkg::BURST_WRAP: begin
                    // wrap_boundary = (start_address/(number_bytes*burst_length_i)) * (number_bytes*burst_length_i)
                    // address_n = wrap_boundary + (number_bytes * burst_length_i)
                    logic [riscv::PLEN-1:0] wrap_boundary;

                    // by spec, N of transfers must be {2, 4, 8, 16}
                    // So, ARLEN must be {1, 3, 7, 15}
                    logic [2:0] log2_len;
                    case (burst_length_i)
                        8'd1: log2_len = 3'b001;
                        8'd3: log2_len = 3'b010;
                        8'd7: log2_len = 3'b011;
                        8'd15: log2_len = 3'b100;
                        default: log2_len = 3'b111;  // invalid
                    endcase

                    // The lowest address within a wrapping burst
                    // Wrap_Boundary = (INT(Start_Address / (Burst_Length x Number_Bytes))) x (Burst_Length x Number_Bytes)
                    wrap_boundary = (addr_i >> (log2_len + n_bytes_i)) << (log2_len + n_bytes_i);

                    // Check if the highest address crosses a 4 kiB boundary (Highest Addr - Lower Addr >= 4kiB)
                    // Highest addr_i = Wrap_Boundary + (Burst_Length x Number_Bytes)
                    if (!(&log2_len) && 
                         (((wrap_boundary & 12'hfff) + ((burst_length_i + 1) << n_bytes_i)) < (1'b1 << 12))) begin
                        allow_request_o  = 1'b1;     // Allow transaction
                    end
                    
                    // Boundary violation
                    else begin
                        bound_violation_o = 1'b1;
                    end

                end

                // BURST_INCR: The final address is Start Addr + Burst_Length x Number_Bytes
                axi_pkg::BURST_INCR: begin
                    // check if burst is within 4K range
                    if (((addr_i & 12'hfff) + ((burst_length_i + 1) << n_bytes_i)) < (1'b1 << 12)) begin
                        allow_request_o  = 1'b1;     // Allow transaction
                    end

                    // Boundary violation
                    else begin
                        bound_violation_o = 1'b1;
                    end
                end

                default:;
            endcase
        end
    end
    
endmodule

/* verilator lint_on WIDTH */