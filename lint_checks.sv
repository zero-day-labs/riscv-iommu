// Copyright (c) 2023 University of Minho
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.

/*
    Author: Manuel Rodríguez, University of Minho
    Date: 28/03/2023

    Description: IOMMU Top module defining parameters and types for lint checks.
*/


`include "ariane_axi_soc_pkg.sv"
`include "typedef_global.svh"

module lint_checks (

	input  logic clk_i,
	input  logic rst_ni,

	// Translation Request Interface (Slave)
	input  ariane_axi_soc::req_t    dev_tr_req_i,
	output ariane_axi_soc::resp_t   dev_tr_resp_o,

	// Translation Completion Interface (Master)
	input  ariane_axi_soc::resp_t   dev_comp_resp_i,
	output ariane_axi_soc::req_t   	dev_comp_req_o,

	// Implicit Memory Accesses Interface (Master)
	input  ariane_axi_soc::resp_t   mem_resp_i,
	output ariane_axi_soc::req_t    mem_req_o,

	// Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
	input  ariane_axi_soc::req_t    prog_req_i,
	output ariane_axi_soc::resp_t   prog_resp_o,

	output logic [15:0] wsi_wires_o
);

	riscv_iommu #(
		.IOTLB_ENTRIES		( 16								 				),
		.DDTC_ENTRIES			( 16								 				),
		.PDTC_ENTRIES			( 16								 				),
		.DEVICE_ID_WIDTH  ( 24												),
		.PSCID_WIDTH      ( 20								 				),
		.GSCID_WIDTH      ( 16								 				),

		.InclPID          ( 1'b0							 				),
		.InclWSI_IG       ( 1'b1							 				),
		.InclMSI_IG       ( 1'b0							 				),

		.ADDR_WIDTH				( 64												),
		.DATA_WIDTH				( 64												),
		.ID_WIDTH					( ariane_soc::IdWidth				),
		.USER_WIDTH				( 1													),
		.aw_chan_t				( ariane_axi_soc::aw_chan_t ),
		.w_chan_t					( ariane_axi_soc::w_chan_t	),
		.b_chan_t					( ariane_axi_soc::b_chan_t	),
		.ar_chan_t				( ariane_axi_soc::ar_chan_t ),
		.r_chan_t					( ariane_axi_soc::r_chan_t	),
		.axi_req_t				( ariane_axi_soc::req_t		  ),
		.axi_rsp_t				( ariane_axi_soc::resp_t		),
		.axi_lite_req_t		( axi_lite_req_t						),
		.axi_lite_resp_t	( axi_lite_resp_t						),
		.reg_req_t				( reg_req_t									),
		.reg_rsp_t				( reg_rsp_t									)
	) i_riscv_iommu (

		.clk_i						( clk_i						),
		.rst_ni						( rst_ni					),

		// Translation Request Interface (Slave)
		.dev_tr_req_i			( dev_tr_req_i		),
		.dev_tr_resp_o		( dev_tr_resp_o		),

		// Translation Completion Interface (Master)
		.dev_comp_resp_i	( dev_comp_resp_i	),
		.dev_comp_req_o		( dev_comp_req_o	),

		// Implicit Memory Accesses Interface (Master)
		.mem_resp_i				( mem_resp_i		  ),
		.mem_req_o				( mem_req_o		    ),

		// Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
		.prog_req_i				( prog_req_i		  ),
		.prog_resp_o			( prog_resp_o		  ),

		.wsi_wires_o			( wsi_wires_o     )
	);

endmodule