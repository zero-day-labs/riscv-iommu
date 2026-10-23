// SPDX-License-Identifier: Apache-2.0
//
// Interrupt signalling regression for the IOMMU (WSI wires and MSI writes).
//
// The testbench instantiates the full IOMMU through lint_checks.sv and drives
// the programming interface (prog_req_i) like software would.  The
// data-structure port is served by a small memory model that can hold the B
// response of writes to a chosen address window.  Faults are produced by
// device writes while ddtp is in its reset mode (all transactions disallowed).
//
// Scenarios (+scenario=<name>):
//   wsi_iofence_shared     fctl.WSI=1, icvec=0 (all sources on vector 0),
//                          IOFENCE.C with WSI=1: ipsr.cip=1 and wire 0 rises
//   wsi_iofence_distinct   same with icvec=0x210 (civ=0, fiv=1, pmiv=2)
//   wsi_fault_shared       fctl.WSI=1, icvec=0x110 (civ=0, fiv=1, pmiv=1, the
//                          Linux two-wire layout), one fault: ipsr.fip=1 and
//                          wire 1 rises
//   wsi_fault_distinct     same with icvec=0x210
//   msi_edge_b_held        fctl.WSI=0, MSI vector 1 at 0x9000/0x55.  Fault 1
//                          sends an MSI whose B response is held; software
//                          clears fip, consumes the record, fault 2 sets fip
//                          again; then the B is released.  Two 0->1
//                          transitions of fip: two MSIs
//   msi_edge_no_hold       same without holding the B response: two MSIs
//
// Each run prints one PASS or FAIL line and finishes.

