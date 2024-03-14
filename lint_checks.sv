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
// Date: 28/03/2023
//
// Description: Top module to instance riscv_iommu module, 
//				defining parameters and types for lint checks.

`include "assertions.svh"
`include "register_interface/typedef.svh"

`include "riscv_pkg.sv"
`include "lint_wrapper_pkg.sv"

`include "rv_iommu_pkg.sv"
`include "rv_iommu_reg_pkg.sv"
`include "rv_iommu_field_pkg.sv"

module lint_checks (

	input  logic clk_i,
	input  logic rst_ni,

	// Translation Request Interface (Slave)
	input  lint_wrapper::req_iommu_t	dev_tr_req_i,
	output lint_wrapper::resp_t   		dev_tr_resp_o,

	// Translation Completion Interface (Master)
	input  lint_wrapper::resp_t   		dev_comp_resp_i,
	output lint_wrapper::req_t   		dev_comp_req_o,

	// Data Structures Interface (Master)
	input  lint_wrapper::resp_t   		ds_resp_i,
	output lint_wrapper::req_t    		ds_req_o,

	// Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
	input  lint_wrapper::req_slv_t    	prog_req_i,
	output lint_wrapper::resp_slv_t   	prog_resp_o,

	output logic [3:0] 					wsi_wires_o
);

	typedef logic [64-1:0]  reg_addr_t;
	typedef logic [32-1:0]  reg_data_t;
	typedef logic [4-1:0]   reg_strb_t;

	// Define reg_req_t and reg_rsp_t structs
	`REG_BUS_TYPEDEF_ALL(iommu_reg, reg_addr_t, reg_data_t, reg_strb_t)

	riscv_iommu #(
		.IOTLB_ENTRIES		( 16						),
		.DDTC_ENTRIES		( 8							),
		.PDTC_ENTRIES		( 8							),
		.MRIFC_ENTRIES		( 4							),

		.InclPC             ( 1'b1						),
		.InclBC             ( 1'b1						),
		.InclDBG			( 1'b1						),

		.MSITrans			( rv_iommu::MSI_FLAT_MRIF	),
		.IGS         		( rv_iommu::BOTH			),
		.N_INT_VEC          ( 4 						),
		.N_IOHPMCTR			( 16						),

		.ADDR_WIDTH			( lint_wrapper::AddrWidth	),
		.DATA_WIDTH			( lint_wrapper::DataWidth	),
		.ID_WIDTH			( lint_wrapper::IdWidth		),
		.ID_SLV_WIDTH		( lint_wrapper::IdWidthSlv	),
		.USER_WIDTH			( lint_wrapper::UserWidth	),
		.aw_chan_t			( lint_wrapper::aw_chan_t 	),
		.w_chan_t			( lint_wrapper::w_chan_t	),
		.b_chan_t			( lint_wrapper::b_chan_t	),
		.ar_chan_t			( lint_wrapper::ar_chan_t 	),
		.r_chan_t			( lint_wrapper::r_chan_t	),
		.axi_req_t			( lint_wrapper::req_t		),
		.axi_rsp_t			( lint_wrapper::resp_t		),
		.axi_req_slv_t		( lint_wrapper::req_slv_t	),
		.axi_rsp_slv_t		( lint_wrapper::resp_slv_t	),
		.axi_req_iommu_t	( lint_wrapper::req_iommu_t	),
		.reg_req_t			( iommu_reg_req_t			),
		.reg_rsp_t			( iommu_reg_rsp_t			)
	) i_riscv_iommu (

		.clk_i				( clk_i				),
		.rst_ni				( rst_ni			),

		// Translation Request Interface (Slave)
		.dev_tr_req_i		( dev_tr_req_i		),
		.dev_tr_resp_o		( dev_tr_resp_o		),

		// Translation Completion Interface (Master)
		.dev_comp_resp_i	( dev_comp_resp_i	),
		.dev_comp_req_o		( dev_comp_req_o	),

		// Implicit Memory Accesses Interface (Master)
		.ds_resp_i			( ds_resp_i			),
		.ds_req_o			( ds_req_o		    ),

		// Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
		.prog_req_i			( prog_req_i		),
		.prog_resp_o		( prog_resp_o		),

		.wsi_wires_o		( wsi_wires_o[3:0])
	);

endmodule