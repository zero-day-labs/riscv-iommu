// IOMMU AXI-REG top configuration module:
//
// Instantiates the IOMMU register map, accessible through a register interface,
// and an AXILite-to-RegIF module, so the Register map may be configured through
// the Slave AXILite interface.
//

`include "packages/iommu_reg_pkg_exp.sv"
`include "include/typedef_global.svh"

module iommu_axi_cfg_top #(
    //* No parameters by now
    // /// The width of the address.
    // parameter int ADDR_WIDTH = -1,
    // /// The width of the data.
    // parameter int DATA_WIDTH = -1,
    // /// Buffer depth (how many outstanding transactions do we allow)
    // parameter int BUFFER_DEPTH = 2,
    // /// Whether the AXI-Lite W channel should be decoupled with a register. This
    // /// can help break long paths at the expense of registers.
    // parameter bit DECOUPLE_W = 1
) (
    // rising-edge clock 
    input  logic     clk_i,
    // asynchronous reset, active low
    input  logic     rst_ni,

    // configuration port
    input  axi_lite_req_t  axi_lite_req_i,
    output axi_lite_rsp_t  axi_lite_rsp_o,

    // To HW
    output iommu_reg_pkg::iommu_reg2hw_t reg2hw_o,
    input  iommu_reg_pkg::iommu_hw2reg_t hw2reg_i

    // // enable test/dev modes of the different modules
    // input  logic     devmode_i
);

    import iommu_reg_pkg::* ;

    // Connection between protocol conversion module and regmap RegIF
    reg_req_t cfg_req_w;
    reg_rsp_t cfg_rsp_w;

    axi_lite_to_reg_intf #(
        .ADDR_WIDTH (13),
        .DATA_WIDTH (64)
    )(
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .axi_lite_req_i (axi_lite_req_i),
        .axi_lite_rsp_o (axi_lite_rsp_o),

        .reg_req_o      (cfg_req_w),
        .reg_rsp_i      (cfg_rsp_w)
    );

    // Register map top module
    iommu_reg_top #(
      .AW (13),
      .DW (64)
    )(
        .clk_i (clk_i),
        .rst_ni (rst_ni),

        .reg_req_i (cfg_req_w),
        .reg_rsp_o (cfg_rsp_w),

        .reg2hw (reg2hw_o),
        .hw2reg (hw2reg_i),
        
        .devmode_i(1'b0)
    );

endmodule