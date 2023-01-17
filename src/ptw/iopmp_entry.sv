// Copyright 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Moritz Schneider, ETH Zurich
//         Andreas Kuster, <kustera@ethz.ch>
// Description: Single PMP entry

`timescale 1ns / 1ps

module pmp_entry #(
    parameter int unsigned PLEN           = 56,
    parameter int unsigned PMP_LEN        = 54,
    // 0 = 4bytes NA4 / 8bytes NAPOT (default), 1 = 16 byte NAPOT, 2 = 32 byte NAPOT, 3 = 64 byte NAPOT, etc.
    parameter int unsigned PMPGranularity = 2
) (
    // Input
    input  logic                  [   PLEN-1:0] addr_i,            // address to be verified
    // Configuration
    input  logic                  [PMP_LEN-1:0] addr_reg_i,        // address register 
    input  logic                  [PMP_LEN-1:0] addr_reg_prev_i,   // address register of previous entry
    input  riscv::pmp_addr_mode_t               conf_addr_mode_i,  // address matching mode
    // Output
    output logic                                match_o
);

  logic [PMP_LEN-1:0] addr_reg_mod;
  logic [PMP_LEN-1:0] addr_reg_prev_mod;

  always_comb begin

    // default
    addr_reg_mod = addr_reg_i;
    addr_reg_prev_mod = addr_reg_prev_i;

    // riscv::OFF or riscv::TOR -> force 0 for bits [G-1:0] where G is the granularity
    if(conf_addr_mode_i == riscv::OFF | conf_addr_mode_i == riscv::TOR) begin
      addr_reg_mod[PMPGranularity-1:0] = {PMPGranularity{1'b0}};
      addr_reg_prev_mod = {PMPGranularity{1'b0}}; //? Shouldn't be addr_reg_prev_mod[PMPGranularity-1:0] ?
    end

    // riscv::NAPOT -> force 1 for bits [G-2:0] where G is the granularity
    // 2 should be 16-byte, 3 should be 32-bytes, etc.
    else if (conf_addr_mode_i == riscv::NAPOT) begin
      addr_reg_mod[PMPGranularity-2:0] = {(PMPGranularity - 1) {1'b1}};
      addr_reg_prev_mod = {(PMPGranularity - 1) {1'b1}};
    end
  end

  logic [PLEN-1:0] conf_addr_n;
  logic [$clog2(PLEN)-1:0] trail_ones;  // where the number of trailing ones will be saved
  assign conf_addr_n = ~addr_reg_mod;   // we negate to count trailing ones

/// A trailing zero counter / leading zero counter.
/// Set MODE to 0 for trailing zero counter => cnt_o is the number of trailing zeros (from the LSB)
/// Set MODE to 1 for leading zero counter  => cnt_o is the number of leading zeros  (from the MSB)
/// If the input does not contain a zero, `empty_o` is asserted. Additionally `cnt_o` contains
/// the maximum number of zeros - 1. For example:
///   in_i = 000_0000, empty_o = 1, cnt_o = 6 (mode = 0)
///   in_i = 000_0001, empty_o = 0, cnt_o = 0 (mode = 0)
///   in_i = 000_1000, empty_o = 0, cnt_o = 3 (mode = 0)
  lzc #(
      .WIDTH(PLEN),
      .MODE (1'b0)
  ) i_lzc (
      .in_i   (conf_addr_n),
      .cnt_o  (trail_ones),
      .empty_o()
  );

  always_comb begin
    case (conf_addr_mode_i)
      riscv::TOR: begin
        // check whether the requested address is in between the two configuration addresses
        if (addr_i >= (addr_reg_prev_mod << 2) && addr_i < (addr_reg_mod << 2)) begin
          match_o = 1'b1;
        end else match_o = 1'b0;

`ifdef FORMAL
        if (match_o == 0) begin
          assert (addr_i >= (addr_reg_mod << 2) || addr_i < (addr_reg_prev_mod << 2));
        end else begin
          assert (addr_i < (addr_reg_mod << 2) && addr_i >= (addr_reg_prev_mod << 2));
        end
`endif
      end
      riscv::NA4, riscv::NAPOT: begin

        if (conf_addr_mode_i == riscv::NA4 && PMPGranularity > 2) begin
          //? Spec defines "not selectable for G >= 1"
          match_o = 1'b0;  // not selectable for G > 2
        end else begin

          logic [PLEN-1:0] base;
          logic [PLEN-1:0] mask;
          int unsigned size;

          // NA4 => yyyy...yyyy00
          if (conf_addr_mode_i == riscv::NA4) begin
            size = 2;
          end 
          
          else begin
            // use the extracted trailing ones
            size = trail_ones + 3;
          end

          mask = '1 << size;
          base = (addr_reg_mod << 2) & mask;
          match_o = (addr_i & mask) == base ? 1'b1 : 1'b0;

`ifdef FORMAL  // TODO: update them to support granularity in the calculation
          // size extract checks
          assert (size >= 2);
          if (conf_addr_mode_i == riscv::NAPOT) begin
            assert (size > 2);
            if (size < PMP_LEN) assert (addr_reg_mod[size-3] == 0);
            for (int i = 0; i < PMP_LEN; i++) begin
              if (size > 3 && i <= size - 4) begin
                assert (addr_reg_mod[i] == 1);  // check that all the rest are ones
              end
            end
          end

          if (size < PLEN - 1) begin
            if (base + 2 ** size > base) begin  // check for overflow
              if (match_o == 0) begin
                assert (addr_i >= base + 2 ** size || addr_i < base);
              end else begin
                assert (addr_i < base + 2 ** size && addr_i >= base);
              end
            end else begin
              if (match_o == 0) begin
                assert (addr_i - 2 ** size >= base || addr_i < base);
              end else begin
                assert (addr_i - 2 ** size < base && addr_i >= base);
              end
            end
          end
`endif
        end
      end
      riscv::OFF: match_o = 1'b0;
      default:    match_o = 0;
    endcase
  end

endmodule
