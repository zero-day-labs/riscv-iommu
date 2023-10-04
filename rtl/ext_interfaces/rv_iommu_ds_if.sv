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
// Date: 01/03/2023
//
// Description: RISC-V IOMMU Data Structures Interface Wrapper.

module rv_iommu_ds_if #(
    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // External ports: To DS IF Bus
    input  axi_rsp_t    ds_resp_i,
    output axi_req_t    ds_req_o,

    /*--------------------------------------------*/
    
    // From PTW
    output axi_rsp_t    ptw_resp_o,
    input  axi_req_t    ptw_req_i,

    // From CDW
    output axi_rsp_t    cdw_resp_o,
    input  axi_req_t    cdw_req_i,

    // From CQ
    output axi_rsp_t    cq_resp_o,
    input  axi_req_t    cq_req_i,

    // From FQ
    output axi_rsp_t    fq_resp_o,
    input  axi_req_t    fq_req_i,

    // From MSI IG
    output axi_rsp_t    msi_ig_resp_o,
    input  axi_req_t    msi_ig_req_i
);

    logic[1:0] w_select, w_select_fifo;

    //# AR Channel (PTW, CDW, CQ)
    stream_arbiter #(
        .DATA_T ( ariane_axi::ar_chan_t ),
        .N_INP  ( 3                     )
    ) i_stream_arbiter_ar (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .inp_data_i     ( {ptw_req_i.ar, cdw_req_i.ar, cq_req_i.ar} ),
        .inp_valid_i    ( {ptw_req_i.ar_valid, cdw_req_i.ar_valid, cq_req_i.ar_valid} ),
        .inp_ready_o    ( {ptw_resp_o.ar_ready, cdw_resp_o.ar_ready, cq_resp_o.ar_ready} ),
        .oup_data_o     ( ds_req_o.ar        ),
        .oup_valid_o    ( ds_req_o.ar_valid  ),
        .oup_ready_i    ( ds_resp_i.ar_ready )
    );

    //# AW Channel (CQ, FQ, MSI IG)
    stream_arbiter #(
        .DATA_T ( ariane_axi::aw_chan_t ),
        .N_INP  ( 3                     )
    ) i_stream_arbiter_aw (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .inp_data_i     ( {cq_req_i.aw, fq_req_i.aw, msi_ig_req_i.aw} ),
        .inp_valid_i    ( {cq_req_i.aw_valid, fq_req_i.aw_valid, msi_ig_req_i.aw_valid} ),
        .inp_ready_o    ( {cq_resp_o.aw_ready, fq_resp_o.aw_ready, msi_ig_resp_o.aw_ready} ),
        .oup_data_o     ( ds_req_o.aw        ),
        .oup_valid_o    ( ds_req_o.aw_valid  ),
        .oup_ready_i    ( ds_resp_i.aw_ready )
    );

    //# W Channel
    // Control signal to select accepted AWID for writing data to W Channel
    always_comb begin
        w_select = '0;
        unique case (ds_req_o.aw.id)   // Selected AWID
            4'b0000:                            w_select = 2'd2; // MSI IG
            4'b0001:                            w_select = 2'd1; // FQ
            4'b0010:                            w_select = 2'd0; // CQ
            default:                            w_select = 2'd0; // none
        endcase
    end

    // Save AWID whenever a transaction is accepted in AW Channel.
    // While writing data to W Channel, another AW transaction may be accepted, so we need to queue the AWIDs
    // Only CQ, FQ and MSI IG perform writes to memory, so we can have max 3 outstanding transactions
    fifo_v3 #(
      .DATA_WIDTH   ( 2    ),
      // we can have a maximum of 2 oustanding transactions as each port is blocking
      .DEPTH        ( 3    )
    ) i_fifo_w_channel (
      .clk_i      ( clk_i           ),
      .rst_ni     ( rst_ni          ),
      .flush_i    ( 1'b0            ),
      .testmode_i ( 1'b0            ),
      .full_o     (                 ),
      .empty_o    (                 ),
      .usage_o    (                 ),
      .data_i     ( w_select        ),
      .push_i     ( ds_req_o.aw_valid & ds_resp_i.aw_ready ), // a new AW transaction was requested and granted
      .data_o     ( w_select_fifo   ),                          // WID to select the W MUX
      .pop_i      ( ds_req_o.w_valid & ds_resp_i.w_ready & ds_req_o.w.last ) // W transaction has finished
    );

    // For invalid AWIDs for which the request was accepted, or when AW FIFO is empty, CQ channel is selected
    stream_mux #(
        .DATA_T ( ariane_axi::w_chan_t ),
        .N_INP  ( 3                    )
    ) i_stream_mux_w (
        .inp_data_i  ( {cq_req_i.w, fq_req_i.w, msi_ig_req_i.w} ),
        .inp_valid_i ( {cq_req_i.w_valid, fq_req_i.w_valid, msi_ig_req_i.w_valid} ),
        .inp_ready_o ( {cq_resp_o.w_ready, fq_resp_o.w_ready, msi_ig_resp_o.w_ready} ),
        .inp_sel_i   ( w_select_fifo        ),
        .oup_data_o  ( ds_req_o.w          ),
        .oup_valid_o ( ds_req_o.w_valid    ),
        .oup_ready_i ( ds_resp_i.w_ready   )
    );

    // Route responses based on ID
    // 0000         -> PTW
    // 0001         -> CDW
    // 0010         -> CQ
    //# R Channel: We only demux RVALID/RREADY signals
    assign ptw_resp_o.r = ds_resp_i.r;
    assign cdw_resp_o.r = ds_resp_i.r;
    assign cq_resp_o.r  = ds_resp_i.r;

    logic [1:0] r_select;

    // Demux RVALID/RREADY signals
    always_comb begin
        r_select = 0;
        unique case (ds_resp_i.r.id)
            4'b0000:                        r_select = 2; // PTW
            4'b0001:                        r_select = 1; // CDW
            4'b0010:                        r_select = 0; // CQ
            default:                        r_select = 0;
        endcase
    end

    stream_demux #(
        .N_OUP ( 3 )
    ) i_stream_demux_r (
        .inp_valid_i ( ds_resp_i.r_valid ),
        .inp_ready_o ( ds_req_o.r_ready  ),
        .oup_sel_i   ( r_select           ),
        .oup_valid_o ( {ptw_resp_o.r_valid, cdw_resp_o.r_valid, cq_resp_o.r_valid} ),
        .oup_ready_i ( {ptw_req_i.r_ready, cdw_req_i.r_ready, cq_req_i.r_ready} )
    );

    //# B Channel: We only demux BVALID/BREADY signals
    logic [1:0] b_select;

    assign cq_resp_o.b = ds_resp_i.b;
    assign fq_resp_o.b = ds_resp_i.b;
    assign msi_ig_resp_o.b = ds_resp_i.b;

    always_comb begin
        b_select = 0;
        unique case (ds_resp_i.b.id)
            4'b0000:                        b_select = 2; // MSI IG
            4'b0001:                        b_select = 1; // FQ
            4'b0010:                        b_select = 0; // CQ
            default:                        b_select = 0;
        endcase
    end

    stream_demux #(
        .N_OUP ( 3 )
    ) i_stream_demux_b (
        .inp_valid_i ( ds_resp_i.b_valid ),
        .inp_ready_o ( ds_req_o.b_ready  ),
        .oup_sel_i   ( b_select           ),
        .oup_valid_o ( {cq_resp_o.b_valid, fq_resp_o.b_valid, msi_ig_resp_o.b_valid} ),
        .oup_ready_i ( {cq_req_i.b_ready,  fq_req_i.b_ready, msi_ig_req_i.b_ready} )
    );
    
endmodule