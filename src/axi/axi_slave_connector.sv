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

module axi_slave_connector #(
    // width of data bus in bits
    parameter int unsigned DATA_WIDTH   = 32,
    // width of address bus in bits
    parameter int unsigned ADDR_WIDTH   = 32,
    // width of strobe (width of data bus in words)
    parameter int unsigned STRB_WIDTH   = (DATA_WIDTH / 8),
    // width of id signal
    parameter int unsigned ID_WIDTH     = 8,
    // width of awuser signal
    parameter int unsigned AWUSER_WIDTH = 1,
    // width of wuser signal
    parameter int unsigned WUSER_WIDTH  = 1,
    // width of buser signal
    parameter int unsigned BUSER_WIDTH  = 1,
    // width of aruser signal
    parameter int unsigned ARUSER_WIDTH = 1,
    // width of ruser signal
    parameter int unsigned RUSER_WIDTH  = 1,
    // AXI request/response
    parameter type         axi_req_t    = logic,
    parameter type         axi_rsp_t    = logic
) (
    //
    // Write address channel
    //
    input  logic     [    ID_WIDTH-1:0] s_axi_awid,
    input  logic     [  ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic     [             7:0] s_axi_awlen,
    input  logic     [             2:0] s_axi_awsize,
    input  logic     [             1:0] s_axi_awburst,
    input  logic                        s_axi_awlock,
    input  logic     [             3:0] s_axi_awcache,
    input  logic     [             2:0] s_axi_awprot,
    input  logic     [             3:0] s_axi_awqos,
    input  logic     [             3:0] s_axi_awregion,
    input  logic     [AWUSER_WIDTH-1:0] s_axi_awuser,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,
    //
    // Write data channel
    //
    input  logic     [  DATA_WIDTH-1:0] s_axi_wdata,
    input  logic     [  STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic     [ WUSER_WIDTH-1:0] s_axi_wuser,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,
    //
    // Write response channel
    //
    output logic     [    ID_WIDTH-1:0] s_axi_bid,
    output logic     [             1:0] s_axi_bresp,
    output logic     [ BUSER_WIDTH-1:0] s_axi_buser,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,
    //
    // Read address channel
    //
    input  logic     [    ID_WIDTH-1:0] s_axi_arid,
    input  logic     [  ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic     [             7:0] s_axi_arlen,
    input  logic     [             2:0] s_axi_arsize,
    input  logic     [             1:0] s_axi_arburst,
    input  logic                        s_axi_arlock,
    input  logic     [             3:0] s_axi_arcache,
    input  logic     [             2:0] s_axi_arprot,
    input  logic     [             3:0] s_axi_arqos,
    input  logic     [             3:0] s_axi_arregion,
    input  logic     [ARUSER_WIDTH-1:0] s_axi_aruser,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,
    //
    // Read data channel
    //
    output logic     [    ID_WIDTH-1:0] s_axi_rid,
    output logic     [  DATA_WIDTH-1:0] s_axi_rdata,
    output logic     [             1:0] s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic     [ RUSER_WIDTH-1:0] s_axi_ruser,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,
    //
    // AXI request/response pair
    //
    output axi_req_t                    axi_req_o,
    input  axi_rsp_t                    axi_rsp_i
);

  //
  // Write address channel
  //
  assign axi_req_o.aw.id     = s_axi_awid;
  assign axi_req_o.aw.addr   = s_axi_awaddr;
  assign axi_req_o.aw.len    = s_axi_awlen;
  assign axi_req_o.aw.size   = s_axi_awsize;
  assign axi_req_o.aw.burst  = s_axi_awburst;
  assign axi_req_o.aw.lock   = s_axi_awlock;
  assign axi_req_o.aw.cache  = s_axi_awcache;
  assign axi_req_o.aw.prot   = s_axi_awprot;
  assign axi_req_o.aw.qos    = s_axi_awqos;
  assign axi_req_o.aw.atop   = {$bits(axi_req_o.aw.atop) {1'b0}};  // hardwire to zero
  assign axi_req_o.aw.region = s_axi_awregion;
  assign axi_req_o.aw.user   = s_axi_awuser;
  assign axi_req_o.aw_valid  = s_axi_awvalid;
  assign s_axi_awready       = axi_rsp_i.aw_ready;

  //
  // Write data channel
  //
  assign axi_req_o.w.data    = s_axi_wdata;
  assign axi_req_o.w.strb    = s_axi_wstrb;
  assign axi_req_o.w.last    = s_axi_wlast;
  assign axi_req_o.w.user    = s_axi_wuser;
  assign axi_req_o.w_valid   = s_axi_wvalid;
  assign s_axi_wready        = axi_rsp_i.w_ready;

  //
  // Write response channel
  //
  assign s_axi_bid           = axi_rsp_i.b.id;
  assign s_axi_bresp         = axi_rsp_i.b.resp;
  assign s_axi_bvalid        = axi_rsp_i.b_valid;
  assign s_axi_buser         = axi_rsp_i.b.user;
  assign axi_req_o.b_ready   = s_axi_bready;

  //
  // Read address channel
  //
  assign axi_req_o.ar.id     = s_axi_arid;
  assign axi_req_o.ar.addr   = s_axi_araddr;
  assign axi_req_o.ar.len    = s_axi_arlen;
  assign axi_req_o.ar.size   = s_axi_arsize;
  assign axi_req_o.ar.burst  = s_axi_arburst;
  assign axi_req_o.ar.lock   = s_axi_arlock;
  assign axi_req_o.ar.cache  = s_axi_arcache;
  assign axi_req_o.ar.prot   = s_axi_arprot;
  assign axi_req_o.ar.qos    = s_axi_arqos;
  assign axi_req_o.ar.region = s_axi_arregion;
  assign axi_req_o.ar.user   = s_axi_aruser;
  assign axi_req_o.ar_valid  = s_axi_arvalid;
  assign s_axi_arready       = axi_rsp_i.ar_ready;

  //
  // Read data channel
  //
  assign s_axi_rid           = axi_rsp_i.r.id;
  assign s_axi_rdata         = axi_rsp_i.r.data;
  assign s_axi_rresp         = axi_rsp_i.r.resp;
  assign s_axi_rlast         = axi_rsp_i.r.last;
  assign s_axi_rvalid        = axi_rsp_i.r_valid;
  assign s_axi_ruser         = axi_rsp_i.r.user;
  assign axi_req_o.r_ready   = s_axi_rready;

endmodule
