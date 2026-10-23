// SPDX-License-Identifier: Apache-2.0
//
// Directed testbench: an invalidation that lands while a page-table or
// context walk is in progress must not leave a later request without a walk.
//
// The full IOMMU (lint_checks top) is connected to two small memories: one
// on the data-structure port (device contexts, page tables, command and fault
// queues) and one on the completion port (device data).  Device requests,
// register accesses and command-queue submissions are driven by tasks.
//
// Scenarios (+scenario=<name>); each runs one or more short simulations with
// a reset in between and prints one PASS or FAIL line:
//
//   ddt_inval_between_walks  (bug)
//       Device 4 (its context cached) reads an unmapped IOVA, so its request
//       ends with a page fault after a first-stage walk.  Device 1 writes a
//       mapped IOVA in the same cycle.  IODIR.INVAL_DDT (all devices) and
//       IOFENCE.C are submitted from 6 cycles before to 10 cycles after both
//       requests are issued (delay -6..10).  Device 1's write and a later read
//       from device 2 must complete at every delay.
//   no_inval  (control)
//       The same traffic without the invalidation.
//   ddt_inval_two_stage  (bug)
//       Like ddt_inval_between_walks, with an Sv39x4 second stage for device
//       4, so its faulting walk is longer, and delays -8..15.
//   flush_at_walk_end  (bug)
//       Device 3 (its context cached) writes an IOVA that misses in the IOTLB.
//       IOTINVAL.VMA for GSCID 5, which no device uses, and IOFENCE.C are
//       submitted from 5 cycles before to 10 cycles after the write is issued
//       (delay -5..10), so at some delays the flush executes in the cycle the
//       page-table walk installs its result.  The write and a later read from
//       device 2 must complete at every delay.
//   flush_after_walk  (control)
//       The same, with the invalidation submitted after the write completed.

