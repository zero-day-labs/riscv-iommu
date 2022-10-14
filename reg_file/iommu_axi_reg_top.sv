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

    // Write address channel
    input  logic     [          13-1:0] s_axil_awaddr,
    input  logic     [             2:0] s_axil_awprot,
    input  logic                        s_axil_awvalid,
    output logic                        s_axil_awready,

    // Write data channel
    input  logic     [          64-1:0] s_axil_wdata,
    input  logic     [           8-1:0] s_axil_wstrb,
    input  logic                        s_axil_wvalid,
    output logic                        s_axil_wready,

    // Write response channel
    output logic     [             1:0] s_axil_bresp,
    output logic                        s_axil_bvalid,
    input  logic                        s_axil_bready,

    // Read address channel
    input  logic     [          13-1:0] s_axil_araddr,
    input  logic     [             2:0] s_axil_arprot,
    input  logic                        s_axil_arvalid,
    output logic                        s_axil_arready,

    // Read data channel
    output logic     [          64-1:0] s_axil_rdata,
    output logic     [             1:0] s_axil_rresp,
    output logic                        s_axil_rvalid,
    input  logic                        s_axil_rready,

    // To HW
    output iommu_reg_pkg::iommu_reg2hw_t reg2hw_o,
    input  iommu_reg_pkg::iommu_hw2reg_t hw2reg_i

    // // enable test/dev modes of the different modules
    // input  logic     devmode_i
);

    import iommu_reg_pkg::* ;

    // connection between AXI-Lite slave connector and protocol conversion module
    axi_lite_req_t  axi_lite_req_w;
    axi_lite_rsp_t  axi_lite_rsp_w;

    // Connection between protocol conversion module and regmap RegIF
    reg_req_t cfg_req_w;
    reg_rsp_t cfg_rsp_w;

    //
    // AXI-Lite connector (used for testbench)
    //
    axi_lite_slave_conn #(
        .DATA_WIDTH (64),
        .ADDR_WIDTH (13)
    ) axi_lite_s_conn(
        // AW
        .s_axil_awaddr  (s_axil_awaddr),
        .s_axil_awprot  (s_axil_awprot),
        .s_axil_awvalid (s_axil_awvalid),
        .s_axil_awready (s_axil_awready),

        // W
        .s_axil_wdata   (s_axil_wdata),
        .s_axil_wstrb   (s_axil_wstrb),
        .s_axil_wvalid  (s_axil_wvalid),
        .s_axil_wready  (s_axil_wready),

        // B
        .s_axil_bresp   (s_axil_bresp),
        .s_axil_bvalid  (s_axil_bvalid),
        .s_axil_bready  (s_axil_bready),

        // RA
        .s_axil_araddr  (s_axil_araddr),
        .s_axil_arprot  (s_axil_arprot),
        .s_axil_arvalid (s_axil_arvalid),
        .s_axil_arready (s_axil_arready),

        // R
        .s_axil_rdata   (s_axil_rdata),
        .s_axil_rresp   (s_axil_rresp),
        .s_axil_rvalid  (s_axil_rvalid),
        .s_axil_rready  (s_axil_rready),

        // AXI request/response pair
        .axi_lite_req_o (axi_lite_req_w),
        .axi_lite_rsp_i (axi_lite_rsp_w)
    );

    //
    // Protocol conversion module
    //
    axi_lite_to_reg_intf #(
        .ADDR_WIDTH (13),
        .DATA_WIDTH (64)
    ) axilite_2_regif(
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .axi_lite_req_i (axi_lite_req_w),
        .axi_lite_rsp_o (axi_lite_rsp_w),

        .reg_req_o      (cfg_req_w),
        .reg_rsp_i      (cfg_rsp_w)
    );

    //
    // Register map top module
    //
    iommu_regmap_top #(
      .AW (13),
      .DW (64)
    ) iommu_regmap(
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .reg_req_i  (cfg_req_w),
        .reg_rsp_o  (cfg_rsp_w),

        .reg2hw     (reg2hw_o),
        .hw2reg     (hw2reg_i),
        
        .devmode_i  (1'b0)
    );

endmodule