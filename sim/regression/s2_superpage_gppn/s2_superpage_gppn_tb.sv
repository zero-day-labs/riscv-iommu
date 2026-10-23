// SPDX-License-Identifier: Apache-2.0
//
// Two-stage translation with a second-stage superpage.
//
// Device 1 has first-stage (Sv39) and second-stage (Sv39x4) translation
// enabled.  The second stage is an identity map built from 2 MiB or 1 GiB
// leaves.  The device writes and then reads one IOVA, and the testbench
// checks the system physical address of both accesses on the downstream
// port.  The read is an IOTLB hit on the entry the write's walk installed.
//
// Scenarios (+scenario=<name>):
//   s1_4k_s2_2m   IOVA 0x4000_3000 -> 4 KiB leaf -> GPA 0x100_9000, 2 MiB G-stage
//   s1_4k_s2_1g   same first stage, 1 GiB G-stage leaf
//   s1_2m_s2_1g   IOVA 0x8020_1000 -> 2 MiB leaf -> GPA 0x100_1000, 1 GiB G-stage
//   s1_2m_s2_2m   same first stage, 2 MiB G-stage leaves
//   s2_only_4k    first stage Bare, GPA 0x4000_2000 -> 4 KiB G-stage leaf -> 0x100_b000
//
// Each scenario prints one PASS or FAIL line and finishes.

