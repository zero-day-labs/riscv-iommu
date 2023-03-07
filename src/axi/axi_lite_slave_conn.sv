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
// Description: AXI slave to (req_t, resp_t) pair connector (pulp-platform interface)
//
// Modified by: Manuel Rodríguez <manuel.cederog@gmail.com>
// Modified at: 24/10/2022
//
// Adapted to be an AXI4-Lite connector
//

`include "include/typedef_global.svh"

module axi_lite_slave_conn #(
    // width of data bus in bits
    parameter int unsigned DATA_WIDTH   = 64,
    // width of address bus in bits
    parameter int unsigned ADDR_WIDTH   = 64,
    // width of strobe (width of data bus in words)
    parameter int unsigned STRB_WIDTH   = (DATA_WIDTH / 8)
) (
    //
    // Write address channel
    //
    input  logic     [  ADDR_WIDTH-1:0] s_axil_awaddr,
    input  logic     [             2:0] s_axil_awprot,
    input  logic                        s_axil_awvalid,
    output logic                        s_axil_awready,
    //
    // Write data channel
    //
    input  logic     [  DATA_WIDTH-1:0] s_axil_wdata,
    input  logic     [  STRB_WIDTH-1:0] s_axil_wstrb,
    input  logic                        s_axil_wvalid,
    output logic                        s_axil_wready,
    //
    // Write response channel
    //
    output logic     [             1:0] s_axil_bresp,
    output logic                        s_axil_bvalid,
    input  logic                        s_axil_bready,
    //
    // Read address channel
    //
    input  logic     [  ADDR_WIDTH-1:0] s_axil_araddr,
    input  logic     [             2:0] s_axil_arprot,
    input  logic                        s_axil_arvalid,
    output logic                        s_axil_arready,
    //
    // Read data channel
    //
    output logic     [  DATA_WIDTH-1:0] s_axil_rdata,
    output logic     [             1:0] s_axil_rresp,
    output logic                        s_axil_rvalid,
    input  logic                        s_axil_rready,

    //
    // AXI request/response pair
    //
    output axi_lite_req_t               axi_lite_req_o,
    input  axi_lite_rsp_t               axi_lite_rsp_i
);

  //
  // Write address channel
  //
  assign axi_lite_req_o.aw.addr   = s_axil_awaddr;
  assign axi_lite_req_o.aw.prot   = s_axil_awprot;
  assign axi_lite_req_o.aw_valid  = s_axil_awvalid;
  assign s_axil_awready           = axi_lite_rsp_i.aw_ready;

  //
  // Write data channel
  //
  assign axi_lite_req_o.w.data    = s_axil_wdata;
  assign axi_lite_req_o.w.strb    = s_axil_wstrb;
  assign axi_lite_req_o.w_valid   = s_axil_wvalid;
  assign s_axil_wready            = axi_lite_rsp_i.w_ready;

  //
  // Write response channel
  //
  assign s_axil_bresp             = axi_lite_rsp_i.b.resp;
  assign s_axil_bvalid            = axi_lite_rsp_i.b_valid;
  assign axi_lite_req_o.b_ready   = s_axil_bready;

  //
  // Read address channel
  //
  assign axi_lite_req_o.ar.addr   = s_axil_araddr;
  assign axi_lite_req_o.ar.prot   = s_axil_arprot;
  assign axi_lite_req_o.ar_valid  = s_axil_arvalid;
  assign s_axil_arready           = axi_lite_rsp_i.ar_ready;

  //
  // Read data channel
  //
  assign s_axil_rdata             = axi_lite_rsp_i.r.data;
  assign s_axil_rresp             = axi_lite_rsp_i.r.resp;
  assign s_axil_rvalid            = axi_lite_rsp_i.r_valid;
  assign axi_lite_req_o.r_ready   = s_axil_rready;

endmodule