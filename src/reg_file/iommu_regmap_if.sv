// IOMMU AXI-REG top configuration module:
//
// Instantiates the IOMMU register map, accessible through a register interface,
// and an AXILite-to-RegIF module, so the Register map may be configured through
// the Slave AXILite interface.
//

`include "packages/iommu_reg_pkg_exp.sv"
`include "include/typedef_global.svh"

module iommu_regmap_if #(
    /// The width of the address.
    parameter int   ADDR_WIDTH = -1,
    /// The width of the data.
    parameter int   DATA_WIDTH = -1,
    /// AXI ID width
    parameter int   ID_WIDTH  = -1,
    /// AXI user width
    parameter int   USER_WIDTH  = -1,
    /// Buffer depth (how many outstanding transactions do we allow)
    parameter int   BUFFER_DEPTH = 2,
    /// Whether the AXI-Lite W channel should be decoupled with a register. This
    /// can help break long paths at the expense of registers.
    parameter bit   DECOUPLE_W = 1,
    /// AXI Full request struct type
    parameter type  axi_req_t = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t = logic,
    /// AXI-Lite request struct type.
    parameter type  axi_lite_req_t = logic,
    /// AXI-Lite response struct type.
    parameter type  axi_lite_rsp_t = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t = logic
) (
    // rising-edge clock 
    input  logic     clk_i,
    // asynchronous reset, active low
    input  logic     rst_ni,

    // AXI Slave interface
    input  axi_req_t prog_req_i,
    output axi_rsp_t prog_resp_o,

    // To HW
    output iommu_reg_pkg::iommu_reg2hw_t    reg2hw_o,
    input  iommu_reg_pkg::iommu_hw2reg_t    hw2reg_i
);

    import iommu_reg_pkg::* ;

    // connection between AXI-Lite slave connector and protocol conversion module
    axi_lite_req_t  axi_lite_req;
    axi_lite_rsp_t  axi_lite_rsp;

    // Connection between protocol conversion module and regmap RegIF
    reg_req_t cfg_req;
    reg_rsp_t cfg_resp;

    //
    // AXI to AXI Lite
    //
    axi_to_axi_lite #(
        .AxiAddrWidth       (ADDR_WIDTH),
        .AxiDataWidth       (DATA_WIDTH),
        .AxiIdWidth         (ID_WIDTH),
        .AxiUserWidth       (USER_WIDTH),
        .AxiMaxWriteTxns    (32'd1),    //? What is the correct value
        .AxiMaxReadTxns     (32'd1),    //? What is the correct value
        .FallThrough        (1'b0),     // The data at the head of the FIFO is immediately presented on the data output lines
        .full_req_t         (axi_req_t),
        .full_resp_t        (axi_rsp_t),
        .lite_req_t         (axi_lite_req_t),
        .lite_resp_t        (axi_lite_rsp_t)
    ) i_axi_to_axi_lite (
        .clk_i      (clk_i),    // Clock
        .rst_ni     (rst_ni),   // Asynchronous reset active low
        .test_i     (1'b0),   // Testmode enable
        // slave port full AXI4+ATOP
        .slv_req_i  (prog_req_i),
        .slv_resp_o (prog_resp_o),
        // master port AXI4-Lite
        .mst_req_o  (axi_lite_req),
        .mst_resp_i (axi_lite_rsp)
    );

    //
    // AXI Lite to Register Interface
    //
    axi_lite_to_reg_intf #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH),
        .BUFFER_DEPTH   (BUFFER_DEPTH), //? What is the correct value for this?
        .DECOUPLE_W     (DECOUPLE_W),   //? What is the correct value for this?
        .axi_lite_req_t (axi_lite_req_t),
        .axi_lite_rsp_t (axi_lite_rsp_t),
        .reg_req_t      (reg_req_t),
        .reg_rsp_t      (reg_rsp_t)
    ) i_axi_lite_to_reg_intf (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .axi_lite_req_i (axi_lite_req),
        .axi_lite_rsp_o (axi_lite_rsp),

        .reg_req_o      (cfg_req),
        .reg_rsp_i      (cfg_resp)
    );

    //
    // Register map wrapper module
    //
    iommu_regmap_wrapper #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .reg_req_t  (reg_req_t),
        .reg_rsp_t  (reg_rsp_t)
    ) i_iommu_regmap_wrapper (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .reg_req_i  (cfg_req),
        .reg_rsp_o  (cfg_resp),

        .reg2hw     (reg2hw_o),
        .hw2reg     (hw2reg_i),
        
        .devmode_i  (1'b0)
    );

endmodule