// SPDX-License-Identifier: Apache-2.0
//
// Directed testbench: a walk whose request has ended (an orphaned walk) must
// not install its result into the IOTLB or report its error against another
// request.
//
// The full IOMMU (lint_checks top) is connected to two small memories: one
// on the data-structure port (device contexts, page tables, command and fault
// queues) and one on the completion port (device data).  Device requests,
// register accesses and command-queue submissions are driven by tasks.
//
// Scenarios (+scenario=<name>); each runs several short simulations with a
// reset in between and prints one PASS or FAIL line:
//
//   cross_device_hit  (bug)
//       Device 1 (two stages, PSCID 5) writes an IOVA and its context is
//       invalidated while the page-table walk runs; device 4 (first stage
//       only, same PSCID value) then writes the same IOVA, which it has not
//       mapped.  128 combinations of timing and second-stage leaf size.  Device
//       4's data must never reach memory.
//   no_context_inval  (control)
//       Same traffic without the context invalidation: device 4's write must
//       be answered with SLVERR without reaching memory.
//   own_page_after_inval  (control)
//       Same as cross_device_hit, but device 4 writes its own page: OKAY, data
//       at 0x100c008.
//   cross_device_fault  (bug)
//       cross_device_hit, also requiring that device 4's write is answered
//       with SLVERR in every combination.
//   fault_record_did  (bug)
//       Device 4 reads an unmapped IOVA; its tc.V is cleared and
//       IODIR.INVAL_DDT for device 4 submitted at delays -10..5.  Every fault
//       record must have TTYP 2 (untranslated read) and DID 4.
//   inval_after_fault  (control)
//       Same, with the invalidation after the read completed: one record,
//       cause 13, TTYP 2, DID 4.

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
  logic [63:0] wr_addr [$], wr_data [$];   // log of written beats

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
      rq.delete(); wq.delete(); bq.delete(); wr_addr.delete(); wr_data.delete();
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
        wr_addr.push_back(a); wr_data.push_back(req_i.w.data);
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


