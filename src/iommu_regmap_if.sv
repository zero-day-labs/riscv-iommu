// Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date:   02/02/2023
//
// Description: Wrapper module for the RISC-V IOMMU register programming interface.
//              Instantiates the IOMMU register map and performs conversion between 
//              register interface protocol and AXI4.
//

// `include "packages/iommu_reg_pkg.sv"

module iommu_regmap_if #(
    /// The width of the address.
    parameter int           ADDR_WIDTH = -1,
    /// The width of the data.
    parameter int           DATA_WIDTH = -1,
    /// AXI ID width
    parameter int           ID_WIDTH  = -1,
    /// AXI user width
    parameter int           USER_WIDTH  = 1,

    /// Whether the AXI-Lite W channel should be decoupled with a register. This
    /// can help break long paths at the expense of registers.
    parameter bit           DECOUPLE_W = 1,

    // Include IOMMU WSI generation support
    parameter bit           InclWSI_IG = 1,
    // Include IOMMU MSI generation support
    parameter bit           InclMSI_IG = 0,
    // Number of interrupt vectors supported
    parameter int unsigned  N_INT_VEC = 16,
    /// AXI Full request struct type
    parameter type  axi_req_t = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t = logic,
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

    // Connection between protocol conversion module and regmap RegIF
    reg_req_t cfg_req;
    reg_rsp_t cfg_resp;

    //
    // AXI4 + ATOP => Register Interface
    //
    axi_to_reg #(
        .ADDR_WIDTH         (ADDR_WIDTH ),
        .DATA_WIDTH         (DATA_WIDTH ),
        .ID_WIDTH           (ID_WIDTH   ),
        .USER_WIDTH         (USER_WIDTH ),

        .DECOUPLE_W         (DECOUPLE_W ),

        .axi_req_t          (axi_req_t  ),
        .axi_rsp_t          (axi_rsp_t  ),
        .reg_req_t          (reg_req_t  ),
        .reg_rsp_t          (reg_rsp_t  )
    ) i_axi_to_reg (
        .clk_i              (clk_i      ),
        .rst_ni             (rst_ni     ),
        .testmode_i         (1'b0       ),
        .axi_req_i          (prog_req_i ),
        .axi_rsp_o          (prog_resp_o),
        .reg_req_o          (cfg_req    ),
        .reg_rsp_i          (cfg_resp   )
    );

    //
    // Register map wrapper module
    //
    iommu_regmap_wrapper #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .InclWSI_IG (InclWSI_IG),
        .InclMSI_IG (InclMSI_IG),
        .N_INT_VEC  (N_INT_VEC),
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