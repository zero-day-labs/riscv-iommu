// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Burst checks of the full IOMMU (lint_checks top, InclBC = 1).
//
// Memory: 1-level DDT at 0x2000 (ddtp = 0x802).  Devices 1 and 2 have a valid
// context with first-stage Sv39 translation, root table at 0x3000 holding a
// 1 GiB identity leaf, so IOVA x translates to physical address x.
//
// Each scenario first runs a legal single-beat write (it must complete), then
// the device write under test, then two legal reads (device 1 and device 2)
// that must be accepted.  The scenario checks the B response of the write
// under test, where it was forwarded, and that both reads were served.
//
//   reserved_burst    AxBURST = 2'b11, 1 beat          -> SLVERR, not forwarded
//   page_end_incr     INCR 8 x 8 bytes at offset 0xfc0  -> OKAY, forwarded
//                     (the last byte is the last byte of the page)
//   incr_single       INCR 1 beat (control)             -> OKAY, forwarded
//   fixed_single      FIXED 1 beat (control)            -> OKAY, forwarded
//   wrap_bad_len      WRAP with AxLEN = 0 (control)     -> SLVERR, not forwarded
//   crossing_incr     INCR 8 x 8 bytes at offset 0xfc8  -> SLVERR, not forwarded
//                     (control: crosses the 4 KiB boundary)

