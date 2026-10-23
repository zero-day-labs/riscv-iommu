// SPDX-License-Identifier: Apache-2.0
//
// Fault-queue (FQ) regression for rv_iommu_fq_handler, on the full IOMMU
// instantiated by lint_checks.sv.
//
// Device 1 has a valid device context (first stage Sv39, one 1 GiB identity
// leaf).  Device 3 has no valid device context, so every transaction it
// issues faults with cause 258 (DDT entry not valid) and produces one fault
// record.  Each scenario:
//   1. sends one write from device 1 (must succeed),
//   2. sends N writes from device 3 (each must end with an error response),
//   3. reads fqh/fqt and fqcsr,
//   4. sends one read from device 1 (must still be translated and served).
//
// Scenarios (+scenario=<name>):
//   fq_disabled  FQ left disabled (its reset state), 8 faults.  No record can
//                be written, so records must be discarded and translation
//                must keep going for every device.
//   fq_overflow  FQ enabled with 4 entries and fqh left at 0, 20 faults.  The
//                queue holds 3 records.  The 4th fault must find it full and
//                set fqcsr.fqof, and later records must be discarded instead
//                of wrapping the tail over unread records.
//   fq_fits      Control: FQ enabled with 4 entries, 3 faults.  3 records,
//                fqof stays clear.