`timescale 1ns/1ps

module wsi_msi_irq_tb;
  import lint_wrapper::*;

  // register offsets (64-bit accesses)
  localparam logic [63:0] FCTL     = 64'h008;
  localparam logic [63:0] CQB      = 64'h018;
  localparam logic [63:0] CQH_CQT  = 64'h020;   // cqh [31:0], cqt [63:32]
  localparam logic [63:0] FQB      = 64'h028;
  localparam logic [63:0] FQH_FQT  = 64'h030;   // fqh [31:0], fqt [63:32]
  localparam logic [63:0] CQ_FQCSR = 64'h048;   // cqcsr [31:0], fqcsr [63:32]
  localparam logic [63:0] PQ_IPSR  = 64'h050;   // pqcsr [31:0], ipsr [63:32]
  localparam logic [63:0] ICVEC    = 64'h2F8;
  localparam logic [63:0] MSI1     = 64'h310;   // msi_cfg_tbl entry 1: address
  localparam logic [63:0] MSI1_DAT = 64'h318;   // data [31:0], vector control [63:32]

  // bits in the 64-bit views above
  localparam int CQON       = 16;
  localparam int FENCE_W_IP = 11;
  localparam int FQON       = 48;
  localparam int CIP        = 32;
  localparam int FIP        = 33;

  // memory map
  localparam logic [63:0] CQ_BASE  = 64'h1000;
  localparam logic [63:0] FQ_BASE  = 64'h3000;
  localparam logic [63:0] MSI_ADDR = 64'h9000;
  localparam logic [31:0] MSI_DATA = 32'h55;

  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
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
    .clk_i(clk_i), .rst_ni(rst_ni),
    .dev_tr_req_i(dev_tr_req_i), .dev_tr_resp_o(dev_tr_resp_o),
    .dev_comp_resp_i(dev_comp_resp_i), .dev_comp_req_o(dev_comp_req_o),
    .ds_resp_i(ds_resp_i), .ds_req_o(ds_req_o),
    .prog_req_i(prog_req_i), .prog_resp_o(prog_resp_o),
    .wsi_wires_o(wsi_wires_o)
  );

  always #5 clk_i = ~clk_i;

  int unsigned cycle;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) cycle <= 0; else cycle <= cycle + 1;

  string scenario;

  // ------------------------------------------------------------------ memory
  logic [63:0] mem [logic [63:0]];

  function automatic logic [63:0] rd(input logic [63:0] a);
    logic [63:0] k;
    k = {a[63:3], 3'b000};
    return mem.exists(k) ? mem[k] : 64'd0;
  endfunction

  function automatic void wr(input logic [63:0] a, input logic [63:0] d, input logic [7:0] strb);
    logic [63:0] k, v;
    k = {a[63:3], 3'b000};
    v = rd(k);
    for (int b = 0; b < 8; b++) if (strb[b]) v[8*b +: 8] = d[8*b +: 8];
    mem[k] = v;
  endfunction

  // ---------------------------------------------- data-structure port model
  // AR/AW always ready; reads are answered in order (INCR bursts); a write's
  // B response is withheld while its address is inside the hold window.
  typedef struct { logic [IdWidth-1:0] id; logic [63:0] addr; logic [7:0] len; } rd_t;
  typedef struct { logic [IdWidth-1:0] id; logic [63:0] addr; bit held; } wr_t;
  rd_t rd_q[$];
  wr_t aw_q[$];
  wr_t b_q[$];
  int  r_beat, w_beat, b_idx;
  bit  b_hold;
  logic [63:0] b_hold_lo, b_hold_hi;

  // MSI writes seen on the data-structure port (address window 0x9000-0x9fff)
  int unsigned msi_n;
  logic [63:0] msi_addr [8];
  logic [31:0] msi_data [8];
  int unsigned msi_cycle [8];

  logic r_valid_q, r_last_q, w_ready_q, b_valid_q;
  logic [IdWidth-1:0] r_id_q, b_id_q;
  logic [63:0] r_data_q;

  always_comb begin
    ds_resp_i = '0;
    ds_resp_i.ar_ready = 1'b1;
    ds_resp_i.aw_ready = 1'b1;
    ds_resp_i.w_ready  = w_ready_q;
    ds_resp_i.r_valid  = r_valid_q;
    ds_resp_i.r.id     = r_id_q;
    ds_resp_i.r.data   = r_data_q;
    ds_resp_i.r.resp   = axi_pkg::RESP_OKAY;
    ds_resp_i.r.last   = r_last_q;
    ds_resp_i.b_valid  = b_valid_q;
    ds_resp_i.b.id     = b_id_q;
    ds_resp_i.b.resp   = axi_pkg::RESP_OKAY;
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_q.delete(); aw_q.delete(); b_q.delete();
      r_beat = 0; w_beat = 0;
      r_valid_q <= 0; r_last_q <= 0; r_id_q <= '0; r_data_q <= '0;
      w_ready_q <= 0; b_valid_q <= 0; b_id_q <= '0;
    end else begin
      if (ds_req_o.ar_valid) begin
        rd_t e;
        e.id = ds_req_o.ar.id; e.addr = ds_req_o.ar.addr; e.len = ds_req_o.ar.len;
        rd_q.push_back(e);
      end
      if (r_valid_q && ds_req_o.r_ready) begin
        if (r_last_q) begin void'(rd_q.pop_front()); r_beat = 0; end
        else r_beat++;
      end
      if (ds_req_o.aw_valid) begin
        wr_t a;
        a.id = ds_req_o.aw.id; a.addr = ds_req_o.aw.addr;
        a.held = b_hold && a.addr >= b_hold_lo && a.addr < b_hold_hi;
        aw_q.push_back(a);
      end
      if (ds_req_o.w_valid && w_ready_q) begin
        logic [63:0] wa;
        wa = aw_q[0].addr + 8 * w_beat;
        wr(wa, ds_req_o.w.data, ds_req_o.w.strb);
        if (wa >= MSI_ADDR && wa < MSI_ADDR + 64'h1000) begin
          if (msi_n < 8) begin
            msi_addr[msi_n] = wa;
            msi_data[msi_n] = wa[2] ? ds_req_o.w.data[63:32] : ds_req_o.w.data[31:0];
            msi_cycle[msi_n] = cycle;
          end
          msi_n++;
        end
        if (ds_req_o.w.last) begin
          b_q.push_back(aw_q[0]);
          void'(aw_q.pop_front());
          w_beat = 0;
        end else w_beat++;
      end
      if (b_valid_q && ds_req_o.b_ready) b_q.delete(b_idx);

      // next outputs
      if (rd_q.size() != 0) begin
        r_valid_q <= 1; r_id_q <= rd_q[0].id;
        r_data_q <= rd(rd_q[0].addr + 8 * r_beat);
        r_last_q <= (r_beat == rd_q[0].len);
      end else begin
        r_valid_q <= 0; r_last_q <= 0;
      end
      w_ready_q <= (aw_q.size() != 0);
      // B: oldest response that is not held and has no older response with the same ID
      b_idx = -1;
      for (int i = 0; i < b_q.size() && b_idx < 0; i++) begin
        bit older;
        older = 0;
        for (int j = 0; j < i; j++) if (b_q[j].id == b_q[i].id) older = 1;
        if (!b_q[i].held && !older) b_idx = i;
      end
      b_valid_q <= (b_idx >= 0);
      b_id_q    <= (b_idx >= 0) ? b_q[b_idx].id : '0;
    end
  end

  task automatic release_b_hold();
    b_hold = 0;
    foreach (aw_q[i]) aw_q[i].held = 0;
    foreach (b_q[i]) b_q[i].held = 0;
  endtask

  // Translated traffic never reaches the downstream port here (all device
  // requests fault); keep it quiet.
  always_comb begin
    dev_comp_resp_i = '0;
    dev_comp_resp_i.aw_ready = 1'b1;
    dev_comp_resp_i.ar_ready = 1'b1;
    dev_comp_resp_i.w_ready  = 1'b1;
  end

  // ---------------------------------------------------------- WSI monitor
  int wire_rise [NumIRQWires];      // first cycle each wire is high, -1 if never
  logic [NumIRQWires-1:0] wires_seen;
  always @(posedge clk_i) begin
    if (rst_ni)
      for (int i = 0; i < NumIRQWires; i++)
        if (wsi_wires_o[i] && !wires_seen[i]) begin
          wires_seen[i] = 1'b1;
          wire_rise[i] = cycle;
        end
  end

  // ------------------------------------------------------ programming port
  task automatic reg_write(input logic [63:0] addr, input logic [63:0] data);
    bit aw_done, w_done, b_done;
    aw_done = 0; w_done = 0; b_done = 0;
    @(negedge clk_i);
    prog_req_i.aw = '0; prog_req_i.aw.addr = addr; prog_req_i.aw.size = 3'd3;
    prog_req_i.aw.burst = axi_pkg::BURST_INCR; prog_req_i.aw_valid = 1'b1;
    prog_req_i.w = '0; prog_req_i.w.data = data; prog_req_i.w.strb = '1;
    prog_req_i.w.last = 1'b1; prog_req_i.w_valid = 1'b1; prog_req_i.b_ready = 1'b1;
    while (!aw_done || !w_done) begin
      @(posedge clk_i);
      if (prog_req_i.aw_valid && prog_resp_o.aw_ready) aw_done = 1;
      if (prog_req_i.w_valid && prog_resp_o.w_ready) w_done = 1;
      @(negedge clk_i);
      if (aw_done) prog_req_i.aw_valid = 1'b0;
      if (w_done) prog_req_i.w_valid = 1'b0;
    end
    while (!b_done) begin @(posedge clk_i); if (prog_resp_o.b_valid) b_done = 1; end
    @(negedge clk_i); prog_req_i.b_ready = 1'b0;
  endtask

  task automatic reg_read(input logic [63:0] addr, output logic [63:0] data);
    bit ar_done, r_done;
    ar_done = 0; r_done = 0; data = '0;
    @(negedge clk_i);
    prog_req_i.ar = '0; prog_req_i.ar.addr = addr; prog_req_i.ar.size = 3'd3;
    prog_req_i.ar.burst = axi_pkg::BURST_INCR; prog_req_i.ar_valid = 1'b1;
    prog_req_i.r_ready = 1'b1;
    while (!ar_done) begin
      @(posedge clk_i); if (prog_req_i.ar_valid && prog_resp_o.ar_ready) ar_done = 1;
      @(negedge clk_i); if (ar_done) prog_req_i.ar_valid = 1'b0;
    end
    while (!r_done) begin
      @(posedge clk_i); if (prog_resp_o.r_valid) begin data = prog_resp_o.r.data; r_done = 1; end
    end
    @(negedge clk_i); prog_req_i.r_ready = 1'b0;
  endtask

  // poll until bit is set; returns 1 on success
  task automatic wait_bit(input logic [63:0] addr, input int bitpos, input int unsigned limit,
                          output bit ok, output logic [63:0] value);
    int unsigned t0;
    t0 = cycle;
    reg_read(addr, value);
    while (!value[bitpos] && cycle - t0 < limit) reg_read(addr, value);
    ok = value[bitpos];
  endtask

  // ------------------------------------------------------- device writes
  // One 8-byte write from device 1; waits for its B response.
  task automatic device_write(input logic [3:0] id, input logic [63:0] addr, output logic [1:0] resp);
    bit aw_done, w_done, b_done;
    aw_done = 0; w_done = 0; b_done = 0; resp = '0;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0;
    dev_tr_req_i.aw.id = id; dev_tr_req_i.aw.addr = addr; dev_tr_req_i.aw.len = 8'd0;
    dev_tr_req_i.aw.size = 3'd3; dev_tr_req_i.aw.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.aw.stream_id = 24'd1;
    dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0; dev_tr_req_i.w.data = 64'h1111_0000 | addr; dev_tr_req_i.w.strb = '1;
    dev_tr_req_i.w.last = 1'b1; dev_tr_req_i.w_valid = 1'b1;
    while (!aw_done || !w_done) begin
      @(posedge clk_i);
      if (dev_tr_req_i.aw_valid && dev_tr_resp_o.aw_ready) aw_done = 1;
      if (dev_tr_req_i.w_valid && dev_tr_resp_o.w_ready) w_done = 1;
      if (dev_tr_resp_o.b_valid) begin b_done = 1; resp = dev_tr_resp_o.b.resp; end
      @(negedge clk_i);
      if (aw_done) dev_tr_req_i.aw_valid = 1'b0;
      if (w_done) dev_tr_req_i.w_valid = 1'b0;
    end
    while (!b_done) begin
      @(posedge clk_i);
      if (dev_tr_resp_o.b_valid) begin b_done = 1; resp = dev_tr_resp_o.b.resp; end
    end
  endtask

  // --------------------------------------------------------------- results
  bit done;
  task automatic finish_pass(input string msg);
    $display("PASS %s: %s", scenario, msg);
    done = 1;
    $finish;
  endtask
  task automatic finish_fail(input string msg, input string expected);
    $display("FAIL %s: %s; expected %s", scenario, msg, expected);
    done = 1;
    $finish;
  endtask

  int unsigned max_cycles;
  always @(posedge clk_i)
    if (rst_ni && !done && cycle > max_cycles) begin
      $display("FAIL %s: no result after %0d cycles; expected the scenario to complete", scenario, cycle);
      $finish;
    end

  function automatic string wire_str();
    string s;
    string w;
    s = "";
    for (int i = 0; i < NumIRQWires; i++) begin
      if (wires_seen[i]) w = $sformatf("wire%0d rises@%0d", i, wire_rise[i]);
      else w = $sformatf("wire%0d never", i);
      s = (i == 0) ? w : {s, ", ", w};
    end
    return s;
  endfunction

  function automatic logic [63:0] qbase(input logic [63:0] base, input int log2szm1);
    return ((base >> 12) << 10) | log2szm1;
  endfunction

  // ---------------------------------------------------------- WSI scenarios
  // IOFENCE.C with WSI=1 on the command queue; cip goes to vector icvec.civ.
  task automatic run_wsi_iofence(input logic [63:0] icvec, input int expect_wire);
    logic [63:0] v, ipsr;
    bit ok;
    reg_write(FCTL, 64'h2);                         // fctl.WSI = 1
    reg_write(ICVEC, icvec);
    reg_write(CQB, qbase(CQ_BASE, 5));
    reg_write(CQ_FQCSR, 64'h3);                     // cqen | cie
    wait_bit(CQ_FQCSR, CQON, 200, ok, v);
    if (!ok) begin finish_fail($sformatf("cqcsr=%h", v[31:0]), "cqon=1"); return; end
    mem[CQ_BASE]     = 64'h0000_0000_0000_0802;     // IOFENCE.C, WSI=1, AV=0
    mem[CQ_BASE + 8] = 64'h0;
    reg_write(CQH_CQT, 64'h1 << 32);                // cqt = 1
    wait_bit(CQ_FQCSR, FENCE_W_IP, 400, ok, v);
    if (!ok) begin finish_fail($sformatf("cqcsr=%h", v[31:0]), "fence_w_ip=1"); return; end
    repeat (10) @(posedge clk_i);
    reg_read(PQ_IPSR, ipsr);
    repeat (30) @(posedge clk_i);
    if (ipsr[CIP] && wires_seen == (1 << expect_wire))
      finish_pass($sformatf("icvec=%h ipsr.cip=%0d %s", icvec[15:0], ipsr[CIP], wire_str()));
    else
      finish_fail($sformatf("icvec=%h ipsr.cip=%0d %s", icvec[15:0], ipsr[CIP], wire_str()),
                  $sformatf("ipsr.cip=1 and only wire %0d rises", expect_wire));
  endtask

  // One fault record; fip goes to vector icvec.fiv.
  task automatic run_wsi_fault(input logic [63:0] icvec, input int expect_wire);
    logic [63:0] v, ipsr, rec0;
    logic [1:0] resp;
    bit ok;
    reg_write(FCTL, 64'h2);                         // fctl.WSI = 1
    reg_write(ICVEC, icvec);
    reg_write(FQB, qbase(FQ_BASE, 4));
    reg_write(CQ_FQCSR, 64'h3 << 32);               // fqen | fie
    wait_bit(CQ_FQCSR, FQON, 200, ok, v);
    if (!ok) begin finish_fail($sformatf("fqcsr=%h", v[63:32]), "fqon=1"); return; end
    device_write(4'd1, 64'h5000, resp);
    wait_bit(PQ_IPSR, FIP, 300, ok, v);
    repeat (10) @(posedge clk_i);
    reg_read(PQ_IPSR, ipsr);
    repeat (30) @(posedge clk_i);
    rec0 = rd(FQ_BASE);
    if (ipsr[FIP] && rec0[11:0] == 12'd256 && wires_seen == (1 << expect_wire))
      finish_pass($sformatf("icvec=%h fault cause=%0d ipsr.fip=%0d %s", icvec[15:0],
                            rec0[11:0], ipsr[FIP], wire_str()));
    else
      finish_fail($sformatf("icvec=%h fault cause=%0d ipsr.fip=%0d %s", icvec[15:0],
                            rec0[11:0], ipsr[FIP], wire_str()),
                  $sformatf("cause=256, ipsr.fip=1 and only wire %0d rises", expect_wire));
  endtask

  // ---------------------------------------------------------- MSI scenario
  task automatic run_msi(input bit hold);
    logic [63:0] v, ipsr, fq;
    logic [1:0] resp;
    bit ok, fail;
    int unsigned t0, refire;
    string s;
    reg_write(FCTL, 64'h0);                         // fctl.WSI = 0: MSI
    reg_write(ICVEC, 64'h210);                      // fiv = 1
    reg_write(MSI1, MSI_ADDR);
    reg_write(MSI1_DAT, {32'h0, MSI_DATA});         // data, vector control = 0 (unmasked)
    reg_write(FQB, qbase(FQ_BASE, 4));
    reg_write(CQ_FQCSR, 64'h3 << 32);               // fqen | fie
    wait_bit(CQ_FQCSR, FQON, 200, ok, v);
    if (!ok) begin finish_fail($sformatf("fqcsr=%h", v[63:32]), "fqon=1"); return; end
    if (hold) begin b_hold_lo = MSI_ADDR; b_hold_hi = MSI_ADDR + 8; b_hold = 1; end

    device_write(4'd1, 64'h5000, resp);             // fault 1: fip 0->1, MSI
    t0 = cycle;
    while (msi_n == 0 && cycle - t0 < 400) @(posedge clk_i);
    if (msi_n == 0) begin finish_fail("no MSI for the first fault", "an MSI write"); return; end
    reg_write(PQ_IPSR, 64'h1 << FIP);               // clear fip (RW1C)
    reg_read(FQH_FQT, fq);
    reg_write(FQH_FQT, 64'h1);                      // consume record 0: fqh = 1
    device_write(4'd2, 64'h6000, resp);             // fault 2: fip 0->1 again
    wait_bit(PQ_IPSR, FIP, 400, ok, ipsr);
    if (!ok) begin finish_fail("fip not set by the second fault", "ipsr.fip=1"); return; end
    refire = cycle;
    repeat (20) @(posedge clk_i);
    if (hold) release_b_hold();
    repeat (100) @(posedge clk_i);
    reg_read(PQ_IPSR, ipsr);
    reg_read(FQH_FQT, fq);

    s = $sformatf("fqt=%0d, fip set again (read) at cycle %0d, %0d MSI(s):", fq[63:32], refire, msi_n);
    fail = (msi_n != 2) || (fq[63:32] != 2);
    for (int i = 0; i < msi_n && i < 8; i++) begin
      s = {s, $sformatf(" [addr=%h data=%h cycle %0d]", msi_addr[i], msi_data[i], msi_cycle[i])};
      if (msi_addr[i] != MSI_ADDR || msi_data[i] != MSI_DATA) fail = 1;
    end
    if (!fail) finish_pass(s);
    else finish_fail(s, $sformatf("fqt=2 and two MSIs, each addr=%h data=%h", MSI_ADDR, MSI_DATA));
  endtask

  // --------------------------------------------------------------- driver
  initial begin
    done = 0; msi_n = 0; b_hold = 0; b_hold_lo = '0; b_hold_hi = '0; wires_seen = '0;
    for (int i = 0; i < NumIRQWires; i++) wire_rise[i] = -1;
    dev_tr_req_i = '0; dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    prog_req_i = '0;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "none";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 5000;
    repeat (6) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);
    case (scenario)
      "wsi_iofence_shared":   run_wsi_iofence(64'h000, 0);
      "wsi_iofence_distinct": run_wsi_iofence(64'h210, 0);
      "wsi_fault_shared":     run_wsi_fault(64'h110, 1);
      "wsi_fault_distinct":   run_wsi_fault(64'h210, 1);
      "msi_edge_b_held":      run_msi(1'b1);
      "msi_edge_no_hold":     run_msi(1'b0);
      default: begin
        $display("FAIL %s: unknown scenario; expected one of wsi_iofence_shared, wsi_iofence_distinct, wsi_fault_shared, wsi_fault_distinct, msi_edge_b_held, msi_edge_no_hold", scenario);
        $finish;
      end
    endcase
  end
endmodule
