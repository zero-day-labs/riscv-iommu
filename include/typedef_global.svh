// Global include file for register interface and AXI typedef structures
// Created for particular use in development process
//

`include "include/typedef_reg.svh"
`include "include/typedef_axi.svh"
`include "packages/axi_pkg.sv"

`ifndef GLOBAL_TYPEDEF_SVH
`define GLOBAL_TYPEDEF_SVH

typedef logic [64-1:0]  addr_t;
typedef logic [64-1:0]  data_t;
typedef logic [8-1:0]   strb_t;

// Define reg_req_t and reg_rsp_t structs
`REG_BUS_TYPEDEF_ALL(reg, addr_t, data_t, strb_t)

// Define axi_lite_req_t and axi_lite_rsp_t structs
`AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)

`endif