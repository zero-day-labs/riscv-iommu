// Copyright © 2025 Manuel Rodríguez & Zero-Day Labs, Lda.
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
// Date: 20/01/2025
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Data Structures Interface Wrapper.

module rv_iommu_ds_if #(

    /// AXI data types
    parameter type aw_chan_t    = logic,
    parameter type w_chan_t     = logic,
    parameter type b_chan_t     = logic,
    parameter type ar_chan_t    = logic,
    parameter type r_chan_t     = logic,

    parameter type axi_req_t    = logic,
    parameter type axi_resp_t   = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // External ports: To DS IF Bus
    input  axi_resp_t   ds_resp_i,
    output axi_req_t    ds_req_o,

    /*--------------------------------------------*/

    // DDTW
    input  axi_req_t    ddtw_req_i,
    output axi_resp_t   ddtw_resp_o,

    // PDTW
    input  axi_req_t    pdtw_req_i,
    output axi_resp_t   pdtw_resp_o,

    // PTW
    input  axi_req_t    ptw_req_i,
    output axi_resp_t   ptw_resp_o,

    // MSI PTW
    input  axi_req_t    msiptw_req_i,
    output axi_resp_t   msiptw_resp_o,

    // MRIF handler
    input  axi_req_t    mrif_handler_req_i,
    output axi_resp_t   mrif_handler_resp_o,

    // CQ
    input  axi_req_t    cq_req_i,
    output axi_resp_t   cq_resp_o,

    // FQ
    input  axi_req_t    fq_req_i,
    output axi_resp_t   fq_resp_o,

    // PQ
    input  axi_req_t    pq_req_i,
    output axi_resp_t   pq_resp_o,

    // MSI IG
    input  axi_req_t    msi_ig_req_i,
    output axi_resp_t   msi_ig_resp_o
);

    // AR Channel (DDTW, PDTW, PTW, CQ, MSIPTW, MRIF handler)
    ar_chan_t ar_data;
    logic ar_valid;
    logic ar_ready;
    stream_arbiter #(
        .DATA_T (ar_chan_t),
        .N_INP  (7)
    ) i_stream_arbiter_ar (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .inp_data_i     ({ddtw_req_i.ar, pdtw_req_i.ar, ptw_req_i.ar, cq_req_i.ar, pq_req_i.ar, msiptw_req_i.ar, mrif_handler_req_i.ar}),
        .inp_valid_i    ({ddtw_req_i.ar_valid, pdtw_req_i.ar_valid, ptw_req_i.ar_valid, cq_req_i.ar_valid, pq_req_i.ar_valid, msiptw_req_i.ar_valid, mrif_handler_req_i.ar_valid}),
        .inp_ready_o    ({ddtw_resp_o.ar_ready, pdtw_resp_o.ar_ready, ptw_resp_o.ar_ready, cq_resp_o.ar_ready, pq_resp_o.ar_ready, msiptw_resp_o.ar_ready, mrif_handler_resp_o.ar_ready}),
        .oup_data_o     (ar_data),
        .oup_valid_o    (ar_valid),
        .oup_ready_i    (ar_ready)
    );

    spill_register #(
        .T          (ar_chan_t),
        .Bypass     (1'b0)
    ) i_spill_register_ds_ar (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (ar_data),
        .valid_i    (ar_valid),
        .ready_o    (ar_ready),

        .data_o     (ds_req_o.ar),
        .valid_o    (ds_req_o.ar_valid),
        .ready_i    (ds_resp_i.ar_ready)
    );

    // AW Channel (CQ, FQ, MRIF handler, MSI IG)
    aw_chan_t aw_data;
    logic aw_valid;
    logic aw_ready;
    logic aw_spill_ready;
    logic w_fifo_full, w_fifo_empty;

    // Every accepted AW must retain its owner until the corresponding WLAST.
    assign aw_ready = aw_spill_ready && !w_fifo_full;
    stream_arbiter #(
        .DATA_T (aw_chan_t),
        .N_INP  (5)
    ) i_stream_arbiter_aw (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .inp_data_i     ({cq_req_i.aw, fq_req_i.aw, pq_req_i.aw, mrif_handler_req_i.aw, msi_ig_req_i.aw}),
        .inp_valid_i    ({cq_req_i.aw_valid, fq_req_i.aw_valid, pq_req_i.aw_valid, mrif_handler_req_i.aw_valid, msi_ig_req_i.aw_valid}),
        .inp_ready_o    ({cq_resp_o.aw_ready, fq_resp_o.aw_ready, pq_resp_o.aw_ready, mrif_handler_resp_o.aw_ready, msi_ig_resp_o.aw_ready}),
        .oup_data_o     (aw_data),
        .oup_valid_o    (aw_valid),
        .oup_ready_i    (aw_ready)
    );

    spill_register #(
        .T          (aw_chan_t),
        .Bypass     (1'b0)
    ) i_spill_register_ds_aw (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (aw_data),
        .valid_i    (aw_valid && !w_fifo_full),
        .ready_o    (aw_spill_ready),

        .data_o     (ds_req_o.aw),
        .valid_o    (ds_req_o.aw_valid),
        .ready_i    (ds_resp_i.aw_ready)
    );

    // W Channel
    logic[2:0] w_select, w_select_fifo;
    logic w_valid;
    logic w_mux_valid;
    logic w_ready;
    w_chan_t w_data;

    // Control signal to select accepted AWID for writing data to W Channel
    always_comb begin
        w_select = '0;
        unique case (aw_data.id)   // Selected AWID
            0:          w_select = 3'd0; // CQ
            1:          w_select = 3'd1; // FQ
            2:          w_select = 3'd2; // MRIF Handler
            3:          w_select = 3'd3; // MSI IG
            4:          w_select = 3'd4; // PQ
            default:    w_select = 3'd0; // CQ
        endcase
    end

    // Save AWID whenever a transaction is accepted in AW Channel.
    fifo_v3 #(
      .DATA_WIDTH   (3),
      .DEPTH        (8)
    ) i_fifo_w_channel (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .flush_i    (1'b0),
      .testmode_i (1'b0),
      .full_o     (w_fifo_full),
      .empty_o    (w_fifo_empty),
      .usage_o    ( ),
      .data_i     (w_select),
      .push_i     (aw_valid & aw_ready),
      .data_o     (w_select_fifo),
      .pop_i      (w_valid & w_ready & w_data.last)
    );

    stream_mux #(
        .DATA_T (w_chan_t),
        .N_INP  (5)
    ) i_stream_mux_w (
        // Packed index must match the owner selected from AWID above.
        .inp_data_i  ({pq_req_i.w, msi_ig_req_i.w, mrif_handler_req_i.w, fq_req_i.w, cq_req_i.w}),
        .inp_valid_i ({pq_req_i.w_valid, msi_ig_req_i.w_valid, mrif_handler_req_i.w_valid, fq_req_i.w_valid, cq_req_i.w_valid}),
        .inp_ready_o ({pq_resp_o.w_ready, msi_ig_resp_o.w_ready, mrif_handler_resp_o.w_ready, fq_resp_o.w_ready, cq_resp_o.w_ready}),
        .inp_sel_i   (w_select_fifo),
        .oup_data_o  (w_data),
        .oup_valid_o (w_mux_valid),
        .oup_ready_i (w_ready && !w_fifo_empty)
    );

    // An empty queue's stale selector must not consume a producer's W data.
    assign w_valid = w_mux_valid && !w_fifo_empty;

    spill_register #(
        .T          (w_chan_t),
        .Bypass     (1'b0)
    ) i_spill_register_ds_w (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (w_data),
        .valid_i    (w_valid),
        .ready_o    (w_ready),

        .data_o     (ds_req_o.w),
        .valid_o    (ds_req_o.w_valid),
        .ready_i    (ds_resp_i.w_ready)
    );

    //// R Channel: We only demux RVALID/RREADY signals
    logic [2:0] r_select;
    logic r_valid;
    logic r_ready;
    r_chan_t r_data;

    assign ptw_resp_o.r             = r_data;
    assign ddtw_resp_o.r            = r_data;
    assign pdtw_resp_o.r            = r_data;
    assign cq_resp_o.r              = r_data;
    assign pq_resp_o.r              = r_data;
    assign msiptw_resp_o.r          = r_data;
    assign mrif_handler_resp_o.r    = r_data;

    // Demux RVALID/RREADY signals
    always_comb begin
        r_select = '0;
        unique case (r_data.id)
            0:          r_select = 3'd0;   // PTW
            1:          r_select = 3'd1;   // DDTW
            2:          r_select = 3'd2;   // PDTW
            3:          r_select = 3'd3;   // CQ
            4:          r_select = 3'd4;   // MSIPTW
            5:          r_select = 3'd5;   // MRIF Handler
            default:    r_select = 3'd0;
        endcase
    end

    spill_register #(
        .T          (r_chan_t),
        .Bypass     (1'b0)
    ) i_spill_register_ds_r (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (ds_resp_i.r),
        .valid_i    (ds_resp_i.r_valid),
        .ready_o    (ds_req_o.r_ready),

        .data_o     (r_data),
        .valid_o    (r_valid),
        .ready_i    (r_ready)
    );

    stream_demux #(
        .N_OUP (7)
    ) i_stream_demux_r (
        .inp_valid_i (r_valid),
        .inp_ready_o (r_ready),
        .oup_sel_i   (r_select),
        .oup_valid_o ({pq_resp_o.r_valid, mrif_handler_resp_o.r_valid, msiptw_resp_o.r_valid, cq_resp_o.r_valid, pdtw_resp_o.r_valid, ddtw_resp_o.r_valid, ptw_resp_o.r_valid}),
        .oup_ready_i ({pq_req_i.r_ready, mrif_handler_req_i.r_ready, msiptw_req_i.r_ready, cq_req_i.r_ready, pdtw_req_i.r_ready, ddtw_req_i.r_ready, ptw_req_i.r_ready})
    );

    // B Channel: We only demux BVALID/BREADY signals
    logic [2:0] b_select;
    logic b_valid;
    logic b_ready;
    b_chan_t b_data;

    assign cq_resp_o.b              = b_data;
    assign fq_resp_o.b              = b_data;
    assign pq_resp_o.b              = b_data;
    assign mrif_handler_resp_o.b    = b_data;
    assign msi_ig_resp_o.b          = b_data;

    always_comb begin
        b_select = '0;
        unique case (b_data.id)
            0:          b_select = 3'd0;   // CQ
            1:          b_select = 3'd1;   // FQ
            2:          b_select = 3'd2;   // MRIF Handler
            3:          b_select = 3'd3;   // MSI IG
            4:          b_select = 3'd4;   // PQ
            default:    b_select = 3'd0;   // CQ
        endcase
    end

    spill_register #(
        .T          (b_chan_t),
        .Bypass     (1'b0)
    ) i_spill_register_ds_b (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .data_i     (ds_resp_i.b),
        .valid_i    (ds_resp_i.b_valid),
        .ready_o    (ds_req_o.b_ready),

        .data_o     (b_data),
        .valid_o    (b_valid),
        .ready_i    (b_ready)
    );

    stream_demux #(
        .N_OUP (5)
    ) i_stream_demux_b (
        .inp_valid_i (b_valid),
        .inp_ready_o (b_ready),
        .oup_sel_i   (b_select),
        .oup_valid_o ({pq_resp_o.b_valid, msi_ig_resp_o.b_valid, mrif_handler_resp_o.b_valid, fq_resp_o.b_valid, cq_resp_o.b_valid}),
        .oup_ready_i ({pq_req_i.b_ready, msi_ig_req_i.b_ready, mrif_handler_req_i.b_ready, fq_req_i.b_ready, cq_req_i.b_ready})
    );

    //# Unused signals
    // Read-only modules
    assign ptw_resp_o.aw_ready  = 1'b0;
    assign ptw_resp_o.w_ready   = 1'b0;
    assign ptw_resp_o.b_valid   = 1'b0;
    assign ptw_resp_o.b.id      = '0;
    assign ptw_resp_o.b.resp    = axi_pkg::RESP_SLVERR;
    assign ptw_resp_o.b.user    = '0;

    assign ddtw_resp_o.aw_ready = 1'b0;
    assign ddtw_resp_o.w_ready  = 1'b0;
    assign ddtw_resp_o.b_valid  = 1'b0;
    assign ddtw_resp_o.b.id     = '0;
    assign ddtw_resp_o.b.resp   = axi_pkg::RESP_SLVERR;
    assign ddtw_resp_o.b.user   = '0;

    assign pdtw_resp_o.aw_ready = 1'b0;
    assign pdtw_resp_o.w_ready  = 1'b0;
    assign pdtw_resp_o.b_valid  = 1'b0;
    assign pdtw_resp_o.b.id     = '0;
    assign pdtw_resp_o.b.resp   = axi_pkg::RESP_SLVERR;
    assign pdtw_resp_o.b.user   = '0;

    assign msiptw_resp_o.aw_ready   = 1'b0;
    assign msiptw_resp_o.w_ready    = 1'b0;
    assign msiptw_resp_o.b_valid    = 1'b0;
    assign msiptw_resp_o.b.id       = '0;
    assign msiptw_resp_o.b.resp     = axi_pkg::RESP_SLVERR;
    assign msiptw_resp_o.b.user     = '0;

    // Write-only modules
    assign fq_resp_o.ar_ready   = 1'b0;
    assign fq_resp_o.r_valid    = 1'b0;
    assign fq_resp_o.r.id       = '0;
    assign fq_resp_o.r.data     = '0;
    assign fq_resp_o.r.resp     = axi_pkg::RESP_SLVERR;
    assign fq_resp_o.r.last     = 1'b0;
    assign fq_resp_o.r.user     = '0;

    assign msi_ig_resp_o.ar_ready   = 1'b0;
    assign msi_ig_resp_o.r_valid    = 1'b0;
    assign msi_ig_resp_o.r.id       = '0;
    assign msi_ig_resp_o.r.data     = '0;
    assign msi_ig_resp_o.r.resp     = axi_pkg::RESP_SLVERR;
    assign msi_ig_resp_o.r.last     = 1'b0;
    assign msi_ig_resp_o.r.user     = '0;

endmodule
