// SPDX-License-Identifier: Apache-2.0
//
// Device-context check regression: DC.msiptp.MODE must be Off when
// DC.iohgatp.MODE is Bare.  The specification reserves every other msiptp
// mode in that case and recommends reporting "DDT entry misconfigured"
// (cause 259).  Runs on the full IOMMU instantiated by lint_checks.sv.
//
// Device 1's device context uses first-stage Sv39 (one 1 GiB identity leaf)
// and the iohgatp/msiptp modes selected by the scenario.  The fault queue is
// enabled so that a rejected context produces a fault record.  Device 1 then
// issues one write to IOVA 0x4000, which is not an MSI address.
//
// Scenarios (+scenario=<name>):
//   bare_flat    iohgatp Bare,   msiptp Flat: the context must be rejected.
//                The write gets an error response, nothing is written, and
//                one fault record with cause 259 is written.
//   bare_off     Control, iohgatp Bare, msiptp Off: write translated and done.
//   sv39x4_flat  Control, iohgatp Sv39x4 (1 GiB identity), msiptp Flat:
//                write translated and done.

`timescale 1ns/1ps

module dc_msiptp_bare_tb;
  import lint_wrapper::*;

  // Register offsets
  localparam logic [AddrWidth-1:0] REG_DDTP = 64'h10;
  localparam logic [AddrWidth-1:0] REG_FQB  = 64'h28;
  localparam logic [AddrWidth-1:0] REG_CSR  = 64'h48;   // cqcsr [31:0], fqcsr [63:32]

  // Memory layout
  localparam logic [AddrWidth-1:0] DDT_BASE  = 64'h2000;           // ddtp.PPN = 2
  localparam logic [AddrWidth-1:0] DC_DEV1   = DDT_BASE + 1 * 64;  // 64-byte DCs
  localparam logic [AddrWidth-1:0] S1_ROOT   = 64'h3000;           // fsc.PPN = 3
  localparam logic [AddrWidth-1:0] S2_ROOT   = 64'h8000;           // iohgatp.PPN = 8
  localparam logic [43:0]          MSIPT_PPN = 44'hC;              // msiptp.PPN
  localparam logic [AddrWidth-1:0] FQ_BASE   = 64'h20000;          // fqb.PPN = 0x20
  localparam logic [AddrWidth-1:0] IOVA      = 64'h4000;
  localparam logic [DataWidth-1:0] WR_DATA   = 64'h1111_2222_3333_4444;

  localparam logic [23:0] DID = 24'd1;
  localparam logic [11:0] CAUSE_DDT_MISCONFIGURED = 12'd259;

  localparam int unsigned WRITE_WAIT = 1500;    // cycles allowed for the write
  localparam int unsigned MAX_CYCLES = 50000;   // whole-run watchdog
  localparam int unsigned MAX_RECS   = 8;

  logic clk_i = 1'b0, rst_ni = 1'b0;
  req_iommu_t dev_tr_req_i;
  resp_t      dev_tr_resp_o;
  req_t       dev_comp_req_o;
  resp_t      dev_comp_resp_i;
  req_t       ds_req_o;
  resp_t      ds_resp_i;
  req_slv_t   prog_req_i;
  resp_slv_t  prog_resp_o;
  logic [NumIRQWires-1:0] wsi_wires_o;

  lint_checks dut (
    .clk_i, .rst_ni,
    .dev_tr_req_i, .dev_tr_resp_o,
    .dev_comp_resp_i, .dev_comp_req_o,
    .ds_resp_i, .ds_req_o,
    .prog_req_i, .prog_resp_o,
    .wsi_wires_o
  );

  always #5 clk_i = ~clk_i;

  string scenario = "";
  logic [3:0] iohgatp_mode, msiptp_mode;   // set from the scenario
  int unsigned cycle_q;

  // ---------------------------------------------------------------------------
  // Data-structure memory (ds port): device context, page tables, fault queue.
  // Reads support bursts.  Writes are fault records; one at a time.
  // ---------------------------------------------------------------------------
  // Leaf PTE mapping a 1 GiB identity page: V R W X U A D.
  localparam logic [DataWidth-1:0] LEAF_1G_IDENTITY = {10'd0, 44'd0, 2'b00, 8'b1101_1111};

  function automatic logic [DataWidth-1:0] mem_word(input logic [AddrWidth-1:0] addr);
    logic [AddrWidth-1:0] a;
    a = {addr[AddrWidth-1:3], 3'b000};
    mem_word = '0;
    case (a)
      DC_DEV1 + 0:  mem_word = 64'h1;                               // tc.V
      DC_DEV1 + 8:  mem_word = {iohgatp_mode, 16'd0, 44'd8};        // iohgatp
      DC_DEV1 + 24: mem_word = {4'd8, 16'd0, 44'd3};                // fsc: Sv39
      DC_DEV1 + 32: mem_word = {msiptp_mode, 16'd0, MSIPT_PPN};     // msiptp
      // msi_addr_mask = 0, msi_addr_pattern = 0x80000: the only MSI page is
      // guest address 0x8000_0000, far from anything this test accesses.
      DC_DEV1 + 48: mem_word = 64'h8_0000;                          // msi_addr_pattern
      S1_ROOT:      mem_word = LEAF_1G_IDENTITY;
      S2_ROOT:      mem_word = LEAF_1G_IDENTITY;
      default:      mem_word = '0;
    endcase
  endfunction

  logic                 rd_valid_q, rd_last_q;
  logic [IdWidth-1:0]   rd_id_q;
  logic [AddrWidth-1:0] rd_addr_q;
  logic [7:0]           rd_beat_q, rd_len_q;

  logic                 wr_open_q, wr_b_q;
  logic [IdWidth-1:0]   wr_id_q;
  logic [AddrWidth-1:0] wr_addr_q;
  logic [7:0]           wr_beat_q;

  int unsigned          nrec_q;                    // fault records written
  logic [AddrWidth-1:0] rec_addr_q  [MAX_RECS];
  logic [DataWidth-1:0] rec_word0_q [MAX_RECS];    // cause, ttyp, did

  always_comb begin
    ds_resp_i          = '0;
    ds_resp_i.ar_ready = !rd_valid_q;
    ds_resp_i.r_valid  = rd_valid_q;
    ds_resp_i.r.id     = rd_id_q;
    ds_resp_i.r.data   = mem_word(rd_addr_q + 64'(rd_beat_q) * 8);
    ds_resp_i.r.resp   = axi_pkg::RESP_OKAY;
    ds_resp_i.r.last   = rd_last_q;
    ds_resp_i.aw_ready = !wr_open_q && !wr_b_q;
    ds_resp_i.w_ready  = wr_open_q;
    ds_resp_i.b_valid  = wr_b_q;
    ds_resp_i.b.id     = wr_id_q;
    ds_resp_i.b.resp   = axi_pkg::RESP_OKAY;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle_q    <= 0;
      rd_valid_q <= 1'b0; rd_last_q <= 1'b0; rd_id_q <= '0; rd_addr_q <= '0;
      rd_beat_q  <= '0;   rd_len_q  <= '0;
      wr_open_q  <= 1'b0; wr_b_q    <= 1'b0; wr_id_q <= '0; wr_addr_q <= '0;
      wr_beat_q  <= '0;
      nrec_q     <= 0;
    end else begin
      cycle_q <= cycle_q + 1;

      if (ds_req_o.ar_valid && ds_resp_i.ar_ready) begin
        rd_valid_q <= 1'b1;
        rd_id_q    <= ds_req_o.ar.id;
        rd_addr_q  <= ds_req_o.ar.addr;
        rd_beat_q  <= '0;
        rd_len_q   <= ds_req_o.ar.len;
        rd_last_q  <= (ds_req_o.ar.len == 0);
      end else if (rd_valid_q && ds_req_o.r_ready) begin
        if (rd_last_q) rd_valid_q <= 1'b0;
        rd_beat_q <= rd_beat_q + 1;
        rd_last_q <= (rd_beat_q + 1 == rd_len_q);
      end

      if (ds_req_o.aw_valid && ds_resp_i.aw_ready) begin
        wr_open_q <= 1'b1;
        wr_id_q   <= ds_req_o.aw.id;
        wr_addr_q <= ds_req_o.aw.addr;
        wr_beat_q <= '0;
      end
      // Beat 0 of a fault record holds cause, ttyp and did.
      if (ds_req_o.w_valid && ds_resp_i.w_ready) begin
        wr_beat_q <= wr_beat_q + 1;
        if (wr_beat_q == 0 && nrec_q < MAX_RECS) begin
          rec_addr_q[nrec_q]  <= wr_addr_q;
          rec_word0_q[nrec_q] <= ds_req_o.w.data;
        end
        if (ds_req_o.w.last) begin
          wr_open_q <= 1'b0;
          wr_b_q    <= 1'b1;
          nrec_q    <= nrec_q + 1;
        end
      end
      if (wr_b_q && ds_req_o.b_ready) wr_b_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Memory behind the translated device port (dev_comp): single-beat writes.
  // ---------------------------------------------------------------------------
  logic                 cw_open_q, cw_b_q;
  logic [IdWidth-1:0]   cw_id_q;
  int unsigned          dev_writes_q;
  logic [AddrWidth-1:0] dev_wr_addr_q;
  logic [DataWidth-1:0] dev_wr_data_q;

  always_comb begin
    dev_comp_resp_i          = '0;
    dev_comp_resp_i.aw_ready = !cw_open_q && !cw_b_q;
    dev_comp_resp_i.w_ready  = cw_open_q;
    dev_comp_resp_i.b_valid  = cw_b_q;
    dev_comp_resp_i.b.id     = cw_id_q;
    dev_comp_resp_i.b.resp   = axi_pkg::RESP_OKAY;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cw_open_q <= 1'b0; cw_b_q <= 1'b0; cw_id_q <= '0;
      dev_writes_q <= 0; dev_wr_addr_q <= '0; dev_wr_data_q <= '0;
    end else begin
      if (dev_comp_req_o.aw_valid && dev_comp_resp_i.aw_ready) begin
        cw_open_q <= 1'b1; cw_id_q <= dev_comp_req_o.aw.id;
        dev_wr_addr_q <= dev_comp_req_o.aw.addr;
      end
      if (dev_comp_req_o.w_valid && dev_comp_resp_i.w_ready && dev_comp_req_o.w.last) begin
        cw_open_q <= 1'b0; cw_b_q <= 1'b1;
        dev_wr_data_q <= dev_comp_req_o.w.data;
        dev_writes_q  <= dev_writes_q + 1;
      end
      if (cw_b_q && dev_comp_req_o.b_ready) cw_b_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Register port
  // ---------------------------------------------------------------------------
  task automatic reg_write(input logic [AddrWidth-1:0] addr, input logic [63:0] data);
    bit aw_done = 0, w_done = 0, b_done = 0;
    @(negedge clk_i);
    prog_req_i.aw = '0; prog_req_i.aw.addr = addr; prog_req_i.aw.size = 3'd3;
    prog_req_i.aw.burst = axi_pkg::BURST_INCR; prog_req_i.aw_valid = 1'b1;
    prog_req_i.w = '0; prog_req_i.w.data = data; prog_req_i.w.strb = '1;
    prog_req_i.w.last = 1'b1; prog_req_i.w_valid = 1'b1; prog_req_i.b_ready = 1'b1;
    while (!b_done) begin
      @(posedge clk_i);
      if (prog_req_i.aw_valid && prog_resp_o.aw_ready) aw_done = 1;
      if (prog_req_i.w_valid && prog_resp_o.w_ready) w_done = 1;
      if (prog_resp_o.b_valid) b_done = 1;
      @(negedge clk_i);
      if (aw_done) prog_req_i.aw_valid = 1'b0;
      if (w_done) prog_req_i.w_valid = 1'b0;
    end
    prog_req_i.b_ready = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Device port: one single-beat write to IOVA.
  // ---------------------------------------------------------------------------
  task automatic dev_write(input logic [23:0] did, output bit done, output logic [1:0] resp);
    bit aw_done = 0, w_done = 0;
    done = 0; resp = '0;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0; dev_tr_req_i.aw.addr = IOVA; dev_tr_req_i.aw.size = 3'd3;
    dev_tr_req_i.aw.burst = axi_pkg::BURST_INCR; dev_tr_req_i.aw.stream_id = did;
    dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0; dev_tr_req_i.w.data = WR_DATA; dev_tr_req_i.w.strb = '1;
    dev_tr_req_i.w.last = 1'b1; dev_tr_req_i.w_valid = 1'b1;
    dev_tr_req_i.b_ready = 1'b1;
    for (int t = 0; t < WRITE_WAIT && !done; t++) begin
      @(posedge clk_i);
      if (dev_tr_req_i.aw_valid && dev_tr_resp_o.aw_ready) aw_done = 1;
      if (dev_tr_req_i.w_valid && dev_tr_resp_o.w_ready) w_done = 1;
      if (dev_tr_resp_o.b_valid) begin resp = dev_tr_resp_o.b.resp; done = 1; end
      @(negedge clk_i);
      if (aw_done) dev_tr_req_i.aw_valid = 1'b0;
      if (w_done) dev_tr_req_i.w_valid = 1'b0;
    end
    dev_tr_req_i.aw_valid = 1'b0; dev_tr_req_i.w_valid = 1'b0; dev_tr_req_i.b_ready = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Scenario
  // ---------------------------------------------------------------------------
  initial begin : watchdog
    wait (rst_ni);
    wait (cycle_q >= MAX_CYCLES);
    $display("FAIL %s: no result after %0d cycles", scenario, MAX_CYCLES);
    $finish;
  end

  initial begin : test
    bit rejected, done;
    logic [1:0] resp;
    string obs, exp, recs, exp_recs;

    dev_tr_req_i = '0;
    prog_req_i   = '0;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
    case (scenario)
      "bare_flat":   begin iohgatp_mode = 4'd0; msiptp_mode = 4'd1; rejected = 1; end
      "bare_off":    begin iohgatp_mode = 4'd0; msiptp_mode = 4'd0; rejected = 0; end
      "sv39x4_flat": begin iohgatp_mode = 4'd8; msiptp_mode = 4'd1; rejected = 0; end
      default: begin
        $display("FAIL %s: unknown scenario (use +scenario=bare_flat|bare_off|sv39x4_flat)", scenario);
        $finish;
      end
    endcase

    repeat (6) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);

    reg_write(REG_DDTP, 64'h0000_0000_0000_0802);           // 1LVL, PPN 2
    reg_write(REG_FQB, {10'd0, 44'h20, 5'd0, 5'd1});        // PPN 0x20, 4 entries
    reg_write(REG_CSR, {32'h0000_0001, 32'h0000_0000});     // fqcsr.fqen = 1
    repeat (20) @(posedge clk_i);

    dev_write(DID, done, resp);
    repeat (50) @(posedge clk_i);                           // let a fault record land

    recs = "";
    for (int i = 0; i < nrec_q && i < MAX_RECS; i++)
      recs = {recs, (i ? "," : ""), $sformatf("slot%0d:cause=%0d,ttyp=%0d,did=%0d",
              (rec_addr_q[i] - FQ_BASE) / 32, rec_word0_q[i][11:0],
              rec_word0_q[i][39:34], rec_word0_q[i][63:40])};
    obs = $sformatf("iohgatp=%0d msiptp=%0d write_done=%0d resp=%0d written=%0d",
                    iohgatp_mode, msiptp_mode, done, resp, dev_writes_q);
    if (dev_writes_q != 0)
      obs = {obs, $sformatf(" addr=%h data=%h", dev_wr_addr_q, dev_wr_data_q)};
    obs = {obs, $sformatf(" records=[%s]", recs)};

    exp_recs = rejected ? $sformatf("slot0:cause=%0d,ttyp=3,did=%0d", CAUSE_DDT_MISCONFIGURED, DID) : "";
    exp = $sformatf("iohgatp=%0d msiptp=%0d write_done=1 resp=%0d written=%0d",
                    iohgatp_mode, msiptp_mode,
                    rejected ? axi_pkg::RESP_SLVERR : axi_pkg::RESP_OKAY, rejected ? 0 : 1);
    if (!rejected) exp = {exp, $sformatf(" addr=%h data=%h", IOVA, WR_DATA)};
    exp = {exp, $sformatf(" records=[%s]", exp_recs)};

    if (obs == exp) $display("PASS %s: %s", scenario, obs);
    else            $display("FAIL %s: %s; expected %s", scenario, obs, exp);
    $finish;
  end
endmodule
