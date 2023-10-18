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

`include "include/assertions.svh"
`include "ariane_axi_soc_pkg.sv"
`include "typedef_global.svh"
`include "rv_iommu_pkg.sv"
`include "rv_iommu_reg_pkg.sv"
`include "rv_iommu_field_pkg.sv"

module lint_checks (

	input  logic clk_i,
	input  logic rst_ni,

	// Translation Request Interface (Slave)
	input  ariane_axi_soc::req_mmu_t    dev_tr_req_i,
	output ariane_axi_soc::resp_t   	dev_tr_resp_o,

	// Translation Completion Interface (Master)
	input  ariane_axi_soc::resp_t   	dev_comp_resp_i,
	output ariane_axi_soc::req_t   		dev_comp_req_o,

	// Data Structures Interface (Master)
	input  ariane_axi_soc::resp_t   	ds_resp_i,
	output ariane_axi_soc::req_t    	ds_req_o,

	// Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
	input  ariane_axi_soc::req_slv_t    prog_req_i,
	output ariane_axi_soc::resp_slv_t   prog_resp_o,

	output logic [15:0] wsi_wires_o
);

	riscv_iommu #(
		.IOTLB_ENTRIES		( 16						),
		.DDTC_ENTRIES		( 8							),
		.PDTC_ENTRIES		( 8							),

		.InclPC             ( 1'b1						),
		.InclMSITrans       ( 1'b1						),
		.InclBC             ( 1'b1						),

		.IGS         		( rv_iommu::BOTH			),
		.N_INT_VEC          ( ariane_soc::IOMMUNumWires ),
		.N_IOHPMCTR			( 16						),

		.ADDR_WIDTH			( 64						),
		.DATA_WIDTH			( 64						),
		.ID_WIDTH			( ariane_soc::IdWidth		),
		.ID_SLV_WIDTH		( ariane_soc::IdWidthSlave	),
		.USER_WIDTH			( 1							),
		.aw_chan_t			( ariane_axi_soc::aw_chan_t ),
		.w_chan_t			( ariane_axi_soc::w_chan_t	),
		.b_chan_t			( ariane_axi_soc::b_chan_t	),
		.ar_chan_t			( ariane_axi_soc::ar_chan_t ),
		.r_chan_t			( ariane_axi_soc::r_chan_t	),
		.axi_req_t			( ariane_axi_soc::req_t		),
		.axi_rsp_t			( ariane_axi_soc::resp_t	),
		.axi_req_slv_t		( ariane_axi_soc::req_slv_t	),
		.axi_rsp_slv_t		( ariane_axi_soc::resp_slv_t),
		.axi_req_mmu_t		( ariane_axi_soc::req_mmu_t ),
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

		.wsi_wires_o		( wsi_wires_o[(ariane_soc::IOMMUNumWires-1):0])
	);

endmodule