module axi4_bc_burst_tb;
  import lint_wrapper::*;

  localparam int unsigned WAIT_CYCLES = 2000;

  localparam logic [AddrWidth-1:0] DDTP_ADDR = 64'h10;
  localparam logic [AddrWidth-1:0] DDT_BASE  = 64'h2000;
  localparam logic [AddrWidth-1:0] PT_ROOT   = 64'h3000;
  localparam logic [AddrWidth-1:0] PAGE      = 64'h4000;

  logic clk_i = 1'b0, rst_ni = 1'b0;
  req_iommu_t dev_tr_req_i;
  resp_t      dev_tr_resp_o;
  resp_t      dev_comp_resp_i;
  req_t       dev_comp_req_o;
  resp_t      ds_resp_i;
  req_t       ds_req_o;
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

  int unsigned cycle;
  always_ff @(posedge clk_i) cycle <= cycle + 1;

  // ---------------------------------------------------------------------------
  // Data-structure memory (read only): DDT, contexts and the page table.
  function automatic logic [63:0] mem_word(logic [AddrWidth-1:0] addr);
    logic [AddrWidth-1:0] a = {addr[AddrWidth-1:3], 3'b000};
    if (a >= DDT_BASE + 64 && a < DDT_BASE + 3 * 64) begin   // device IDs 1 and 2
      case (a[5:3])
        3'd0:    return 64'h1;                                // tc.V
        3'd3:    return {4'd8, 16'd0, 44'(PT_ROOT >> 12)};    // fsc: Sv39 root
        default: return 64'h0;
      endcase
    end
    if (a == PT_ROOT) return 64'hdf;                          // 1 GiB leaf, PPN 0, D A U X W R V
    return 64'h0;
  endfunction

  logic        r_valid;
  logic [IdWidth-1:0] r_id;
  logic [AddrWidth-1:0] r_addr;
  logic [7:0]  r_beat, r_len;

  always_comb begin
    ds_resp_i          = '0;
    ds_resp_i.ar_ready = !r_valid;
    ds_resp_i.aw_ready = 1'b1;
    ds_resp_i.w_ready  = 1'b1;
    ds_resp_i.r_valid  = r_valid;
    ds_resp_i.r.id     = r_id;
    ds_resp_i.r.data   = mem_word(r_addr + 64'(r_beat) * 8);
    ds_resp_i.r.last   = (r_beat == r_len);
    ds_resp_i.r.resp   = axi_pkg::RESP_OKAY;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_valid <= 1'b0; r_id <= '0; r_addr <= '0; r_beat <= '0; r_len <= '0;
    end else if (!r_valid && ds_req_o.ar_valid) begin
      r_valid <= 1'b1; r_id <= ds_req_o.ar.id; r_addr <= ds_req_o.ar.addr;
      r_beat <= '0; r_len <= ds_req_o.ar.len;
    end else if (r_valid && ds_req_o.r_ready) begin
      if (r_beat == r_len) r_valid <= 1'b0;
      else r_beat <= r_beat + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Downstream (translated) port: accepts writes and reads, records them.
  logic        c_aw_seen, c_b_valid;
  logic [IdWidth-1:0] c_b_id;
  logic [AddrWidth-1:0] fwd_aw_addr;
  int unsigned fwd_aw_count, fwd_w_beats, fwd_ar_count;

  always_comb begin
    dev_comp_resp_i          = '0;
    dev_comp_resp_i.aw_ready = !c_aw_seen;
    dev_comp_resp_i.w_ready  = c_aw_seen && !c_b_valid;
    dev_comp_resp_i.b_valid  = c_b_valid;
    dev_comp_resp_i.b.id     = c_b_id;
    dev_comp_resp_i.b.resp   = axi_pkg::RESP_OKAY;
    dev_comp_resp_i.ar_ready = 1'b1;   // reads are only counted, never answered
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c_aw_seen <= 1'b0; c_b_valid <= 1'b0; c_b_id <= '0; fwd_aw_addr <= '0;
      fwd_aw_count <= 0; fwd_w_beats <= 0; fwd_ar_count <= 0;
    end else begin
      if (dev_comp_req_o.aw_valid && dev_comp_resp_i.aw_ready) begin
        c_aw_seen <= 1'b1; c_b_id <= dev_comp_req_o.aw.id;
        fwd_aw_addr <= dev_comp_req_o.aw.addr; fwd_aw_count <= fwd_aw_count + 1;
      end
      if (dev_comp_req_o.w_valid && dev_comp_resp_i.w_ready) begin
        fwd_w_beats <= fwd_w_beats + 1;
        if (dev_comp_req_o.w.last) c_b_valid <= 1'b1;
      end
      if (c_b_valid && dev_comp_req_o.b_ready) begin
        c_b_valid <= 1'b0; c_aw_seen <= 1'b0;
      end
      if (dev_comp_req_o.ar_valid) fwd_ar_count <= fwd_ar_count + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Register write through the programming port (64-bit).
  task automatic reg_write(logic [AddrWidth-1:0] addr, logic [63:0] data);
    bit aw_done = 0, w_done = 0;
    @(negedge clk_i);
    prog_req_i.aw = '0; prog_req_i.aw.addr = addr; prog_req_i.aw.size = 3'd3;
    prog_req_i.aw.burst = axi_pkg::BURST_INCR; prog_req_i.aw_valid = 1'b1;
    prog_req_i.w = '0; prog_req_i.w.data = data; prog_req_i.w.strb = '1;
    prog_req_i.w.last = 1'b1; prog_req_i.w_valid = 1'b1; prog_req_i.b_ready = 1'b1;
    while (!(aw_done && w_done)) begin
      @(posedge clk_i);
      if (prog_req_i.aw_valid && prog_resp_o.aw_ready) aw_done = 1;
      if (prog_req_i.w_valid && prog_resp_o.w_ready) w_done = 1;
      @(negedge clk_i);
      if (aw_done) prog_req_i.aw_valid = 1'b0;
      if (w_done) prog_req_i.w_valid = 1'b0;
    end
    while (!prog_resp_o.b_valid) @(posedge clk_i);
    @(negedge clk_i); prog_req_i.b_ready = 1'b0;
  endtask

  // Device write: AW then (len + 1) W beats, then wait for B.
  // Gives up after WAIT_CYCLES; AW/W stay asserted until accepted.
  task automatic dev_write(logic [AddrWidth-1:0] addr, logic [1:0] burst, logic [7:0] len,
                           output bit done, output logic [1:0] resp);
    int unsigned t = 0, beat = 0;
    bit aw_done = 0;
    done = 0; resp = '0;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0; dev_tr_req_i.aw.addr = addr; dev_tr_req_i.aw.size = 3'd3;
    dev_tr_req_i.aw.burst = burst; dev_tr_req_i.aw.len = len;
    dev_tr_req_i.aw.stream_id = 24'd1; dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0; dev_tr_req_i.w.data = 64'hd0d0_0000; dev_tr_req_i.w.strb = '1;
    dev_tr_req_i.w.last = (len == 0); dev_tr_req_i.w_valid = 1'b1;
    dev_tr_req_i.b_ready = 1'b1;
    while (t < WAIT_CYCLES && !done) begin
      bit aw_hs, w_hs;
      @(posedge clk_i); t++;
      aw_hs = dev_tr_req_i.aw_valid && dev_tr_resp_o.aw_ready;
      w_hs  = dev_tr_req_i.w_valid && dev_tr_resp_o.w_ready;
      if (dev_tr_resp_o.b_valid) begin done = 1; resp = dev_tr_resp_o.b.resp; end
      @(negedge clk_i);
      if (aw_hs) begin aw_done = 1; dev_tr_req_i.aw_valid = 1'b0; end
      if (w_hs) begin
        if (beat == len) dev_tr_req_i.w_valid = 1'b0;
        else begin
          beat++;
          dev_tr_req_i.w.data = 64'hd0d0_0000 + beat;
          dev_tr_req_i.w.last = (beat == len);
        end
      end
    end
    @(negedge clk_i);
    if (done) begin
      dev_tr_req_i.b_ready = 1'b0;
    end
  endtask

  // Legal single-beat read; only AR acceptance is checked.
  task automatic dev_read(logic [23:0] did, output bit accepted);
    int unsigned t = 0;
    accepted = 0;
    @(negedge clk_i);
    dev_tr_req_i.ar = '0; dev_tr_req_i.ar.addr = PAGE; dev_tr_req_i.ar.size = 3'd3;
    dev_tr_req_i.ar.burst = axi_pkg::BURST_INCR; dev_tr_req_i.ar.stream_id = did;
    dev_tr_req_i.ar_valid = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    while (t < WAIT_CYCLES && !accepted) begin
      @(posedge clk_i); t++;
      if (dev_tr_resp_o.ar_ready) accepted = 1;
    end
    @(negedge clk_i); dev_tr_req_i.ar_valid = 1'b0;
    // Give the IOMMU time to forward the read before the next one.
    repeat (40) @(posedge clk_i);
  endtask

  // ---------------------------------------------------------------------------
  initial begin
    string       scenario;
    logic [AddrWidth-1:0] addr, exp_addr;
    logic [1:0]  burst, resp, exp_resp, warm_resp;
    logic [7:0]  len;
    bit          exp_fwd, warm_done, done, read1, read2, ok;
    int unsigned aw_before, w_before, fwd_aws, fwd_beats;

    if (!$value$plusargs("scenario=%s", scenario)) scenario = "reserved_burst";
    case (scenario)
      "reserved_burst": begin addr = PAGE;           burst = 2'b11;                len = 0; exp_fwd = 0; end
      "page_end_incr":  begin addr = PAGE + 'hfc0;   burst = axi_pkg::BURST_INCR;  len = 7; exp_fwd = 1; end
      "incr_single":    begin addr = PAGE + 'h8;     burst = axi_pkg::BURST_INCR;  len = 0; exp_fwd = 1; end
      "fixed_single":   begin addr = PAGE + 'h10;    burst = axi_pkg::BURST_FIXED; len = 0; exp_fwd = 1; end
      "wrap_bad_len":   begin addr = PAGE;           burst = axi_pkg::BURST_WRAP;  len = 0; exp_fwd = 0; end
      "crossing_incr":  begin addr = PAGE + 'hfc8;   burst = axi_pkg::BURST_INCR;  len = 7; exp_fwd = 0; end
      default: begin
        $display("FAIL %s: unknown scenario", scenario);
        $finish;
      end
    endcase
    exp_resp = exp_fwd ? axi_pkg::RESP_OKAY : axi_pkg::RESP_SLVERR;

    dev_tr_req_i = '0; prog_req_i = '0;
    repeat (5) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);
    reg_write(DDTP_ADDR, 64'h802);                 // 1LVL DDT at 0x2000

    dev_write(PAGE, axi_pkg::BURST_INCR, 0, warm_done, warm_resp);
    repeat (5) @(posedge clk_i);

    aw_before = fwd_aw_count; w_before = fwd_w_beats;
    dev_write(addr, burst, len, done, resp);
    repeat (5) @(posedge clk_i);
    fwd_aws = fwd_aw_count - aw_before; fwd_beats = fwd_w_beats - w_before;
    dev_read(24'd1, read1);
    dev_read(24'd2, read2);

    ok = warm_done && warm_resp == axi_pkg::RESP_OKAY && done && resp == exp_resp
         && read1 && read2
         && fwd_aws == (exp_fwd ? 1 : 0)
         && fwd_beats == (exp_fwd ? len + 1 : 0)
         && (!exp_fwd || fwd_aw_addr == addr);
    $display("%s %s: burst=%0d len=%0d addr=0x%0h b_received=%0d resp=%0d forwarded_aw=%0d forwarded_w_beats=%0d forwarded_addr=0x%0h read_dev1=%0d read_dev2=%0d cycles=%0d%s",
             ok ? "PASS" : "FAIL", scenario, burst, len, addr, done, resp, fwd_aws, fwd_beats,
             fwd_aws ? fwd_aw_addr : 64'h0, read1, read2, cycle,
             ok ? "" : $sformatf("; expected b_received=1 resp=%0d forwarded_aw=%0d forwarded_w_beats=%0d read_dev1=1 read_dev2=1 (warm-up write done=%0d resp=%0d)",
                                 exp_resp, exp_fwd, exp_fwd ? len + 1 : 0, warm_done, warm_resp));
    $finish;
  end

endmodule
