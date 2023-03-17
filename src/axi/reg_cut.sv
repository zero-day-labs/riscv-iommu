// Copyright 2022 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author:      Andreas Kuster, <kustera@ethz.ch>
// Description: Register interface cut (breaks combinatorial paths)

module reg_cut #(
    // make this register transparent
    parameter bit  Bypass    = 1'b0,
    // register interface request/response
    parameter type reg_req_t = logic,
    parameter type reg_rsp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // input
    input  reg_req_t req_in,
    output reg_rsp_t rsp_in,
    // output
    output reg_req_t req_out,
    input  reg_rsp_t rsp_out
);

  if (Bypass) begin : gen_bypass

    // handshake
    assign req_out.valid = req_in.valid;
    assign rsp_in.ready  = rsp_out.ready;

    // data
    assign req_out.addr  = req_in.addr;
    assign req_out.write = req_in.write;
    assign req_out.wdata = req_in.wdata;
    assign req_out.wstrb = req_in.wstrb;
    assign rsp_in.rdata  = rsp_out.rdata;
    assign rsp_in.error  = rsp_out.error;

  end else begin : gen_reg

    always @(posedge clk_i) begin

      if (!rst_ni) begin

        // handshake
        req_out.valid <= 1'b0;
        rsp_in.ready  <= 1'b0;

        // data
        req_out.addr  <= '0;
        req_out.write <= '0;
        req_out.wdata <= '0;
        req_out.wstrb <= '0;
        rsp_in.rdata  <= '0;
        rsp_in.error  <= '0;

      end else begin

        // handshake
        req_out.valid <= req_in.valid;
        rsp_in.ready  <= rsp_out.ready;

        // data
        req_out.addr  <= req_in.addr;
        req_out.write <= req_in.write;
        req_out.wdata <= req_in.wdata;
        req_out.wstrb <= req_in.wstrb;
        rsp_in.rdata  <= rsp_out.rdata;
        rsp_in.error  <= rsp_out.error;

      end
    end
  end

endmodule
