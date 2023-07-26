// Global include file for register interface and AXI typedef structures
// Created for particular use in development process
//

`include "register_interface/typedef.svh"
`include "axi/typedef.svh"
`include "axi_pkg.sv"

`ifndef GLOBAL_TYPEDEF_SVH
`define GLOBAL_TYPEDEF_SVH

typedef logic [64-1:0]  addr_t;
typedef logic [32-1:0]  reg_addr_t;
typedef logic [64-1:0]  data_t;
typedef logic [32-1:0]  reg_data_t;
typedef logic [8-1:0]   strb_t;
typedef logic [4-1:0]   reg_strb_t;

// Define reg_req_t and reg_rsp_t structs
`REG_BUS_TYPEDEF_ALL(iommu_reg, reg_addr_t, reg_data_t, reg_strb_t)

`endif