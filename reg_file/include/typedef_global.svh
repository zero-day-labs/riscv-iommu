// Global include file for register interface and AXI typedef structures
// Created for particular use in development process
//

`include "include/typedef_reg.svh"
`include "include/typedef_axi.svh"
`include "packages/axi_pkg.sv"

`ifndef GLOBAL_TYPEDEF_SVH
`define GLOBAL_TYPEDEF_SVH

typedef logic [13-1:0] addr_t;
typedef logic [64-1:0] data_t;
typedef logic [8-1:0] strb_t;


// `define REG_BUS_TYPEDEF_REQ(req_t, addr_t, data_t, strb_t) \
//     typedef struct packed { \
//         addr_t addr; \
//         logic  write; \
//         data_t wdata; \
//         strb_t wstrb; \
//         logic  valid; \
//     } req_t;

// `define REG_BUS_TYPEDEF_RSP(rsp_t, data_t) \
//     typedef struct packed { \
//         data_t rdata; \
//         logic  error; \
//         logic  ready; \
//     } rsp_t;
`REG_BUS_TYPEDEF_ALL(reg, addr_t, data_t, strb_t)


// All AXI4-Lite Channels and Request/Response Structs in One Macro
//
// This can be used whenever the user is not interested in "precise" control of the naming of the
// individual channels.
//
// Usage Example:
// `AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)
//
// This defines `axi_lite_req_t` and `axi_lite_rsp_t` request/response structs as well as
// `axi_lite_aw_chan_t`, `axi_lite_w_chan_t`, `axi_lite_b_chan_t`, `axi_lite_ar_chan_t`, and
// `axi_lite_r_chan_t` channel structs.
`AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)

`endif