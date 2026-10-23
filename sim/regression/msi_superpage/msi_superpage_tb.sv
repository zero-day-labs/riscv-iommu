// SPDX-License-Identifier: Apache-2.0
//
// Directed testbench: MSI address recognition and interrupt-file selection
// for device writes translated through first-stage superpages.
//
// The full IOMMU (lint_checks top) is driven with one two-stage device
// context (Sv39 first stage, Sv39x4 second stage, flat MSI page table).  The
// device issues one 32-bit write; the testbench records the response, the
// downstream write address and data, the MSI page-table reads and the
// fault-queue records, and compares them with the expected values of the
// scenario selected by +scenario=<name>.
//
// Memory map (physical):
//   0x060000  device directory (1 level, extended contexts), device 1 at 0x060040
//   0x070000  fault queue
//   0x080000  second-stage root (16 KiB), 0x084000 / 0x085000 / 0x086000 lower levels
//   0x090000  MSI page table (16-byte entries)
//   0x200000  first-stage tables (guest physical = physical, 4 KiB second-stage leaves)
//   0x604000  ordinary memory behind guest page 4
//   0x2002000, 0x2005000  interrupt files
// Every second-stage leaf is 4 KiB.

`timescale 1ns/1ps

module msi_superpage_tb;
  import lint_wrapper::*;

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

  localparam int unsigned MAX_CYCLES = 20000;
  localparam logic [63:0] DDT     = 64'h06_0000;
  localparam logic [63:0] FQ      = 64'h07_0000;
  localparam logic [63:0] G_ROOT  = 64'h08_0000;
  localparam logic [63:0] G_L1    = 64'h08_4000;
  localparam logic [63:0] G_L0_A  = 64'h08_5000;   // guest 0x000000-0x1fffff
  localparam logic [63:0] G_L0_B  = 64'h08_6000;   // guest 0x200000-0x3fffff
  localparam logic [63:0] MSI_PT  = 64'h09_0000;
  localparam logic [63:0] S1_ROOT = 64'h20_0000;
  localparam logic [63:0] S1_L1_0 = 64'h20_1000;   // IOVA 0x00000000-0x3fffffff
  localparam logic [63:0] S1_L0_0 = 64'h20_2000;   // IOVA 0x00000000-0x001fffff
  localparam logic [63:0] S1_L1_2 = 64'h20_3000;   // IOVA 0x80000000-0xbfffffff
  localparam logic [63:0] S1_L0_2 = 64'h20_4000;   // IOVA 0x80800000-0x809fffff
  localparam logic [63:0] PLAIN   = 64'h60_4000;
  localparam logic [43:0] IFILE_A = 44'h2002;
  localparam logic [43:0] IFILE_B = 44'h2005;
  localparam logic [31:0] DATA    = 32'h0000_002a;

  localparam logic [9:0] PTE_PTR  = 10'h001;       // V
  localparam logic [9:0] PTE_LEAF = 10'h0d7;       // D A U W R V

  // -------------------------------------------------------------- memory
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

  function automatic void pte(input logic [63:0] table_base, input int idx,
                              input logic [63:0] ppn, input logic [9:0] flags);
    mem[table_base + 64'(8 * idx)] = (ppn << 10) | 64'(flags);
  endfunction

  // ------------------------------------------------------- observations
  int unsigned cycle;
  int msipt_reads;
  logic [63:0] msipt_first;
  int fq_records;
  logic [11:0] fq_cause;
  int comp_writes;
  int comp_wbeats;
  logic [63:0] comp_addr;
  logic [63:0] comp_data;
  logic [7:0]  comp_strb;

  // ------------------------------------------------ data-structure port
  typedef struct { logic [IdWidth-1:0] id; logic [63:0] addr; logic [7:0] len; } burst_t;
  burst_t ds_rq[$];
  burst_t ds_wq[$];
  logic [IdWidth-1:0] ds_bq[$];
  int ds_rbeat, ds_wbeat;
  logic ds_r_valid_q, ds_r_last_q, ds_b_valid_q;
  logic [IdWidth-1:0] ds_r_id_q, ds_b_id_q;
  logic [63:0] ds_r_data_q;

  always_comb begin
    ds_resp_i = '0;
    ds_resp_i.ar_ready = 1'b1;
    ds_resp_i.aw_ready = 1'b1;
    ds_resp_i.w_ready  = 1'b1;
    ds_resp_i.r_valid  = ds_r_valid_q;
    ds_resp_i.r.id     = ds_r_id_q;
    ds_resp_i.r.data   = ds_r_data_q;
    ds_resp_i.r.last   = ds_r_last_q;
    ds_resp_i.r.resp   = axi_pkg::RESP_OKAY;
    ds_resp_i.b_valid  = ds_b_valid_q;
    ds_resp_i.b.id     = ds_b_id_q;
    ds_resp_i.b.resp   = axi_pkg::RESP_OKAY;
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      ds_rq.delete(); ds_wq.delete(); ds_bq.delete();
      ds_rbeat = 0; ds_wbeat = 0;
      ds_r_valid_q <= 1'b0; ds_r_last_q <= 1'b0; ds_b_valid_q <= 1'b0;
      ds_r_id_q <= '0; ds_b_id_q <= '0; ds_r_data_q <= '0;
    end else begin
      if (ds_req_o.ar_valid) begin
        burst_t b;
        b.id = ds_req_o.ar.id; b.addr = ds_req_o.ar.addr; b.len = ds_req_o.ar.len;
        ds_rq.push_back(b);
        if (b.addr >= MSI_PT && b.addr < MSI_PT + 64'h1000) begin
          if (msipt_reads == 0) msipt_first = b.addr;
          msipt_reads++;
        end
      end
      if (ds_r_valid_q && ds_req_o.r_ready) begin
        if (ds_r_last_q) begin void'(ds_rq.pop_front()); ds_rbeat = 0; end
        else ds_rbeat++;
      end
      if (ds_req_o.aw_valid) begin
        burst_t b;
        b.id = ds_req_o.aw.id; b.addr = ds_req_o.aw.addr; b.len = ds_req_o.aw.len;
        ds_wq.push_back(b);
      end
      if (ds_req_o.w_valid && ds_wq.size() != 0) begin
        logic [63:0] a;
        a = ds_wq[0].addr + 64'(8 * ds_wbeat);
        wr(a, ds_req_o.w.data, ds_req_o.w.strb);
        if (a >= FQ && a < FQ + 64'h1000 && a[4:0] == 5'd0) begin
          if (fq_records == 0) fq_cause = ds_req_o.w.data[11:0];
          fq_records++;
        end
        if (ds_req_o.w.last) begin
          ds_bq.push_back(ds_wq[0].id); void'(ds_wq.pop_front()); ds_wbeat = 0;
        end else ds_wbeat++;
      end
      if (ds_b_valid_q && ds_req_o.b_ready) void'(ds_bq.pop_front());

      if (ds_rq.size() != 0) begin
        ds_r_valid_q <= 1'b1;
        ds_r_id_q    <= ds_rq[0].id;
        ds_r_data_q  <= rd(ds_rq[0].addr + 64'(8 * ds_rbeat));
        ds_r_last_q  <= (ds_rbeat == int'(ds_rq[0].len));
      end else begin
        ds_r_valid_q <= 1'b0; ds_r_last_q <= 1'b0;
      end
      ds_b_valid_q <= (ds_bq.size() != 0);
      ds_b_id_q    <= (ds_bq.size() != 0) ? ds_bq[0] : '0;
    end
  end

  // --------------------------------------------- downstream (memory) port
  logic [IdWidth-1:0] comp_awq[$];
  logic [IdWidth-1:0] comp_bq[$];
  logic comp_b_valid_q;
  logic [IdWidth-1:0] comp_b_id_q;

  always_comb begin
    dev_comp_resp_i = '0;
    dev_comp_resp_i.aw_ready = 1'b1;
    dev_comp_resp_i.w_ready  = 1'b1;
    dev_comp_resp_i.ar_ready = 1'b1;
    dev_comp_resp_i.b_valid  = comp_b_valid_q;
    dev_comp_resp_i.b.id     = comp_b_id_q;
    dev_comp_resp_i.b.resp   = axi_pkg::RESP_OKAY;
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      comp_awq.delete(); comp_bq.delete();
      comp_b_valid_q <= 1'b0; comp_b_id_q <= '0;
    end else begin
      if (dev_comp_req_o.aw_valid) begin
        if (comp_writes == 0) comp_addr = dev_comp_req_o.aw.addr;
        comp_writes++;
        comp_awq.push_back(dev_comp_req_o.aw.id);
      end
      if (dev_comp_req_o.w_valid) begin
        if (comp_wbeats == 0) begin comp_data = dev_comp_req_o.w.data; comp_strb = dev_comp_req_o.w.strb; end
        comp_wbeats++;
        if (dev_comp_req_o.w.last && comp_awq.size() != 0) begin
          comp_bq.push_back(comp_awq[0]); void'(comp_awq.pop_front());
        end
      end
      if (comp_b_valid_q && dev_comp_req_o.b_ready) void'(comp_bq.pop_front());
      comp_b_valid_q <= (comp_bq.size() != 0);
      comp_b_id_q    <= (comp_bq.size() != 0) ? comp_bq[0] : '0;
    end
  end

  // ------------------------------------------------------ programming port
  task automatic prog_write64(input logic [63:0] addr, input logic [63:0] data);
    bit aw_done, w_done;
    aw_done = 0; w_done = 0;
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

  task automatic prog_read64(input logic [63:0] addr, output logic [63:0] data);
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

  // ------------------------------------------------------------- scenario
  string scenario;
  bit known;
  bit s1_1g;            // map IOVA 0x4000 with a 1 GiB first-stage leaf
  bit s1_k4_ifile;      // map IOVA 0x80800000.. with 4 KiB first-stage leaves
  logic [51:0] pattern, mask;
  bit pte0_valid, pte1_valid;
  logic [43:0] pte0_ppn, pte1_ppn;
  logic [63:0] iova;
  // expectations
  int unsigned exp_resp;
  logic [63:0] exp_addr;            // 0: no downstream write
  logic [63:0] exp_msipt;           // 0: no MSI page-table read
  logic [11:0] exp_cause;           // 0: no fault record

  function automatic void configure();
    known = 1;
    s1_1g = 0; s1_k4_ifile = 0;
    pte0_valid = 0; pte1_valid = 0; pte0_ppn = IFILE_A; pte1_ppn = IFILE_B;
    case (scenario)
      // Guest page 4 is an interrupt file (pattern 4, mask 0); write IOVA 0x4000.
      "msi_page_4k":   begin pattern = 52'h4; mask = '0; pte0_valid = 1; iova = 64'h4000;
                             exp_resp = 0; exp_addr = 64'h2002000; exp_msipt = MSI_PT; exp_cause = 0; end
      "msi_page_1g":   begin pattern = 52'h4; mask = '0; pte0_valid = 1; iova = 64'h4000; s1_1g = 1;
                             exp_resp = 0; exp_addr = 64'h2002000; exp_msipt = MSI_PT; exp_cause = 0; end
      // Guest page 0 is the interrupt file (pattern 0), no valid MSI PTE; write
      // ordinary guest page 4 at IOVA 0x4000.
      "plain_page_4k": begin pattern = 52'h0; mask = '0; iova = 64'h4000;
                             exp_resp = 0; exp_addr = PLAIN; exp_msipt = 0; exp_cause = 0; end
      "plain_page_1g": begin pattern = 52'h0; mask = '0; iova = 64'h4000; s1_1g = 1;
                             exp_resp = 0; exp_addr = PLAIN; exp_msipt = 0; exp_cause = 0; end
      // Interrupt files at guest pages 0x30000 (file 0) and 0x30001 (file 1),
      // msi_addr_mask = 1.  IOVA 0x80800000 maps guest 0x30000000 with a 2 MiB
      // first-stage leaf.  Write offset 8 of interrupt file 1.
      "ifile1_2m":     begin pattern = 52'h30000; mask = 52'h1; pte1_valid = 1; iova = 64'h8080_1008;
                             exp_resp = 0; exp_addr = 64'h2005008; exp_msipt = MSI_PT + 64'h10; exp_cause = 0; end
      "ifile1_2m_pte0_valid":
                       begin pattern = 52'h30000; mask = 52'h1; pte0_valid = 1; pte1_valid = 1; iova = 64'h8080_1008;
                             exp_resp = 0; exp_addr = 64'h2005008; exp_msipt = MSI_PT + 64'h10; exp_cause = 0; end
      "ifile1_4k":     begin pattern = 52'h30000; mask = 52'h1; pte1_valid = 1; iova = 64'h8080_1008; s1_k4_ifile = 1;
                             exp_resp = 0; exp_addr = 64'h2005008; exp_msipt = MSI_PT + 64'h10; exp_cause = 0; end
      // msi_addr_mask = 0: one interrupt file at guest page 0x30000, MSI PTE 0
      // points at 0x2005000.  Write offset 8 of it through the 2 MiB leaf.
      "ifile0_mask0_2m":
                       begin pattern = 52'h30000; mask = '0; pte0_valid = 1; pte0_ppn = IFILE_B; iova = 64'h8080_0008;
                             exp_resp = 0; exp_addr = 64'h2005008; exp_msipt = MSI_PT; exp_cause = 0; end
      default: known = 0;
    endcase
  endfunction

  task automatic build_memory();
    // device context of device 1 (extended format, 64 bytes)
    mem[DDT + 64'h40] = 64'h1;                                              // tc: V
    mem[DDT + 64'h48] = {4'd8, 16'd1, 44'(G_ROOT >> 12)};                   // iohgatp: Sv39x4, GSCID 1
    mem[DDT + 64'h50] = 64'(20'd1) << 12;                                   // ta: PSCID 1
    mem[DDT + 64'h58] = {4'd8, 16'd0, 44'(S1_ROOT >> 12)};                  // fsc: Sv39, guest root
    mem[DDT + 64'h60] = {4'd1, 16'd0, 44'(MSI_PT >> 12)};                   // msiptp: flat
    mem[DDT + 64'h68] = 64'(mask);                                          // msi_addr_mask
    mem[DDT + 64'h70] = 64'(pattern);                                       // msi_addr_pattern
    mem[DDT + 64'h78] = 64'h0;

    // MSI page table: flat entries (V=1, M=3)
    if (pte0_valid) mem[MSI_PT + 64'h00] = (64'(pte0_ppn) << 10) | 64'h7;
    if (pte1_valid) mem[MSI_PT + 64'h10] = (64'(pte1_ppn) << 10) | 64'h7;

    // second stage, 4 KiB leaves only
    pte(G_ROOT, 0, G_L1 >> 12, PTE_PTR);
    pte(G_L1, 0, G_L0_A >> 12, PTE_PTR);
    pte(G_L1, 1, G_L0_B >> 12, PTE_PTR);
    pte(G_L0_A, 4, PLAIN >> 12, PTE_LEAF);                                  // guest page 4
    for (int i = 0; i < 5; i++) pte(G_L0_B, i, (S1_ROOT >> 12) + i, PTE_LEAF); // first-stage tables

    // first stage
    if (s1_1g) pte(S1_ROOT, 0, 64'h0, PTE_LEAF);                            // 1 GiB: IOVA 0 -> guest 0
    else begin
      pte(S1_ROOT, 0, S1_L1_0 >> 12, PTE_PTR);
      pte(S1_L1_0, 0, S1_L0_0 >> 12, PTE_PTR);
      pte(S1_L0_0, 4, 64'h4, PTE_LEAF);                                     // 4 KiB: IOVA 0x4000 -> guest 0x4000
    end
    pte(S1_ROOT, 2, S1_L1_2 >> 12, PTE_PTR);
    if (s1_k4_ifile) begin
      pte(S1_L1_2, 4, S1_L0_2 >> 12, PTE_PTR);
      pte(S1_L0_2, 0, 64'h30000, PTE_LEAF);
      pte(S1_L0_2, 1, 64'h30001, PTE_LEAF);
    end else
      pte(S1_L1_2, 4, 64'h30000, PTE_LEAF);                                 // 2 MiB: IOVA 0x80800000 -> guest 0x30000000
  endtask

  function automatic string hex_or_none(input logic [63:0] v, input bit present);
    return present ? $sformatf("0x%0h", v) : "none";
  endfunction

  function automatic string resp_name(input int unsigned r);
    case (r)
      0: return "OKAY";
      1: return "EXOKAY";
      2: return "SLVERR";
      default: return "DECERR";
    endcase
  endfunction

  // watchdog
  always @(posedge clk_i) begin
    cycle <= cycle + 1;
    if (cycle > MAX_CYCLES) begin
      $display("FAIL %s: timeout after %0d cycles, no write response; expected resp=%s", scenario,
               MAX_CYCLES, resp_name(exp_resp));
      $finish;
    end
  end

  initial begin
    logic [63:0] v;
    int unsigned resp;
    int unsigned t0, t_done;
    string got, want;

    cycle = 0;
    msipt_reads = 0; msipt_first = '0; fq_records = 0; fq_cause = '0;
    comp_writes = 0; comp_wbeats = 0; comp_addr = '0; comp_data = '0; comp_strb = '0;
    dev_tr_req_i = '0; prog_req_i = '0;
    dev_tr_req_i.b_ready = 1'b1; dev_tr_req_i.r_ready = 1'b1;
    if (!$value$plusargs("scenario=%s", scenario)) scenario = "";
    configure();
    if (!known) begin
      $display("FAIL %s: unknown scenario", scenario);
      $finish;
    end
    build_memory();

    repeat (5) @(posedge clk_i);
    @(negedge clk_i); rst_ni = 1'b1;
    repeat (3) @(posedge clk_i);

    // fault queue (16 entries), then the device directory (1 level)
    prog_write64(64'h28, ((FQ >> 12) << 10) | 64'd3);
    prog_write64(64'h48, 64'h1_0000_0000);                                  // fqcsr.fqen
    repeat (20) @(posedge clk_i);
    prog_write64(64'h10, ((DDT >> 12) << 10) | 64'd2);
    do prog_read64(64'h10, v); while (v[4]);

    // one 32-bit write from device 1
    t0 = cycle;
    @(negedge clk_i);
    dev_tr_req_i.aw = '0;
    dev_tr_req_i.aw.id = 4'd1;
    dev_tr_req_i.aw.addr = iova;
    dev_tr_req_i.aw.len = 8'd0;
    dev_tr_req_i.aw.size = 3'd2;
    dev_tr_req_i.aw.burst = axi_pkg::BURST_INCR;
    dev_tr_req_i.aw.stream_id = 24'd1;
    dev_tr_req_i.aw_valid = 1'b1;
    dev_tr_req_i.w = '0;
    dev_tr_req_i.w.data = {32'h0, DATA} << (8 * iova[2:0]);
    dev_tr_req_i.w.strb = 8'h0f << iova[2:0];
    dev_tr_req_i.w.last = 1'b1;
    dev_tr_req_i.w_valid = 1'b1;
    fork
      begin
        do @(posedge clk_i); while (!dev_tr_resp_o.aw_ready);
        @(negedge clk_i); dev_tr_req_i.aw_valid = 1'b0;
      end
      begin
        do @(posedge clk_i); while (!dev_tr_resp_o.w_ready);
        @(negedge clk_i); dev_tr_req_i.w_valid = 1'b0;
      end
    join
    while (!dev_tr_resp_o.b_valid) @(posedge clk_i);
    resp = dev_tr_resp_o.b.resp;
    t_done = cycle - t0;
    repeat (100) @(posedge clk_i);           // let a fault record reach memory

    got = $sformatf("resp=%s write=%s data=%s msipt_read=%s fault_cause=%s",
                    resp_name(resp),
                    (comp_writes == 0) ? "none" : (comp_writes == 1) ? $sformatf("0x%0h", comp_addr)
                                                : $sformatf("%0d writes, first 0x%0h", comp_writes, comp_addr),
                    (comp_writes == 0) ? "none" : $sformatf("0x%0h", (comp_data >> (8 * comp_addr[2:0])) & 64'hffff_ffff),
                    hex_or_none(msipt_first, msipt_reads != 0),
                    (fq_records == 0) ? "none" : $sformatf("%0d", fq_cause));
    want = $sformatf("resp=%s write=%s data=%s msipt_read=%s fault_cause=%s",
                     resp_name(exp_resp), hex_or_none(exp_addr, exp_addr != 0),
                     (exp_addr != 0) ? $sformatf("0x%0h", DATA) : "none",
                     hex_or_none(exp_msipt, exp_msipt != 0),
                     (exp_cause == 0) ? "none" : $sformatf("%0d", exp_cause));
    if (got == want) $display("PASS %s: %s (response after %0d cycles)", scenario, got, t_done);
    else             $display("FAIL %s: %s; expected %s", scenario, got, want);
    $finish;
  end
endmodule