`timescale 1ns/1ps

module s2_superpage_gppn_tb;
  import lint_wrapper::*;

  // ------------------------------------------------------------------ DUT
  logic clk_i, rst_ni;
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

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  longint unsigned cycle;
  always @(posedge clk_i) cycle <= cycle + 1;

  // ------------------------------------------------- memory map and encodings
  localparam logic [63:0] REG_DDTP  = 64'h10;
  localparam logic [63:0] REG_CQB   = 64'h18;
  localparam logic [63:0] REG_FQB   = 64'h28;
  localparam logic [63:0] REG_CQCSR = 64'h48;   // cqcsr low word, fqcsr high word

  localparam logic [63:0] CQ_BASE  = 64'h1000;
  localparam logic [63:0] DDT_BASE = 64'h2000;   // one-level DDT, 64-byte contexts
  localparam logic [63:0] FQ_BASE  = 64'h3000;
  localparam logic [63:0] S1_ROOT  = 64'h10_0000;
  localparam logic [63:0] G_ROOT   = 64'h18_0000; // 16 KiB aligned
  localparam logic [63:0] G_L1     = 64'h18_4000;
  localparam logic [63:0] G_L0     = 64'h18_5000;
  localparam int unsigned DEVICE_ID = 1;

  localparam logic [7:0] PTE_PTR  = 8'h01;        // V: pointer to the next level
  localparam logic [7:0] PTE_LEAF = 8'hd7;        // V R W U A D

  function automatic logic [63:0] pte(input logic [43:0] ppn, input logic [7:0] flags);
    return {10'd0, ppn, 2'b00, flags};
  endfunction

  // ------------------------------------------------------------- memory model
  logic [63:0] mem [logic [63:0]];

  function automatic logic [63:0] mem_rd(input logic [63:0] a);
    logic [63:0] k = {a[63:3], 3'b000};
    return mem.exists(k) ? mem[k] : 64'd0;
  endfunction

  function automatic void mem_wr(input logic [63:0] a, input logic [63:0] d, input logic [7:0] strb);
    logic [63:0] k = {a[63:3], 3'b000};
    logic [63:0] v = mem_rd(k);
    for (int b = 0; b < 8; b++) if (strb[b]) v[8*b +: 8] = d[8*b +: 8];
    mem[k] = v;
  endfunction

  // A simple AXI slave over the memory: accepts every address, returns read
  // bursts in order one beat per cycle, and answers writes after the last beat.
  typedef struct { logic [IdWidth-1:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size; } burst_t;

  function automatic burst_t burst(input logic [IdWidth-1:0] id, input logic [63:0] addr,
                                   input logic [7:0] len, input logic [2:0] size);
    burst_t b;
    b.id = id; b.addr = addr; b.len = len; b.size = size;
    return b;
  endfunction

  // ---- data-structure port (IOMMU reads DDT, page tables, queues)
  burst_t ds_ar_q[$], ds_aw_q[$];
  logic [IdWidth-1:0] ds_b_q[$];
  int ds_r_beat, ds_w_beat;
  logic ds_r_valid, ds_r_last, ds_w_ready, ds_b_valid;
  logic [IdWidth-1:0] ds_r_id, ds_b_id;
  logic [63:0] ds_r_data;

  always_comb begin
    ds_resp_i          = '0;
    ds_resp_i.ar_ready = 1'b1;
    ds_resp_i.aw_ready = 1'b1;
    ds_resp_i.w_ready  = ds_w_ready;
    ds_resp_i.b_valid  = ds_b_valid;
    ds_resp_i.b.id     = ds_b_id;
    ds_resp_i.r_valid  = ds_r_valid;
    ds_resp_i.r.id     = ds_r_id;
    ds_resp_i.r.data   = ds_r_data;
    ds_resp_i.r.last   = ds_r_last;
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ds_ar_q.delete(); ds_aw_q.delete(); ds_b_q.delete();
      ds_r_beat = 0; ds_w_beat = 0;
      ds_r_valid <= 0; ds_r_last <= 0; ds_r_id <= '0; ds_r_data <= '0;
      ds_w_ready <= 0; ds_b_valid <= 0; ds_b_id <= '0;
    end else begin
      if (ds_req_o.ar_valid)
        ds_ar_q.push_back(burst(ds_req_o.ar.id, ds_req_o.ar.addr, ds_req_o.ar.len, ds_req_o.ar.size));
      if (ds_r_valid && ds_req_o.r_ready) begin
        if (ds_r_last) begin void'(ds_ar_q.pop_front()); ds_r_beat = 0; end
        else ds_r_beat++;
      end
      if (ds_req_o.aw_valid)
        ds_aw_q.push_back(burst(ds_req_o.aw.id, ds_req_o.aw.addr, ds_req_o.aw.len, ds_req_o.aw.size));
      if (ds_req_o.w_valid && ds_w_ready) begin
        mem_wr(ds_aw_q[0].addr + (ds_w_beat << ds_aw_q[0].size), ds_req_o.w.data, ds_req_o.w.strb);
        if (ds_req_o.w.last) begin
          ds_b_q.push_back(ds_aw_q[0].id); void'(ds_aw_q.pop_front()); ds_w_beat = 0;
        end else ds_w_beat++;
      end
      if (ds_b_valid && ds_req_o.b_ready) void'(ds_b_q.pop_front());

      ds_r_valid <= (ds_ar_q.size() != 0);
      if (ds_ar_q.size() != 0) begin
        ds_r_id   <= ds_ar_q[0].id;
        ds_r_data <= mem_rd(ds_ar_q[0].addr + (ds_r_beat << ds_ar_q[0].size));
        ds_r_last <= (ds_r_beat == ds_ar_q[0].len);
      end else ds_r_last <= 0;
      ds_w_ready <= (ds_aw_q.size() != 0);
      ds_b_valid <= (ds_b_q.size() != 0);
      ds_b_id    <= (ds_b_q.size() != 0) ? ds_b_q[0] : '0;
    end
  end

  // ---- downstream port (translated device accesses); logs every address
  burst_t cp_ar_q[$], cp_aw_q[$];
  logic [IdWidth-1:0] cp_b_q[$];
  int cp_r_beat, cp_w_beat;
  logic cp_r_valid, cp_r_last, cp_w_ready, cp_b_valid;
  logic [IdWidth-1:0] cp_r_id, cp_b_id;
  logic [63:0] cp_r_data;
  logic [63:0] down_aw[$], down_ar[$];   // addresses seen on the downstream port

  always_comb begin
    dev_comp_resp_i          = '0;
    dev_comp_resp_i.ar_ready = 1'b1;
    dev_comp_resp_i.aw_ready = 1'b1;
    dev_comp_resp_i.w_ready  = cp_w_ready;
    dev_comp_resp_i.b_valid  = cp_b_valid;
    dev_comp_resp_i.b.id     = cp_b_id;
    dev_comp_resp_i.r_valid  = cp_r_valid;
    dev_comp_resp_i.r.id     = cp_r_id;
    dev_comp_resp_i.r.data   = cp_r_data;
    dev_comp_resp_i.r.last   = cp_r_last;
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cp_ar_q.delete(); cp_aw_q.delete(); cp_b_q.delete();
      cp_r_beat = 0; cp_w_beat = 0;
      cp_r_valid <= 0; cp_r_last <= 0; cp_r_id <= '0; cp_r_data <= '0;
      cp_w_ready <= 0; cp_b_valid <= 0; cp_b_id <= '0;
    end else begin
      if (dev_comp_req_o.ar_valid) begin
        cp_ar_q.push_back(burst(dev_comp_req_o.ar.id, dev_comp_req_o.ar.addr, dev_comp_req_o.ar.len, dev_comp_req_o.ar.size));
        down_ar.push_back(dev_comp_req_o.ar.addr);
      end
      if (cp_r_valid && dev_comp_req_o.r_ready) begin
        if (cp_r_last) begin void'(cp_ar_q.pop_front()); cp_r_beat = 0; end
        else cp_r_beat++;
      end
      if (dev_comp_req_o.aw_valid) begin
        cp_aw_q.push_back(burst(dev_comp_req_o.aw.id, dev_comp_req_o.aw.addr, dev_comp_req_o.aw.len, dev_comp_req_o.aw.size));
        down_aw.push_back(dev_comp_req_o.aw.addr);
      end
      if (dev_comp_req_o.w_valid && cp_w_ready) begin
        mem_wr(cp_aw_q[0].addr + (cp_w_beat << cp_aw_q[0].size), dev_comp_req_o.w.data, dev_comp_req_o.w.strb);
        if (dev_comp_req_o.w.last) begin
          cp_b_q.push_back(cp_aw_q[0].id); void'(cp_aw_q.pop_front()); cp_w_beat = 0;
        end else cp_w_beat++;
      end
      if (cp_b_valid && dev_comp_req_o.b_ready) void'(cp_b_q.pop_front());

      cp_r_valid <= (cp_ar_q.size() != 0);
      if (cp_ar_q.size() != 0) begin
        cp_r_id   <= cp_ar_q[0].id;
        cp_r_data <= mem_rd(cp_ar_q[0].addr + (cp_r_beat << cp_ar_q[0].size));
        cp_r_last <= (cp_r_beat == cp_ar_q[0].len);
      end else cp_r_last <= 0;
      cp_w_ready <= (cp_aw_q.size() != 0);
      cp_b_valid <= (cp_b_q.size() != 0);
      cp_b_id    <= (cp_b_q.size() != 0) ? cp_b_q[0] : '0;
    end
  end

  // -------------------------------------------------------- device responses
  int          b_count, r_count;
  logic [1:0]  b_resp, r_resp;
  logic [63:0] r_data;

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      b_count <= 0; r_count <= 0;
    end else begin
      if (dev_tr_resp_o.b_valid && dev_tr_req_i.b_ready) begin
        b_resp <= dev_tr_resp_o.b.resp; b_count <= b_count + 1;
      end
      if (dev_tr_resp_o.r_valid && dev_tr_req_i.r_ready && dev_tr_resp_o.r.last) begin
        r_resp <= dev_tr_resp_o.r.resp; r_data <= dev_tr_resp_o.r.data; r_count <= r_count + 1;
      end
    end
  end

  // ----------------------------------------------------------- device accesses
  // One 8-byte INCR access from DEVICE_ID; returns when the response arrives.
  task automatic dev_write(input logic [63:0] iova, input logic [63:0] data, output logic [1:0] resp);
    bit aw_done = 0, w_done = 0;
    int n = b_count;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0;
    dev_tr_req_i.aw.addr = iova; dev_tr_req_i.aw.size = 3'd3; dev_tr_req_i.aw.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.aw.stream_id = DEVICE_ID;
    dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0;
    dev_tr_req_i.w.data = data; dev_tr_req_i.w.strb = '1; dev_tr_req_i.w.last = 1'b1;
    dev_tr_req_i.w_valid = 1'b1;
    while (!aw_done || !w_done) begin
      @(posedge clk_i);
      if (dev_tr_req_i.aw_valid && dev_tr_resp_o.aw_ready) aw_done = 1;
      if (dev_tr_req_i.w_valid && dev_tr_resp_o.w_ready) w_done = 1;
      @(negedge clk_i);
      if (aw_done) dev_tr_req_i.aw_valid = 1'b0;
      if (w_done) dev_tr_req_i.w_valid = 1'b0;
    end
    while (b_count == n) @(posedge clk_i);
    resp = b_resp;
  endtask

  task automatic dev_read(input logic [63:0] iova, output logic [1:0] resp, output logic [63:0] data);
    int n = r_count;
    @(negedge clk_i);
    dev_tr_req_i.ar = '0;
    dev_tr_req_i.ar.addr = iova; dev_tr_req_i.ar.size = 3'd3; dev_tr_req_i.ar.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.ar.stream_id = DEVICE_ID;
    dev_tr_req_i.ar_valid = 1'b1;
    do @(posedge clk_i); while (!dev_tr_resp_o.ar_ready);
    @(negedge clk_i);
    dev_tr_req_i.ar_valid = 1'b0;
    while (r_count == n) @(posedge clk_i);
    resp = r_resp; data = r_data;
  endtask

  // ----------------------------------------------------- programming interface
  task automatic reg_write(input logic [63:0] addr, input logic [63:0] data);
    bit aw_done = 0, w_done = 0;
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
    do @(posedge clk_i); while (!prog_resp_o.b_valid);
    @(negedge clk_i); prog_req_i.b_ready = 1'b0;
  endtask

  task automatic reg_read(input logic [63:0] addr, output logic [63:0] data);
    @(negedge clk_i);
    prog_req_i.ar = '0; prog_req_i.ar.addr = addr; prog_req_i.ar.size = 3'd3;
    prog_req_i.ar.burst = axi_pkg::BURST_INCR; prog_req_i.ar_valid = 1'b1; prog_req_i.r_ready = 1'b1;
    do @(posedge clk_i); while (!prog_resp_o.ar_ready);
    @(negedge clk_i); prog_req_i.ar_valid = 1'b0;
    do @(posedge clk_i); while (!prog_resp_o.r_valid);
    data = prog_resp_o.r.data;
    @(negedge clk_i); prog_req_i.r_ready = 1'b0;
  endtask

  function automatic string addr_list(input logic [63:0] q[$]);
    string s = "";
    if (q.size() == 0) return "none";
    foreach (q[i]) s = {s, (i ? "," : ""), $sformatf("0x%0h", q[i])};
    return s;
  endfunction

  // ----------------------------------------------------------------- scenario
  string       scenario;
  logic [63:0] iova, expected;
  int unsigned max_cycles;

  always @(posedge clk_i)
    if (max_cycles != 0 && cycle > max_cycles) begin
      $display("FAIL %s: no completion after %0d cycles; expected the write and the read to complete",
               scenario, max_cycles);
      $finish;
    end

  // Device context of DEVICE_ID: first stage Sv39 (or Bare), second stage Sv39x4.
  task automatic set_device_context(input bit s1_on);
    logic [63:0] dc = DDT_BASE + 64 * DEVICE_ID;
    mem[dc + 8]  = {4'd8, 16'd1, 44'(G_ROOT >> 12)};             // iohgatp: Sv39x4, GSCID 1
    mem[dc + 16] = 64'd1 << 12;                                   // ta: PSCID 1
    mem[dc + 24] = s1_on ? {4'd8, 16'd0, 44'(S1_ROOT >> 12)} : 64'd0; // fsc: Sv39 or Bare
    mem[dc + 32] = 64'd0;                                         // msiptp: off
    mem[dc + 40] = 64'd0;
    mem[dc + 48] = 64'd0;
    mem[dc + 56] = 64'd0;
    mem[dc + 0]  = 64'd1;                                         // tc: V
  endtask

  // Identity second stage for GPA [0, 1 GiB): one 1 GiB leaf or 512 2 MiB leaves.
  task automatic set_identity_g_stage(input bit use_1g);
    if (use_1g) mem[G_ROOT] = pte(44'h0, PTE_LEAF);
    else begin
      mem[G_ROOT] = pte(44'(G_L1 >> 12), PTE_PTR);
      for (int i = 0; i < 512; i++) mem[G_L1 + 8 * i] = pte(44'(i << 9), PTE_LEAF);
    end
  endtask

  // First stage, at identical guest and system physical addresses:
  //   root[1] -> 0x10_1000, [0] -> 0x10_2000, [3] = 4 KiB leaf (IOVA 0x4000_3000 -> GPA 0x100_9000)
  //   root[2] -> 0x10_3000, [1] = 2 MiB leaf (IOVA 0x8020_0000 -> GPA 0x100_0000)
  task automatic set_first_stage(input bit leaf_2m);
    if (!leaf_2m) begin
      mem[S1_ROOT + 8 * 1]   = pte(44'h101, PTE_PTR);
      mem[64'h10_1000]       = pte(44'h102, PTE_PTR);
      mem[64'h10_2000 + 8 * 3] = pte(44'h1009, PTE_LEAF);
    end else begin
      mem[S1_ROOT + 8 * 2]   = pte(44'h103, PTE_PTR);
      mem[64'h10_3000 + 8 * 1] = pte(44'h1000, PTE_LEAF);
    end
  endtask

  initial begin : main
    logic [1:0]  wresp, rresp;
    logic [63:0] rdata, ddtp;
    logic [63:0] wdata = 64'h5157_0000_0000_0001;

    rst_ni = 1'b0; cycle = 0;
    dev_tr_req_i = '0; dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    prog_req_i = '0;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "s1_4k_s2_2m";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 20000;

    case (scenario)
      "s1_4k_s2_2m": begin set_identity_g_stage(0); set_first_stage(0); iova = 64'h4000_3000; expected = 64'h100_9000; end
      "s1_4k_s2_1g": begin set_identity_g_stage(1); set_first_stage(0); iova = 64'h4000_3000; expected = 64'h100_9000; end
      "s1_2m_s2_1g": begin set_identity_g_stage(1); set_first_stage(1); iova = 64'h8020_1000; expected = 64'h100_1000; end
      "s1_2m_s2_2m": begin set_identity_g_stage(0); set_first_stage(1); iova = 64'h8020_1000; expected = 64'h100_1000; end
      "s2_only_4k": begin
        // GPA 0x4000_2000: root[1] -> 0x18_4000, [0] -> 0x18_5000, [2] = 4 KiB leaf -> 0x100_b000
        mem[G_ROOT + 8 * 1] = pte(44'(G_L1 >> 12), PTE_PTR);
        mem[G_L1]           = pte(44'(G_L0 >> 12), PTE_PTR);
        mem[G_L0 + 8 * 2]   = pte(44'h100b, PTE_LEAF);
        iova = 64'h4000_2000; expected = 64'h100_b000;
      end
      default: begin
        $display("FAIL %s: unknown scenario; expected one of s1_4k_s2_2m s1_4k_s2_1g s1_2m_s2_1g s1_2m_s2_2m s2_only_4k",
                 scenario);
        $finish;
      end
    endcase
    set_device_context(scenario != "s2_only_4k");

    repeat (6) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);

    // Command and fault queues on, then the one-level device directory.
    reg_write(REG_CQB, {10'd0, 44'(CQ_BASE >> 12), 5'd0, 5'd5});
    reg_write(REG_FQB, {10'd0, 44'(FQ_BASE >> 12), 5'd0, 5'd4});
    reg_write(REG_CQCSR, 64'h1_0000_0001);
    repeat (32) @(posedge clk_i);
    reg_write(REG_DDTP, {10'd0, 44'(DDT_BASE >> 12), 6'd0, 4'd2});
    do reg_read(REG_DDTP, ddtp); while (ddtp[4]);

    // The write walks both stages and fills the IOTLB; the read hits it.
    dev_write(iova, wdata, wresp);
    dev_read(iova, rresp, rdata);
    repeat (20) @(posedge clk_i);

    if (down_aw.size() == 1 && down_aw[0] == expected && down_ar.size() == 1 && down_ar[0] == expected
        && wresp == axi_pkg::RESP_OKAY && rresp == axi_pkg::RESP_OKAY && rdata == wdata)
      $display("PASS %s: iova 0x%0h write to 0x%0h, read from 0x%0h", scenario, iova, down_aw[0], down_ar[0]);
    else
      $display("FAIL %s: iova 0x%0h write to %s, read from %s (bresp %0d, rresp %0d, data 0x%0h); expected 0x%0h for both",
               scenario, iova, addr_list(down_aw), addr_list(down_ar), wresp, rresp, rdata, expected);
    $finish;
  end
endmodule