`timescale 1ns/1ps

module fq_disabled_overflow_tb;
  import lint_wrapper::*;

  // Register offsets
  localparam logic [AddrWidth-1:0] REG_DDTP = 64'h10;
  localparam logic [AddrWidth-1:0] REG_FQB  = 64'h28;
  localparam logic [AddrWidth-1:0] REG_FQHT = 64'h30;   // fqh [31:0], fqt [63:32]
  localparam logic [AddrWidth-1:0] REG_CSR  = 64'h48;   // cqcsr [31:0], fqcsr [63:32]

  // Memory layout
  localparam logic [AddrWidth-1:0] DDT_BASE  = 64'h2000;           // ddtp.PPN = 2
  localparam logic [AddrWidth-1:0] DC_DEV1   = DDT_BASE + 1 * 64;  // 64-byte DCs
  localparam logic [AddrWidth-1:0] PT_ROOT   = 64'h3000;           // iosatp.PPN = 3
  localparam logic [AddrWidth-1:0] FQ_BASE   = 64'h20000;          // fqb.PPN = 0x20
  localparam int unsigned          FQ_SLOTS  = 4;
  localparam logic [AddrWidth-1:0] IOVA      = 64'h4000;
  localparam logic [DataWidth-1:0] WR_DATA   = 64'h1111_2222_3333_4444;
  localparam logic [DataWidth-1:0] RD_DATA   = 64'h5555_6666_7777_8888;

  localparam logic [23:0] DID_GOOD  = 24'd1;
  localparam logic [23:0] DID_FAULT = 24'd3;

  localparam int unsigned FAULT_WAIT = 500;     // cycles allowed per transaction
  localparam int unsigned PROBE_WAIT = 2000;
  localparam int unsigned MAX_CYCLES = 200000;  // whole-run watchdog
  localparam int unsigned MAX_RECS   = 32;

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
  int unsigned cycle_q;

  // ---------------------------------------------------------------------------
  // Data-structure memory (ds port): device context, page table, fault queue.
  // Reads support bursts.  Writes are fault records; one at a time.
  // ---------------------------------------------------------------------------
  function automatic logic [DataWidth-1:0] mem_word(input logic [AddrWidth-1:0] addr);
    logic [AddrWidth-1:0] a;
    a = {addr[AddrWidth-1:3], 3'b000};
    mem_word = '0;
    if (a == DC_DEV1)          mem_word = 64'h1;                  // tc.V
    else if (a == DC_DEV1 + 24) mem_word = {4'd8, 16'd0, 44'd3};  // fsc: Sv39, PPN 3
    else if (a == PT_ROOT)      // leaf, 1 GiB identity, V R W X U A D
      mem_word = {10'd0, 44'd0, 2'b00, 8'b1101_1111};
  endfunction

  logic                 rd_valid_q, rd_last_q;
  logic [IdWidth-1:0]   rd_id_q;
  logic [AddrWidth-1:0] rd_addr_q;
  logic [7:0]           rd_beat_q, rd_len_q;

  logic                 wr_open_q, wr_b_q;
  logic [IdWidth-1:0]   wr_id_q;
  logic [AddrWidth-1:0] wr_addr_q;
  logic [7:0]           wr_beat_q;
  logic [DataWidth-1:0] wr_word0_q;

  int unsigned          nrec_q;                    // fault records written
  logic [AddrWidth-1:0] rec_addr_q  [MAX_RECS];
  logic [DataWidth-1:0] rec_word0_q [MAX_RECS];    // cause, ttyp, did
  logic [DataWidth-1:0] rec_word2_q [MAX_RECS];    // iotval

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
      wr_beat_q  <= '0;   wr_word0_q <= '0;
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
      // A fault record is 4 beats: beat 0 holds cause/ttyp/did, beat 2 iotval.
      if (ds_req_o.w_valid && ds_resp_i.w_ready) begin
        wr_beat_q <= wr_beat_q + 1;
        if (wr_beat_q == 0) wr_word0_q <= ds_req_o.w.data;
        if (wr_beat_q == 2 && nrec_q < MAX_RECS) begin
          rec_addr_q[nrec_q]  <= wr_addr_q;
          rec_word0_q[nrec_q] <= wr_word0_q;
          rec_word2_q[nrec_q] <= ds_req_o.w.data;
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
  // Memory behind the translated device port (dev_comp): single-beat accesses.
  // ---------------------------------------------------------------------------
  logic                 cw_open_q, cw_b_q, cr_valid_q;
  logic [IdWidth-1:0]   cw_id_q, cr_id_q;
  int unsigned          dev_writes_q, dev_reads_q;
  logic [AddrWidth-1:0] dev_wr_addr_q, dev_rd_addr_q;
  logic [DataWidth-1:0] dev_wr_data_q;

  always_comb begin
    dev_comp_resp_i          = '0;
    dev_comp_resp_i.aw_ready = !cw_open_q && !cw_b_q;
    dev_comp_resp_i.w_ready  = cw_open_q;
    dev_comp_resp_i.b_valid  = cw_b_q;
    dev_comp_resp_i.b.id     = cw_id_q;
    dev_comp_resp_i.b.resp   = axi_pkg::RESP_OKAY;
    dev_comp_resp_i.ar_ready = !cr_valid_q;
    dev_comp_resp_i.r_valid  = cr_valid_q;
    dev_comp_resp_i.r.id     = cr_id_q;
    dev_comp_resp_i.r.data   = RD_DATA;
    dev_comp_resp_i.r.resp   = axi_pkg::RESP_OKAY;
    dev_comp_resp_i.r.last   = 1'b1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cw_open_q <= 1'b0; cw_b_q <= 1'b0; cr_valid_q <= 1'b0;
      cw_id_q <= '0; cr_id_q <= '0;
      dev_writes_q <= 0; dev_reads_q <= 0;
      dev_wr_addr_q <= '0; dev_rd_addr_q <= '0; dev_wr_data_q <= '0;
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

      if (dev_comp_req_o.ar_valid && dev_comp_resp_i.ar_ready) begin
        cr_valid_q <= 1'b1; cr_id_q <= dev_comp_req_o.ar.id;
        dev_rd_addr_q <= dev_comp_req_o.ar.addr;
        dev_reads_q   <= dev_reads_q + 1;
      end else if (cr_valid_q && dev_comp_req_o.r_ready) begin
        cr_valid_q <= 1'b0;
      end
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

  task automatic reg_read(input logic [AddrWidth-1:0] addr, output logic [63:0] data);
    bit ar_done = 0, r_done = 0;
    data = '0;
    @(negedge clk_i);
    prog_req_i.ar = '0; prog_req_i.ar.addr = addr; prog_req_i.ar.size = 3'd3;
    prog_req_i.ar.burst = axi_pkg::BURST_INCR; prog_req_i.ar_valid = 1'b1;
    prog_req_i.r_ready = 1'b1;
    while (!r_done) begin
      @(posedge clk_i);
      if (prog_req_i.ar_valid && prog_resp_o.ar_ready) ar_done = 1;
      if (prog_resp_o.r_valid) begin data = prog_resp_o.r.data; r_done = 1; end
      @(negedge clk_i);
      if (ar_done) prog_req_i.ar_valid = 1'b0;
    end
    prog_req_i.r_ready = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Device port
  // ---------------------------------------------------------------------------
  // One single-beat write to IOVA.  done=0 if no B response arrives within
  // FAULT_WAIT cycles; AWVALID/WVALID then stay asserted, as AXI requires.
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
    for (int t = 0; t < FAULT_WAIT && !done; t++) begin
      @(posedge clk_i);
      if (dev_tr_req_i.aw_valid && dev_tr_resp_o.aw_ready) aw_done = 1;
      if (dev_tr_req_i.w_valid && dev_tr_resp_o.w_ready) w_done = 1;
      if (dev_tr_resp_o.b_valid) begin resp = dev_tr_resp_o.b.resp; done = 1; end
      @(negedge clk_i);
      if (aw_done) dev_tr_req_i.aw_valid = 1'b0;
      if (w_done) dev_tr_req_i.w_valid = 1'b0;
    end
    if (done) dev_tr_req_i.b_ready = 1'b0;
  endtask

  // One single-beat read from IOVA.  served=1 once the R beat comes back.
  task automatic dev_read(input logic [23:0] did, output bit served,
                          output logic [1:0] resp, output logic [63:0] data);
    bit ar_done = 0;
    served = 0; resp = '0; data = '0;
    @(negedge clk_i);
    dev_tr_req_i.ar = '0; dev_tr_req_i.ar.addr = IOVA; dev_tr_req_i.ar.size = 3'd3;
    dev_tr_req_i.ar.burst = axi_pkg::BURST_INCR; dev_tr_req_i.ar.stream_id = did;
    dev_tr_req_i.ar_valid = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    for (int t = 0; t < PROBE_WAIT && !served; t++) begin
      @(posedge clk_i);
      if (dev_tr_req_i.ar_valid && dev_tr_resp_o.ar_ready) ar_done = 1;
      if (dev_tr_resp_o.r_valid) begin
        served = 1; resp = dev_tr_resp_o.r.resp; data = dev_tr_resp_o.r.data;
      end
      @(negedge clk_i);
      if (ar_done) dev_tr_req_i.ar_valid = 1'b0;
    end
    dev_tr_req_i.r_ready = 1'b0;
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
    int unsigned nfaults, exp_records, exp_fqt;
    logic [31:0] exp_fqcsr;
    bit fq_enable, done, served;
    logic [1:0] resp;
    logic [63:0] rdata, fqht, csr;
    int unsigned completed, error_resps;
    string obs, exp, slots, exp_slots, bad_rec;

    dev_tr_req_i = '0;
    prog_req_i   = '0;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
    case (scenario)
      "fq_disabled": begin fq_enable = 0; nfaults = 8;  exp_records = 0; exp_fqt = 0; exp_fqcsr = 32'h0000_0000; end
      "fq_overflow": begin fq_enable = 1; nfaults = 20; exp_records = 3; exp_fqt = 3; exp_fqcsr = 32'h0001_0201; end
      "fq_fits":     begin fq_enable = 1; nfaults = 3;  exp_records = 3; exp_fqt = 3; exp_fqcsr = 32'h0001_0001; end
      default: begin
        $display("FAIL %s: unknown scenario (use +scenario=fq_disabled|fq_overflow|fq_fits)", scenario);
        $finish;
      end
    endcase

    repeat (6) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);

    reg_write(REG_DDTP, 64'h0000_0000_0000_0802);           // 1LVL, PPN 2
    if (fq_enable) begin
      reg_write(REG_FQB, {10'd0, 44'h20, 5'd0, 5'd1});      // PPN 0x20, LOG2SZ-1 = 1: 4 entries
      reg_write(REG_CSR, {32'h0000_0001, 32'h0000_0000});   // fqcsr.fqen = 1
      repeat (20) @(posedge clk_i);
    end

    // Device 1 works before any fault.
    dev_write(DID_GOOD, done, resp);
    if (!done || resp != axi_pkg::RESP_OKAY || dev_writes_q != 1 ||
        dev_wr_addr_q != IOVA || dev_wr_data_q != WR_DATA) begin
      $display("FAIL %s: first write from device 1: done=%0d resp=%0d writes=%0d addr=%h data=%h; expected done=1 resp=0 writes=1 addr=%h data=%h",
               scenario, done, resp, dev_writes_q, dev_wr_addr_q, dev_wr_data_q, IOVA, WR_DATA);
      $finish;
    end

    // Faulting writes from device 3.  Stop at the first one that gets no
    // response; it stays outstanding, as a real device's would.
    completed = 0; error_resps = 0;
    for (int i = 0; i < nfaults; i++) begin
      dev_write(DID_FAULT, done, resp);
      if (!done) break;
      completed++;
      if (resp == axi_pkg::RESP_SLVERR) error_resps++;
    end

    reg_read(REG_FQHT, fqht);
    reg_read(REG_CSR, csr);

    // Device 1 must still be served.
    dev_read(DID_GOOD, served, resp, rdata);
    served = served && resp == axi_pkg::RESP_OKAY && rdata == RD_DATA &&
             dev_reads_q == 1 && dev_rd_addr_q == IOVA;

    // Fault records: queue slot of each, and the fields of any record that
    // is not (cause 258, ttyp untranslated write, did 3, iotval = IOVA).
    slots = ""; exp_slots = ""; bad_rec = "";
    for (int i = 0; i < nrec_q && i < MAX_RECS; i++) begin
      slots = {slots, (i ? "," : ""), $sformatf("%0d", (rec_addr_q[i] - FQ_BASE) / 32)};
      if (rec_word0_q[i][11:0] != 12'd258 || rec_word0_q[i][39:34] != 6'd3 ||
          rec_word0_q[i][63:40] != DID_FAULT || rec_word2_q[i] != IOVA)
        bad_rec = $sformatf(" bad_record%0d=%h/%h", i, rec_word0_q[i], rec_word2_q[i]);
    end
    for (int i = 0; i < exp_records; i++)
      exp_slots = {exp_slots, (i ? "," : ""), $sformatf("%0d", i)};

    obs = $sformatf("faults_completed=%0d/%0d error_responses=%0d records=%0d slots=[%s]%s fqh=%0d fqt=%0d fqcsr=%08h fqof=%0d device1_read_served=%0d",
                    completed, nfaults, error_resps, nrec_q, slots, bad_rec,
                    fqht[31:0], fqht[63:32], csr[63:32], csr[32+9], served);
    exp = $sformatf("faults_completed=%0d/%0d error_responses=%0d records=%0d slots=[%s] fqh=0 fqt=%0d fqcsr=%08h fqof=%0d device1_read_served=1",
                    nfaults, nfaults, nfaults, exp_records, exp_slots,
                    exp_fqt, exp_fqcsr, exp_fqcsr[9]);
    if (obs == exp) $display("PASS %s: %s (%0d cycles)", scenario, obs, cycle_q);
    else            $display("FAIL %s: %s; expected %s", scenario, obs, exp);
    $finish;
  end
endmodule