module orphan_walk_tb;
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
  bit          aw_taken [16];                // write request handed over
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
    aw_taken[id] = aw_done;
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
                          REG_FQB = 64'h28, REG_FQH = 64'h30, REG_CQCSR = 64'h48;

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
  localparam logic [63:0] CMD_IODIR_INVAL_DDT = 64'h3;      // add DV and DID for one device
  localparam logic [63:0] CMD_IOFENCE_C       = 64'h3002;   // PR=PW=1

  function automatic logic [63:0] iodir_inval_ddt(input int did);
    return CMD_IODIR_INVAL_DDT | (64'd1 << 33) | (64'(did) << 40);
  endfunction

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

  // Sv39x4 identity second-stage mapping of the 2 MiB or 1 GiB region that
  // holds gpa (2 MiB leaves go into table l1).
  task automatic gmap_identity(input logic [63:0] root, input logic [63:0] l1, input bit giga,
                               input logic [63:0] gpa);
    if (giga) begin
      ds_mem.mem[root + 8 * gpa[40:30]] = pte({gpa[63:30], 30'b0}, PTE_LEAF);
    end else begin
      ds_mem.mem[root + 8 * gpa[40:30]] = pte(l1, PTE_TABLE);
      ds_mem.mem[l1   + 8 * gpa[29:21]] = pte({gpa[63:21], 21'b0}, PTE_LEAF);
    end
  endtask

  // Reset the IOMMU and both memories, then enable the command and fault
  // queues and set ddtp to one-level mode.
  task automatic restart();
    logic [63:0] v;
    rst_ni = 1'b0;
    dev_tr_req_i = '0; dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    prog_req_i = '0;
    repeat (4) @(posedge clk_i);
    ds_mem.mem.delete(); comp_mem.mem.delete();
    for (int i = 0; i < 16; i++) begin aw_taken[i] = 0; b_seen[i] = 0; r_seen[i] = 0; end
    cq_tail = 0;
    @(negedge clk_i); rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
    reg_write(REG_CQB, (CQ_BASE >> 12) << 10 | 64'd5, 8'hFF);     // 64 entries
    reg_write(REG_FQB, (FQ_BASE >> 12) << 10 | 64'd4, 8'hFF);     // 32 entries
    reg_write(REG_CQCSR, 64'h0000_0001_0000_0001, 8'hFF);         // cqen, fqen
    reg_write(REG_DDTP, (DDT_BASE >> 12) << 10 | 64'd2, 8'hFF);   // 1LVL
    do reg_read(REG_DDTP, v); while (v[4]);                       // busy
  endtask


  function automatic string resp_str(input bit seen, input logic [1:0] resp);
    return !seen ? $sformatf("no response in %0d cycles", TIMEOUT) :
           resp == axi_pkg::RESP_OKAY ? "OKAY" :
           resp == axi_pkg::RESP_SLVERR ? "SLVERR" : $sformatf("resp %0d", resp);
  endfunction

  // First doublewords of the fault records written so far.
  task automatic fault_records(output logic [63:0] recs [$]);
    logic [63:0] v;
    reg_read(REG_FQH, v);                       // fqh in [31:0], fqt in [63:32]
    recs.delete();
    for (int i = v[31:0]; i != v[63:32]; i = (i + 1) % 32)
      recs.push_back(ds_mem.mem[FQ_BASE + 32 * i]);
  endtask

  function automatic string record_str(input logic [63:0] r);
    return $sformatf("cause %0d ttyp %0d did %0d", r[11:0], r[39:34], r[63:40]);
  endfunction

  // ------------------------------------------------------------ scenarios
  //
  // Cross-device scenarios.  Device 1 uses both stages: first stage Sv39
  // (PSCID 5) maps IOVA 0x4000_5000 to GPA 0x1009000, second stage Sv39x4
  // (GSCID 1) maps that with an identity 2 MiB or 1 GiB leaf.  Device 4 uses
  // only the first stage, with the same PSCID value 5, and maps only IOVA
  // 0x4000_7000 (to 0x100c000).
  //
  // Device 4 first writes its own page, so its context is cached.  Device 1
  // then writes 0x4000_5000.  k1 cycles later software clears device 1's
  // tc.V and submits IODIR.INVAL_DDT for device 1 and IOFENCE.C.  k2 cycles
  // after that (and once device 1's write has been handed over) device 4
  // writes 0x4000_5000, which it has not mapped.
  //
  // mode 0: as above.
  // mode 1: no tc.V change and no IODIR.INVAL_DDT (IOFENCE.C only).
  // mode 2: as mode 0, but device 4 writes 0x4000_7008 (its own page).
  //
  // Returns where device 4's data reached memory ('1 if nowhere) and the
  // response to its write.
  localparam logic [63:0] DEV4_DATA = 64'hD4D4_0000_0000_0004;
  localparam logic [63:0] NOWHERE   = '1;
  localparam int K2 [4] = '{0, 2, 4, 8};

  task automatic run_cross_device(input int k1, input int k2, input bit giga, input int mode,
                                  output logic [63:0] landed, output bit answered,
                                  output logic [1:0] resp);
    bit warm;
    int unsigned t0;
    restart();
    set_dc(1, 5, 64'h100000, 64'h180000, 1);
    map_4k(64'h100000, 64'h101000, 64'h102000, 64'h4000_5000, 64'h1009000);
    gmap_identity(64'h180000, 64'h184000, giga, 64'h100000);
    gmap_identity(64'h180000, 64'h184000, giga, 64'h1009000);
    set_dc(4, 5, 64'h10c000);
    map_4k(64'h10c000, 64'h10d000, 64'h10e000, 64'h4000_7000, 64'h100c000);

    dev_write(1, 4, 64'h4000_7000, 64'hA1);    // caches device 4's context
    wait_done(1, 1, warm);

    if (mode != 1) cq_put(iodir_inval_ddt(1));
    cq_put(CMD_IOFENCE_C);
    fork dev_write(2, 1, 64'h4000_5000, 64'hB2); join_none
    repeat (k1) @(posedge clk_i);
    if (mode != 1) ds_mem.mem[DDT_BASE + 64 * 1] = 64'h0;      // device 1: tc.V = 0
    cq_submit();
    repeat (k2) @(posedge clk_i);
    t0 = cycle;
    while (!aw_taken[2] && cycle - t0 < TIMEOUT) @(posedge clk_i);
    dev_write(3, 4, mode == 2 ? 64'h4000_7008 : 64'h4000_5000, DEV4_DATA);
    wait_done(3, 1, answered);
    repeat (200) @(posedge clk_i);

    landed = NOWHERE;
    foreach (comp_mem.wr_data[i]) if (comp_mem.wr_data[i] == DEV4_DATA) landed = comp_mem.wr_addr[i];
    resp = b_resp[3];
    if (!warm) begin answered = 0; landed = 64'hBAD; end   // setup failed
  endtask

  // Fault-record scenarios.  Device 4 (first stage only, context cached)
  // reads IOVA 0x8020_1f80, whose level-1 PTE is invalid.  Software clears
  // device 4's tc.V and submits IODIR.INVAL_DDT for device 4 and IOFENCE.C
  // `delay` cycles after the read is issued (before it if negative), or after
  // the read has completed.  Returns the fault records written.
  task automatic run_fault_record(input int delay, input bit after, output bit answered,
                                  output logic [63:0] recs [$]);
    bit warm;
    restart();
    set_dc(4, 4, 64'h10c000);
    map_4k(64'h10c000, 64'h10d000, 64'h10e000, 64'h4000_3000, 64'h100c000);
    ds_mem.mem[64'h10c000 + 8 * 2] = pte(64'h10f000, PTE_TABLE);  // 0x8020_1f80: level-1 PTE invalid

    dev_write(1, 4, 64'h4000_3ff0, 64'hA1);    // caches device 4's context
    wait_done(1, 1, warm);

    cq_put(iodir_inval_ddt(4));
    cq_put(CMD_IOFENCE_C);
    if (!after && delay < 0) begin
      ds_mem.mem[DDT_BASE + 64 * 4] = 64'h0;                  // device 4: tc.V = 0
      fork cq_submit(); join_none
      repeat (-delay) @(posedge clk_i);
    end
    fork dev_read(2, 4, 64'h8020_1f80); join_none
    if (after) wait_done(2, 0, answered);
    else repeat (delay > 0 ? delay : 0) @(posedge clk_i);
    if (after || delay >= 0) begin
      ds_mem.mem[DDT_BASE + 64 * 4] = 64'h0;
      cq_submit();
    end
    wait_done(2, 0, answered);
    repeat (300) @(posedge clk_i);
    fault_records(recs);
    if (!warm) answered = 0;
  endtask

  initial begin
    string scenario, line, examples;
    int nbad, nruns, nwrong, nlost;

    if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
    nbad = 0; nruns = 0; nwrong = 0; nlost = 0; examples = "";

    case (scenario)

      // 2 leaf sizes x k1 in 0..15 x k2 in {0, 2, 4, 8} = 128 combinations
      "cross_device_hit", "no_context_inval", "own_page_after_inval", "cross_device_fault": begin
        int mode;
        logic [63:0] landed;
        logic [1:0] resp;
        bit answered, ok;
        mode = scenario == "no_context_inval" ? 1 : scenario == "own_page_after_inval" ? 2 : 0;
        for (int g = 0; g < 2; g++)
          for (int k1 = 0; k1 < 16; k1++)
            foreach (K2[i]) begin
              run_cross_device(k1, K2[i], g, mode, landed, answered, resp);
              nruns++;
              line = $sformatf("%s k1=%0d k2=%0d", g ? "1G" : "2M", k1, K2[i]);
              if (mode == 2)
                ok = answered && resp == axi_pkg::RESP_OKAY && landed == 64'h100c008;
              else if (scenario == "cross_device_hit")
                ok = landed == NOWHERE;                // only the cross-device access counts
              else
                ok = answered && resp == axi_pkg::RESP_SLVERR && landed == NOWHERE;
              if (landed != NOWHERE && mode != 2) nwrong++;
              if (!answered) nlost++;
              $display("  %-16s %s: device-4 write %s%s", line, ok ? "ok    " : "FAILED",
                       resp_str(answered, resp),
                       landed == NOWHERE ? "" : $sformatf(", data at 0x%0h", landed));
              if (!ok) begin
                nbad++;
                if (nbad <= 3)
                  examples = {examples, examples == "" ? "" : "; ",
                              $sformatf("%s: %s%s", line, resp_str(answered, resp),
                                        landed == NOWHERE ? "" : $sformatf(" at 0x%0h", landed))};
              end
            end
        case (scenario)
          "cross_device_hit":
            if (nbad == 0)
              $display("PASS %s: device-4 write reached memory in 0 of %0d combinations (no response in %0d)",
                       scenario, nruns, nlost);
            else
              $display("FAIL %s: device-4 write reached memory in %0d of %0d combinations (e.g. %s); expected 0",
                       scenario, nwrong, nruns, examples);
          "own_page_after_inval":
            if (nbad == 0)
              $display("PASS %s: device-4 write answered OKAY and arrived at 0x100c008 in %0d of %0d combinations",
                       scenario, nruns, nruns);
            else
              $display("FAIL %s: %0d of %0d combinations wrong (e.g. %s); expected OKAY at 0x100c008 in all",
                       scenario, nbad, nruns, examples);
          default:
            if (nbad == 0)
              $display("PASS %s: device-4 write answered SLVERR without reaching memory in %0d of %0d combinations",
                       scenario, nruns, nruns);
            else
              $display("FAIL %s: %0d of %0d combinations wrong (e.g. %s); expected SLVERR without reaching memory in all",
                       scenario, nbad, nruns, examples);
        endcase
      end

      // delay -10..5, or once after the read completed
      "fault_record_did", "inval_after_fault": begin
        logic [63:0] recs [$];
        bit answered, ok;
        int first, last, nnone;
        string bad_recs, seen_str;
        int seen [string];
        if (scenario == "fault_record_did") begin first = -10; last = 5; end
        else begin first = 0; last = 0; end
        bad_recs = ""; nnone = 0;
        for (int d = first; d <= last; d++) begin
          run_fault_record(d, scenario == "inval_after_fault", answered, recs);
          nruns++;
          ok = answered && r_resp[2] == axi_pkg::RESP_SLVERR;
          line = "";
          if (recs.size() == 0) nnone++;
          foreach (recs[i]) begin
            line = {line, line == "" ? "" : ", ", record_str(recs[i])};
            seen[record_str(recs[i])] = seen.exists(record_str(recs[i])) ? seen[record_str(recs[i])] + 1 : 1;
            if (recs[i][39:34] != 6'd2 || recs[i][63:40] != 24'd4) begin
              ok = 0;
              if (bad_recs == "") bad_recs = record_str(recs[i]);
            end
          end
          if (scenario == "inval_after_fault" && recs.size() != 1) ok = 0;
          $display("  delay %3d %s: device-4 read %s, fault records: %s", d, ok ? "ok    " : "FAILED",
                   resp_str(answered, r_resp[2]), line == "" ? "none" : line);
          if (!ok) begin
            nbad++;
            examples = {examples, examples == "" ? "" : ",", $sformatf("%0d", d)};
          end
        end
        seen_str = "";
        foreach (seen[r]) seen_str = {seen_str, seen_str == "" ? "" : ", ", $sformatf("%s (%0d)", r, seen[r])};
        if (nnone != 0) seen_str = {seen_str, seen_str == "" ? "" : ", ", $sformatf("no record (%0d)", nnone)};
        if (nbad == 0)
          $display("PASS %s: only TTYP 2 / DID 4 records in %0d of %0d runs: %s",
                   scenario, nruns, nruns, seen_str);
        else
          $display("FAIL %s: %0d of %0d runs wrong (delay %s; e.g. record %s); expected only records with TTYP 2 and DID 4",
                   scenario, nbad, nruns, examples, bad_recs == "" ? "none" : bad_recs);
      end

      default: $display("FAIL %s: unknown scenario", scenario);
    endcase
    $finish;
  end

  // Last-resort guard (each run is bounded by TIMEOUT already).
  initial begin
    #100ms;
    $display("FAIL watchdog: simulation did not finish");
    $finish;
  end

endmodule
