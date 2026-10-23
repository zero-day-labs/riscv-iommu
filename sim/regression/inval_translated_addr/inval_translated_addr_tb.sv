// SPDX-License-Identifier: Apache-2.0
//
// Translated address of a request that races a device-directory invalidation.
//
// Device 1 has first-stage (Sv39) translation only; IOVA 0x4000_2000 maps to
// physical page 0x100_6000.  The device accesses IOVA 0x4000_25a8 once to
// warm the DDTC and IOTLB.  Software then submits IODIR.INVAL_DDT (all
// devices) and IOFENCE.C, and the device repeats the access `gap` cycles
// after the command-queue tail write.  The testbench checks the address of
// the repeated access on the downstream port and its data.
//
// Scenarios (+scenario=<name>):
//   read_inval_sweep    read, gap = 0 .. 24, each gap from reset
//   write_inval_sweep   write, gap = 0 .. 24, each gap from reset
//   read_no_inval       read, no command submitted
//   write_no_inval      write, no command submitted
//   read_inval_done     read, issued after the command queue head reaches the tail
//   write_inval_done    write, issued after the command queue head reaches the tail
//
// Each scenario prints one PASS or FAIL line and finishes.

`timescale 1ns/1ps

module inval_translated_addr_tb;
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
  localparam logic [63:0] REG_CQHT  = 64'h20;   // cqh low word, cqt high word
  localparam logic [63:0] REG_FQB   = 64'h28;
  localparam logic [63:0] REG_CQCSR = 64'h48;   // cqcsr low word, fqcsr high word

  localparam logic [63:0] CQ_BASE  = 64'h1000;
  localparam logic [63:0] DDT_BASE = 64'h2000;   // one-level DDT, 64-byte contexts
  localparam logic [63:0] FQ_BASE  = 64'h3000;
  localparam logic [63:0] S1_ROOT  = 64'h10_0000;
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
  localparam logic [63:0] IOVA     = 64'h4000_25a8;
  localparam logic [63:0] EXPECTED = 64'h100_65a8;
  localparam int          GAPS     = 25;

  string       scenario;
  int unsigned max_cycles;

  always @(posedge clk_i)
    if (max_cycles != 0 && cycle > max_cycles) begin
      $display("FAIL %s: no completion after %0d cycles; expected every access to complete",
               scenario, max_cycles);
      $finish;
    end

  // Device context and first-stage tables:
  //   root[1] -> 0x10_1000, [0] -> 0x10_2000, [2] = 4 KiB leaf -> 0x100_6000
  task automatic set_tables();
    logic [63:0] dc = DDT_BASE + 64 * DEVICE_ID;
    mem[dc + 8]  = 64'd0;                                         // iohgatp: Bare
    mem[dc + 16] = 64'd1 << 12;                                   // ta: PSCID 1
    mem[dc + 24] = {4'd8, 16'd0, 44'(S1_ROOT >> 12)};             // fsc: Sv39
    mem[dc + 32] = 64'd0;                                         // msiptp: off
    mem[dc + 40] = 64'd0;
    mem[dc + 48] = 64'd0;
    mem[dc + 56] = 64'd0;
    mem[dc + 0]  = 64'd1;                                         // tc: V
    mem[S1_ROOT + 8 * 1]     = pte(44'h101, PTE_PTR);
    mem[64'h10_1000]         = pte(44'h102, PTE_PTR);
    mem[64'h10_2000 + 8 * 2] = pte(44'h1006, PTE_LEAF);
  endtask

  task automatic access(input bit write, input logic [63:0] data, output logic [1:0] resp,
                        output logic [63:0] rdata);
    if (write) begin dev_write(IOVA, data, resp); rdata = 'x; end
    else dev_read(IOVA, resp, rdata);
  endtask

  // One run from reset.  mode 0: no command, 1: command `gap` cycles before
  // the access, 2: access after the command queue drained.
  task automatic run_once(input bit write, input int mode, input int gap,
                          output string result, output bit ok);
    logic [1:0]  resp;
    logic [63:0] rdata, value;
    logic [63:0] marker = 64'h0600_0000_0000_0000 | 64'(gap);
    logic [63:0] wdata  = 64'h0a00_0000_0000_0000 | 64'(gap);

    rst_ni = 1'b0;
    dev_tr_req_i = '0; dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    prog_req_i = '0;
    repeat (6) @(posedge clk_i);
    @(negedge clk_i) rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);

    // Command and fault queues on, then the one-level device directory.
    reg_write(REG_CQB, {10'd0, 44'(CQ_BASE >> 12), 5'd0, 5'd5});
    reg_write(REG_FQB, {10'd0, 44'(FQ_BASE >> 12), 5'd0, 5'd4});
    reg_write(REG_CQCSR, 64'h1_0000_0001);
    repeat (32) @(posedge clk_i);
    reg_write(REG_DDTP, {10'd0, 44'(DDT_BASE >> 12), 6'd0, 4'd2});
    do reg_read(REG_DDTP, value); while (value[4]);

    // Warm the DDTC and the IOTLB.
    access(write, 64'h0b00_0000_0000_0000, resp, rdata);

    // IODIR.INVAL_DDT for all devices, then IOFENCE.C (PR, PW).
    mem[EXPECTED] = marker;
    down_aw.delete(); down_ar.delete();
    if (mode != 0) begin
      mem[CQ_BASE + 0]  = 64'h3;
      mem[CQ_BASE + 8]  = 64'h0;
      mem[CQ_BASE + 16] = 64'h3002;
      mem[CQ_BASE + 24] = 64'h0;
      reg_write(REG_CQHT, 64'd2 << 32);
      if (mode == 1) repeat (gap) @(posedge clk_i);
      else do reg_read(REG_CQHT, value); while (value[31:0] != 32'd2);
    end
    access(write, wdata, resp, rdata);
    repeat (64) @(posedge clk_i);

    if (write) begin
      result = $sformatf("%s, resp %0d, 0x%0h holds 0x%0h", addr_list(down_aw), resp, EXPECTED, mem[EXPECTED]);
      ok = down_aw.size() == 1 && down_aw[0] == EXPECTED && down_ar.size() == 0
           && resp == axi_pkg::RESP_OKAY && mem[EXPECTED] == wdata;
    end else begin
      result = $sformatf("%s, resp %0d, data 0x%0h", addr_list(down_ar), resp, rdata);
      ok = down_ar.size() == 1 && down_ar[0] == EXPECTED && down_aw.size() == 0
           && resp == axi_pkg::RESP_OKAY && rdata == marker;
    end
  endtask

  initial begin : main
    bit    write, ok, all_ok;
    int    mode;
    string result, bad;

    rst_ni = 1'b0; cycle = 0;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "read_inval_sweep";
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 200000;
    write = scenario.substr(0, 4) == "write";
    case (scenario)
      "read_inval_sweep", "write_inval_sweep": mode = 1;
      "read_no_inval", "write_no_inval":       mode = 0;
      "read_inval_done", "write_inval_done":   mode = 2;
      default: begin
        $display("FAIL %s: unknown scenario; expected {read,write}_{inval_sweep,no_inval,inval_done}", scenario);
        $finish;
      end
    endcase
    set_tables();

    if (mode == 1) begin
      all_ok = 1; bad = "";
      for (int gap = 0; gap < GAPS; gap++) begin
        run_once(write, mode, gap, result, ok);
        if (!ok) begin
          bad = {bad, (bad == "" ? "" : "; "), $sformatf("gap %0d: %s", gap, result)};
          all_ok = 0;
        end
      end
      if (all_ok)
        $display("PASS %s: gaps 0-%0d all forwarded to 0x%0h", scenario, GAPS - 1, EXPECTED);
      else
        $display("FAIL %s: %s; expected 0x%0h at every gap", scenario, bad, EXPECTED);
    end else begin
      run_once(write, mode, 0, result, ok);
      if (ok) $display("PASS %s: %s", scenario, result);
      else    $display("FAIL %s: %s; expected 0x%0h, resp 0", scenario, result, EXPECTED);
    end
    $finish;
  end
endmodule