`timescale 1ns/1ps

// One AXI4 slave with a sparse 64-bit memory.  AR and AW are always ready;
// reads are answered in order, one beat per cycle (INCR); B follows the last
// W beat.  `mem` is accessed directly by the testbench.
module axi_mem
  import lint_wrapper::*;
(
  input  logic  clk_i,
  input  logic  rst_ni,
  input  req_t  req_i,
  output resp_t resp_o
);
  logic [63:0] mem [logic [63:0]];

  function automatic logic [63:0] read64(input logic [63:0] a);
    return mem.exists({a[63:3], 3'b0}) ? mem[{a[63:3], 3'b0}] : 64'd0;
  endfunction

  typedef struct { logic [IdWidth-1:0] id; logic [63:0] addr; int len; } burst_t;
  burst_t rq [$];          // accepted reads
  burst_t wq [$];          // accepted writes waiting for data
  logic [IdWidth-1:0] bq [$];
  int rbeat, wbeat;
  logic r_valid, r_last, b_valid, w_ready;
  logic [IdWidth-1:0] r_id, b_id;
  logic [63:0] r_data;

  always_comb begin
    resp_o = '0;
    resp_o.ar_ready = 1'b1;
    resp_o.aw_ready = 1'b1;
    resp_o.w_ready  = w_ready;
    resp_o.r_valid  = r_valid;
    resp_o.r.id     = r_id;
    resp_o.r.data   = r_data;
    resp_o.r.last   = r_last;
    resp_o.r.resp   = axi_pkg::RESP_OKAY;
    resp_o.b_valid  = b_valid;
    resp_o.b.id     = b_id;
    resp_o.b.resp   = axi_pkg::RESP_OKAY;
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rq.delete(); wq.delete(); bq.delete();
      rbeat = 0; wbeat = 0;
      r_valid <= 1'b0; r_last <= 1'b0; b_valid <= 1'b0; w_ready <= 1'b0;
      r_id <= '0; b_id <= '0; r_data <= '0;
    end else begin
      burst_t nb;
      if (r_valid && req_i.r_ready) begin
        if (r_last) begin void'(rq.pop_front()); rbeat = 0; end
        else rbeat++;
      end
      if (req_i.ar_valid) begin
        nb.id = req_i.ar.id; nb.addr = req_i.ar.addr; nb.len = req_i.ar.len;
        rq.push_back(nb);
      end
      if (req_i.aw_valid) begin
        nb.id = req_i.aw.id; nb.addr = req_i.aw.addr; nb.len = req_i.aw.len;
        wq.push_back(nb);
      end
      if (req_i.w_valid && w_ready) begin
        logic [63:0] a, v;
        a = wq[0].addr + 8 * wbeat;
        v = read64(a);
        for (int b = 0; b < 8; b++) if (req_i.w.strb[b]) v[8*b +: 8] = req_i.w.data[8*b +: 8];
        mem[{a[63:3], 3'b0}] = v;
        if (req_i.w.last) begin
          bq.push_back(wq[0].id);
          void'(wq.pop_front());
          wbeat = 0;
        end else wbeat++;
      end
      if (b_valid && req_i.b_ready) void'(bq.pop_front());

      w_ready <= (wq.size() != 0);
      r_valid <= (rq.size() != 0);
      r_last  <= (rq.size() != 0) && (rbeat == rq[0].len);
      if (rq.size() != 0) begin
        r_id   <= rq[0].id;
        r_data <= read64(rq[0].addr + 8 * rbeat);
      end
      b_valid <= (bq.size() != 0);
      b_id    <= (bq.size() != 0) ? bq[0] : '0;
    end
  end
endmodule


module walker_start_tb;
  import lint_wrapper::*;

  // ------------------------------------------------------------------ DUT
  logic       clk_i = 1'b0;
  logic       rst_ni = 1'b0;
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

  axi_mem ds_mem   (.clk_i, .rst_ni, .req_i(ds_req_o),       .resp_o(ds_resp_i));
  axi_mem comp_mem (.clk_i, .rst_ni, .req_i(dev_comp_req_o), .resp_o(dev_comp_resp_i));

  always #5 clk_i = ~clk_i;

  int unsigned cycle;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) cycle <= 0; else cycle <= cycle + 1;

  localparam int unsigned TIMEOUT = 2000;   // cycles a request may take

  // ---------------------------------------------------------- device side
  // Responses are recorded per AXI ID.  The testbench keeps at most one write
  // and one read outstanding on the translation request port.
  bit          b_seen [16], r_seen [16];
  logic [1:0]  b_resp [16], r_resp [16];
  logic [63:0] r_data [16];
  int unsigned done_at [16];

  always @(posedge clk_i) begin
    if (rst_ni && dev_tr_resp_o.b_valid) begin
      b_seen[dev_tr_resp_o.b.id] = 1'b1;
      b_resp[dev_tr_resp_o.b.id] = dev_tr_resp_o.b.resp;
      done_at[dev_tr_resp_o.b.id] = cycle;
    end
    if (rst_ni && dev_tr_resp_o.r_valid && dev_tr_resp_o.r.last) begin
      r_seen[dev_tr_resp_o.r.id] = 1'b1;
      r_resp[dev_tr_resp_o.r.id] = dev_tr_resp_o.r.resp;
      r_data[dev_tr_resp_o.r.id] = dev_tr_resp_o.r.data;
      done_at[dev_tr_resp_o.r.id] = cycle;
    end
  end

  // Untranslated, unprivileged, single-beat 64-bit write.  Gives up (leaving
  // the request asserted) if it is not accepted within TIMEOUT cycles.
  task automatic dev_write(input int id, input int did, input logic [63:0] iova,
                           input logic [63:0] data);
    bit aw_done = 0, w_done = 0;
    int unsigned t0 = cycle;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0;
    dev_tr_req_i.aw.id = id; dev_tr_req_i.aw.addr = iova;
    dev_tr_req_i.aw.size = 3'd3; dev_tr_req_i.aw.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.aw.stream_id = did;
    dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0; dev_tr_req_i.w.data = data; dev_tr_req_i.w.strb = '1;
    dev_tr_req_i.w.last = 1'b1; dev_tr_req_i.w_valid = 1'b1;
    while (!(aw_done && w_done) && cycle - t0 < TIMEOUT) begin
      @(posedge clk_i);
      if (dev_tr_resp_o.aw_ready) aw_done = 1;
      if (dev_tr_resp_o.w_ready)  w_done = 1;
      @(negedge clk_i);
      if (aw_done) dev_tr_req_i.aw_valid = 1'b0;
      if (w_done)  dev_tr_req_i.w_valid = 1'b0;
    end
  endtask

  // Untranslated, unprivileged, single-beat 64-bit read.
  task automatic dev_read(input int id, input int did, input logic [63:0] iova);
    bit ar_done = 0;
    int unsigned t0 = cycle;
    @(negedge clk_i);
    dev_tr_req_i.ar = '0;
    dev_tr_req_i.ar.id = id; dev_tr_req_i.ar.addr = iova;
    dev_tr_req_i.ar.size = 3'd3; dev_tr_req_i.ar.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.ar.stream_id = did;
    dev_tr_req_i.ar_valid = 1'b1;
    while (!ar_done && cycle - t0 < TIMEOUT) begin
      @(posedge clk_i);
      if (dev_tr_resp_o.ar_ready) ar_done = 1;
      @(negedge clk_i);
      if (ar_done) dev_tr_req_i.ar_valid = 1'b0;
    end
  endtask

  // Wait for the response to the write (or read) with this ID.
  task automatic wait_done(input int id, input bit is_write, output bit ok);
    int unsigned t0 = cycle;
    while (!(is_write ? b_seen[id] : r_seen[id]) && cycle - t0 < TIMEOUT) @(posedge clk_i);
    ok = is_write ? b_seen[id] : r_seen[id];
  endtask

  // ------------------------------------------------- programming interface
  localparam logic [63:0] REG_DDTP = 64'h10, REG_CQB = 64'h18, REG_CQH_CQT = 64'h20,
                          REG_FQB = 64'h28, REG_CQCSR = 64'h48;

  task automatic reg_write(input logic [63:0] addr, input logic [63:0] data, input logic [7:0] strb);
    bit aw_done = 0, w_done = 0;
    @(negedge clk_i);
    prog_req_i.aw = '0; prog_req_i.aw.addr = addr; prog_req_i.aw.size = 3'd3;
    prog_req_i.aw.burst = axi_pkg::BURST_INCR; prog_req_i.aw_valid = 1'b1;
    prog_req_i.w = '0; prog_req_i.w.data = data; prog_req_i.w.strb = strb;
    prog_req_i.w.last = 1'b1; prog_req_i.w_valid = 1'b1; prog_req_i.b_ready = 1'b1;
    while (!(aw_done && w_done)) begin
      @(posedge clk_i);
      if (prog_resp_o.aw_ready) aw_done = 1;
      if (prog_resp_o.w_ready)  w_done = 1;
      @(negedge clk_i);
      if (aw_done) prog_req_i.aw_valid = 1'b0;
      if (w_done)  prog_req_i.w_valid = 1'b0;
    end
    do @(posedge clk_i); while (!prog_resp_o.b_valid);
    @(negedge clk_i); prog_req_i.b_ready = 1'b0;
  endtask

  task automatic reg_read(input logic [63:0] addr, output logic [63:0] data);
    @(negedge clk_i);
    prog_req_i.ar = '0; prog_req_i.ar.addr = addr; prog_req_i.ar.size = 3'd3;
    prog_req_i.ar.burst = axi_pkg::BURST_INCR; prog_req_i.ar_valid = 1'b1;
    prog_req_i.r_ready = 1'b1;
    do @(posedge clk_i); while (!prog_resp_o.ar_ready);
    @(negedge clk_i); prog_req_i.ar_valid = 1'b0;
    while (!prog_resp_o.r_valid) @(posedge clk_i);
    data = prog_resp_o.r.data;
    @(negedge clk_i); prog_req_i.r_ready = 1'b0;
  endtask

  // ------------------------------------------------------- data structures
  localparam logic [63:0] CQ_BASE = 64'h1000, DDT_BASE = 64'h2000, FQ_BASE = 64'h3000;

  // First doubleword of the commands used here (the second one is zero)
  localparam logic [63:0] CMD_IODIR_INVAL_DDT = 64'h3;      // DV=0: all devices
  localparam logic [63:0] CMD_IOTINVAL_VMA    = 64'h1;
  localparam logic [63:0] CMD_IOFENCE_C       = 64'h3002;   // PR=PW=1

  int cq_tail;

  task automatic cq_put(input logic [63:0] dw0);
    ds_mem.mem[CQ_BASE + 16 * cq_tail]     = dw0;
    ds_mem.mem[CQ_BASE + 16 * cq_tail + 8] = 64'h0;
    cq_tail++;
  endtask

  task automatic cq_submit();
    // cqt is the upper half of the doubleword at 0x20 (cqh, below it, is read-only)
    reg_write(REG_CQH_CQT, 64'(cq_tail) << 32, 8'hF0);
  endtask

  // Extended-format device context: first stage Sv39 with the given root,
  // second stage Sv39x4 with root groot (Bare if groot is 0), no process
  // context, MSI translation off.
  task automatic set_dc(input int did, input int pscid, input logic [63:0] root,
                        input logic [63:0] groot = 0, input int gscid = 0);
    logic [63:0] dc = DDT_BASE + 64 * did;
    for (int i = 1; i < 8; i++) ds_mem.mem[dc + 8 * i] = 64'h0;
    if (groot != 0) ds_mem.mem[dc + 8] = (64'd8 << 60) | (64'(gscid) << 44) | (groot >> 12);
    ds_mem.mem[dc + 16] = 64'(pscid) << 12;               // ta.PSCID
    ds_mem.mem[dc + 24] = (64'd8 << 60) | (root >> 12);   // fsc: Sv39
    ds_mem.mem[dc]      = 64'h1;                          // tc.V
  endtask

  function automatic logic [63:0] pte(input logic [63:0] pa, input logic [7:0] flags);
    return ((pa >> 12) << 10) | 64'(flags);
  endfunction

  localparam logic [7:0] PTE_TABLE = 8'h01;   // V
  localparam logic [7:0] PTE_LEAF  = 8'hD7;   // V R W U A D

  // Sv39 4 KiB mapping through the given root, level-1 and level-0 tables.
  task automatic map_4k(input logic [63:0] root, input logic [63:0] l1, input logic [63:0] l0,
                        input logic [63:0] iova, input logic [63:0] pa);
    ds_mem.mem[root + 8 * iova[38:30]] = pte(l1, PTE_TABLE);
    ds_mem.mem[l1   + 8 * iova[29:21]] = pte(l0, PTE_TABLE);
    ds_mem.mem[l0   + 8 * iova[20:12]] = pte(pa, PTE_LEAF);
  endtask

  // Sv39x4 4 KiB second-stage mapping (GPA -> SPA).
  task automatic gmap_4k(input logic [63:0] root, input logic [63:0] l1, input logic [63:0] l0,
                         input logic [63:0] gpa, input logic [63:0] spa);
    ds_mem.mem[root + 8 * gpa[40:30]] = pte(l1, PTE_TABLE);
    ds_mem.mem[l1   + 8 * gpa[29:21]] = pte(l0, PTE_TABLE);
    ds_mem.mem[l0   + 8 * gpa[20:12]] = pte(spa, PTE_LEAF);
  endtask

  // Reset the IOMMU and both memories, then enable the command and fault
  // queues and set ddtp to one-level mode.  Device 2 (used for the final
  // read) maps IOVA 0x4000_7000 to 0x100e000.
  task automatic restart();
    logic [63:0] v;
    rst_ni = 1'b0;
    dev_tr_req_i = '0; dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    prog_req_i = '0;
    repeat (4) @(posedge clk_i);
    ds_mem.mem.delete(); comp_mem.mem.delete();
    for (int i = 0; i < 16; i++) begin b_seen[i] = 0; r_seen[i] = 0; end
    cq_tail = 0;
    @(negedge clk_i); rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
    set_dc(2, 2, 64'h104000);
    map_4k(64'h104000, 64'h105000, 64'h106000, 64'h4000_7000, 64'h100e000);
    comp_mem.mem[64'h100e010] = 64'h2222_0000_0000_0010;
    reg_write(REG_CQB, (CQ_BASE >> 12) << 10 | 64'd5, 8'hFF);     // 64 entries
    reg_write(REG_FQB, (FQ_BASE >> 12) << 10 | 64'd4, 8'hFF);     // 32 entries
    reg_write(REG_CQCSR, 64'h0000_0001_0000_0001, 8'hFF);         // cqen, fqen
    reg_write(REG_DDTP, (DDT_BASE >> 12) << 10 | 64'd2, 8'hFF);   // 1LVL
    do reg_read(REG_DDTP, v); while (v[4]);                       // busy
  endtask

  // Final check that the IOMMU still serves an unrelated device.
  task automatic final_read(input int id, output bit ok);
    dev_read(id, 2, 64'h4000_7010);
    wait_done(id, 0, ok);
    ok = ok && r_resp[id] == axi_pkg::RESP_OKAY && r_data[id] == 64'h2222_0000_0000_0010;
  endtask

  // ------------------------------------------------------------ scenarios
  // Each run returns ok, the cycle at which the final read completed, and,
  // if it failed, what went wrong.

  function automatic string resp_str(input bit seen, input logic [1:0] resp);
    return !seen ? $sformatf("no response in %0d cycles", TIMEOUT) :
           resp == axi_pkg::RESP_OKAY ? "OKAY" :
           resp == axi_pkg::RESP_SLVERR ? "SLVERR" : $sformatf("resp %0d", resp);
  endfunction

  // Device 4 reads an unmapped IOVA (level-1 PTE invalid) while device 1
  // writes a mapped one.  With two_stage, device 4 also uses an Sv39x4 second
  // stage (identity, 4 KiB pages), which makes its page-table walk longer.
  task automatic run_between_walks(input int delay, input bit inval, input bit two_stage,
                                   output bit ok, output int unsigned at, output string why);
    bit warm, wr, rd, fin;
    logic [63:0] gpas [5] = '{64'h10c000, 64'h10d000, 64'h10e000, 64'h10f000, 64'h100c000};
    restart();
    if (two_stage) begin
      set_dc(4, 4, 64'h10c000, 64'h180000, 4);
      foreach (gpas[i])
        gmap_4k(64'h180000, 64'h184000, gpas[i] < 64'h200000 ? 64'h185000 : 64'h186000,
                gpas[i], gpas[i]);
    end else begin
      set_dc(4, 4, 64'h10c000);
    end
    map_4k(64'h10c000, 64'h10d000, 64'h10e000, 64'h4000_3000, 64'h100c000);
    ds_mem.mem[64'h10c000 + 8 * 2] = pte(64'h10f000, PTE_TABLE);  // IOVA 0x8020_1f80 faults
    set_dc(1, 1, 64'h100000);
    map_4k(64'h100000, 64'h101000, 64'h102000, 64'h4000_5000, 64'h1009000);

    dev_write(1, 4, 64'h4000_3ff0, 64'hA1);    // caches device 4's context
    wait_done(1, 1, warm);

    // The invalidation is submitted `delay` cycles after both requests are
    // issued (before them if delay is negative).
    if (inval) begin
      cq_put(CMD_IODIR_INVAL_DDT); cq_put(CMD_IOFENCE_C);
      if (delay < 0) begin
        fork cq_submit(); join_none
        repeat (-delay) @(posedge clk_i);
      end
    end
    fork
      dev_read(2, 4, 64'h8020_1f80);
      dev_write(3, 1, 64'h4000_5f80, 64'hB3);
    join_none
    if (inval && delay >= 0) begin
      repeat (delay) @(posedge clk_i);
      cq_submit();
    end
    wait_done(3, 1, wr);
    wait_done(2, 0, rd);
    final_read(4, fin);

    ok = warm && wr && rd && fin
         && b_resp[3] == axi_pkg::RESP_OKAY && comp_mem.mem[64'h1009f80] == 64'hB3
         && r_resp[2] == axi_pkg::RESP_SLVERR;
    at = done_at[4];
    why = $sformatf("device-4 read %s, device-1 write %s, device-2 read %s",
                    resp_str(rd, r_resp[2]), resp_str(wr, b_resp[3]), resp_str(fin, r_resp[4]));
  endtask

  // Device 3 writes an IOVA that misses in the IOTLB; an IOTINVAL.VMA that
  // matches no entry is submitted `delay` cycles later (or after the write).
  task automatic run_walk_end(input int delay, input bit after,
                              output bit ok, output int unsigned at, output string why);
    bit warm, wr, fin;
    restart();
    set_dc(3, 3, 64'h110000);
    map_4k(64'h110000, 64'h111000, 64'h112000, 64'h4001_1000, 64'h1011000);
    map_4k(64'h110000, 64'h111000, 64'h112000, 64'h4001_2000, 64'h1012000);

    dev_write(1, 3, 64'h4001_1000, 64'hA1);    // caches device 3's context
    wait_done(1, 1, warm);

    // The invalidation is submitted `delay` cycles after the write is issued
    // (before it if delay is negative), or after the write has completed.
    cq_put((64'd5 << 44) | (64'd1 << 33) | CMD_IOTINVAL_VMA);   // GV=1, GSCID=5
    cq_put(CMD_IOFENCE_C);
    if (!after && delay < 0) begin
      fork cq_submit(); join_none
      repeat (-delay) @(posedge clk_i);
    end
    fork dev_write(2, 3, 64'h4001_2008, 64'hB2); join_none
    if (after) begin
      wait_done(2, 1, wr);
      cq_submit();
    end else if (delay >= 0) begin
      repeat (delay) @(posedge clk_i);
      cq_submit();
    end
    wait_done(2, 1, wr);
    final_read(3, fin);

    ok = warm && wr && fin
         && b_resp[2] == axi_pkg::RESP_OKAY && comp_mem.mem[64'h1012008] == 64'hB2;
    at = done_at[3];
    why = $sformatf("device-3 write %s, device-2 read %s",
                    resp_str(wr, b_resp[2]), resp_str(fin, r_resp[3]));
  endtask

  initial begin
    string scenario, why, failed;
    string delays_by_why [string];
    int first, runs, nfail;
    int unsigned at, at_min, at_max;
    bit ok;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
    // Swept scenarios run delay = first .. first + runs - 1.
    case (scenario)
      "ddt_inval_between_walks":          begin first = -6; runs = 17; end
      "flush_at_walk_end":                begin first = -5; runs = 16; end
      "ddt_inval_two_stage":              begin first = -8; runs = 24; end
      "no_inval", "flush_after_walk":     begin first = 0;  runs = 1;  end
      default: begin
        $display("FAIL %s: unknown scenario", scenario);
        $finish;
      end
    endcase
    nfail = 0; at_min = '1; at_max = 0;
    for (int d = first; d < first + runs; d++) begin
      case (scenario)
        "ddt_inval_between_walks": run_between_walks(d, 1, 0, ok, at, why);
        "ddt_inval_two_stage":     run_between_walks(d, 1, 1, ok, at, why);
        "no_inval":                run_between_walks(0, 0, 0, ok, at, why);
        "flush_at_walk_end":       run_walk_end(d, 0, ok, at, why);
        default:                   run_walk_end(0, 1, ok, at, why);
      endcase
      $display("  delay %2d: %s: %s%s", d, ok ? "ok    " : "FAILED", why,
               ok ? $sformatf(" (final read done at cycle %0d)", at) : "");
      if (ok) begin
        if (at < at_min) at_min = at;
        if (at > at_max) at_max = at;
      end else begin
        nfail++;
        delays_by_why[why] = {delays_by_why.exists(why) ? {delays_by_why[why], ","} : "",
                              $sformatf("%0d", d)};
      end
    end
    if (nfail == 0) begin
      $display("PASS %s: %0d of %0d run(s) completed, final read done at cycle %s", scenario,
               runs, runs, at_min == at_max ? $sformatf("%0d", at_min)
                                            : $sformatf("%0d-%0d", at_min, at_max));
    end else begin
      failed = "";
      foreach (delays_by_why[w])
        failed = {failed, failed == "" ? "" : "; ", "delay ", delays_by_why[w], ": ", w};
      $display("FAIL %s: %0d of %0d run(s) failed (%s); expected every run to complete with OKAY",
               scenario, nfail, runs, failed);
    end
    $finish;
  end

  // Last-resort guard (each run is bounded by TIMEOUT already).
  initial begin
    #50ms;
    $display("FAIL watchdog: simulation did not finish");
    $finish;
  end

endmodule
