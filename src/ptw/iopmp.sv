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
// Description: Purely combinatorial PMP unit (with extraction for more complex configs such as NAPOT)

`timescale 1ns / 1ps

module pmp #(
    parameter int unsigned PLEN           = 56,  // rv32: 34
    parameter int unsigned PMP_LEN        = 54,  // rv32: 32
    parameter int unsigned NR_ENTRIES     = 16,
    // 0 = 4bytes NA4 / 8bytes NAPOT (default), 1 = 16 byte NAPOT, 2 = 32 byte NAPOT, 3 = 64 byte NAPOT, etc.
    parameter int unsigned PMPGranularity = 2
) (
    // Input
    input  logic               [PLEN-1:0]              addr_i,        // input address to be checked
    input  riscv::pmp_access_t                         access_type_i, // requested access type
    input  riscv::priv_lvl_t                           priv_lvl_i,    // requested priv level
    // Configuration
    //? Shouldn't be NR_ENTRIES-1 instead of 15 ?
    input  logic               [    15:0][PMP_LEN-1:0] addr_reg_i,    // 54-bit address registers (bits [55:2] of physical address)
    input  riscv::pmpcfg_t     [    15:0]              conf_reg_i,    // 8-bit config registers
    // Output
    output logic                                       allow_o
);
  // if there are no PMPs we can always grant the access.
  if (NR_ENTRIES > 0) begin : gen_pmp
    logic [NR_ENTRIES-1:0] match;

    for (genvar i = 0; i < NR_ENTRIES; i++) begin
      logic [PMP_LEN-1:0] addr_reg_prev;

      assign addr_reg_prev = (i == 0) ? '0 : addr_reg_i[i-1];

      pmp_entry #(
          .PLEN           (PLEN),
          .PMP_LEN        (PMP_LEN),
          .PMPGranularity (PMPGranularity)
      ) i_pmp_entry (
          .addr_i           (addr_i),
          .addr_reg_i       (addr_reg_i[i]),
          .conf_addr_prev_i (addr_reg_prev),
          .conf_addr_mode_i (conf_reg_i[i].addr_mode),
          .match_o          (match[i])
      );
    end

    always_comb begin
      int i;

      allow_o = 1'b0;
      for (i = 0; i < NR_ENTRIES; i++) begin
        // Check must be performed for S and U modes, or for all modes if L=1
        if (priv_lvl_i != riscv::PRIV_LVL_M || conf_reg_i[i].locked) begin
          if (match[i]) begin   //? I think this condition should be first, or in the same if
            // check access types
            if ((access_type_i & conf_reg_i[i].access_type) != access_type_i) allow_o = 1'b0;
            else allow_o = 1'b1;
            break;
          end
        end
      end

      // no PMP entry matched the address (it's impossible to match the same address with two PMP entries)
      if (i == NR_ENTRIES) begin
        // allow all accesses from M-mode for no pmp match
        if (priv_lvl_i == riscv::PRIV_LVL_M) allow_o = 1'b1;
        // disallow accesses for all other modes
        else
          allow_o = 1'b0;
      end
    end
  end else assign allow_o = 1'b1;

`ifdef FORMAL
  always @(*) begin
    if (priv_lvl_i == riscv::PRIV_LVL_M) begin
      static logic no_locked = 1'b1;
      for (int i = 0; i < NR_ENTRIES; i++) begin
        if (conf_reg_i[i].locked && conf_reg_i[i].addr_mode != riscv::OFF) begin
          no_locked &= 1'b0;
        end else no_locked &= 1'b1;
      end

      if (no_locked == 1'b1) assert (allow_o == 1'b1);
    end
  end
`endif
endmodule
