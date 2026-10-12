// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// -----------------------------------------------------------------------------
// Bounded, self-checking Verilator 4.x (--cc --exe --build, explicit C++
// clock driver) testbench for the production
// cva6/corev_apu/riscv-iommu/rtl/ext_interfaces/rv_iommu_ds_if.sv.
//
// Scope: EXTERNAL behaviour of the DS write path only (AW / W / B for the five
// write-capable producers CQ, FQ, MRIF handler, MSI IG, PQ).  The DUT is the
// unmodified production wrapper (or a saved baseline copy supplied through the
// runner's --ds-source option).  No RTL behaviour is re-implemented here.
//
// Scenario 1 (+scenario=1, default): FQ only.
//   One FQ burst, AWID = 1, AWLEN = 3 => exactly 4 W beats with WLAST.  The FQ
//   AW is held asserted until accepted, then the 4 W beats are driven.  The DS
//   sink accepts AW and W independently and answers with B carrying the same
//   ID.  This is the minimal reproducer of the reported symptom:
//   "accepted FQ AW but never any FQ W data" (hang).
//
// Scenario 2 (+scenario=2): all five writers active at once.
//   Distinct sentinel data, burst lengths 1..4, independent AW/W sub-FSMs,
//   DS AW/W backpressure and B routing, several bursts in flight concurrently.
//
// Scenario 3 (+scenario=3): CQ W offered before its AW.
//   One CQ burst (the reset/stale selector is zero), AW withheld while W is
//   already valid and held; proves no producer W is consumed while the
//   accepted-AW owner queue is empty.
//
// Scenario 4 (+scenario=4): >8 FQ AWs offered with W delayed.
//   Twelve 1-beat FQ bursts; DS AW sink ready, external WREADY held low until
//   a fixed cycle.  Proves producer-side AW backpressure prevents lost
//   ownership and that all writes complete after W release.
//
// Scoreboard policy
// -----------------
//   * Expected W bursts are derived from the OBSERVED DS output AW handshakes
//     (AWID, AWLEN and a burst index encoded in AWADDR).  The DUT's internal
//     selection arithmetic is never mirrored.
//   * DS WREADY is held low until at least one DS AW handshake has been
//     observed.  This is the "hold sink WREADY until it has AW" option called
//     out in the task; it keeps the scoreboard online while the DUT may still
//     legitimately present W before AW (AW and W live in independent spill
//     registers).  No W beat is ever accepted without an outstanding expected
//     AW entry.
//   * Except in the early-W scenario, each producer drives W after its AW for the same
//     burst has been accepted (this is the "matching accepted internal AW
//     ownership" property, and it also keeps the stimulus inside the wrapper's
//     supported contract: the wrapper routes W by accepted-AW order).  A
//     producer-side guard asserts this property explicitly.
//
// Exit status: $fatal(1) on any mismatch or on watchdog timeout; plain $finish
// (exit 0) only when every burst has been AW+W+B acknowledged and the error
// counter is zero.
// -----------------------------------------------------------------------------

`include "axi/typedef.svh"

module iommu_ds_if_write_tb (
  input logic clk_i,
  input logic rst_n
);

  // ---------------------------------------------------------------------------
  // AXI types - one consistent vendor set (axi/typedef.svh + axi_pkg).
  // ---------------------------------------------------------------------------
  localparam int unsigned AddrWidth = 64;
  localparam int unsigned DataWidth = 64;
  localparam int unsigned IdWidth   = 4;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam int unsigned UserWidth = 1;

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdWidth-1:0]   id_t;
  typedef logic [StrbWidth-1:0] strb_t;
  typedef logic [UserWidth-1:0] user_t;

  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)

  localparam int unsigned NumProd   = 5;
  localparam int unsigned QDepth    = 32;
  localparam int unsigned MaxCycles = 20000;
  localparam int unsigned W_RELEASE_CYCLE = 100;

  // Producer index == AWID used by that producer.
  localparam int unsigned P_CQ   = 0;
  localparam int unsigned P_FQ   = 1;
  localparam int unsigned P_MRIF = 2;
  localparam int unsigned P_MSI  = 3;
  localparam int unsigned P_PQ   = 4;

  // ---------------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // Clock / reset are provided by the C++ driver.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Scenario selection and derived burst plan
  // ---------------------------------------------------------------------------
  int scenario;
  int total_bursts;
  int total_beats;
  int unsigned tb_cycle;

  function automatic int nburst_of(input int p);
    if (scenario == 1) begin
      return (p == int'(P_FQ)) ? 1 : 0;
    end
    if (scenario == 3) begin
      return (p == int'(P_CQ)) ? 1 : 0;
    end
    if (scenario == 4) begin
      return (p == int'(P_FQ)) ? 12 : 0;
    end
    case (p)
      int'(P_CQ)  : return 2;
      int'(P_FQ)  : return 2;
      int'(P_MRIF): return 1;
      int'(P_MSI) : return 2;
      int'(P_PQ)  : return 2;
      default     : return 0;
    endcase
  endfunction

  function automatic int beats_of(input int p, input int j);
    if (scenario == 1) begin
      return 4;                       // FQ burst, AWLEN = 3
    end
    if (scenario == 3) begin
      return 4;
    end
    if (scenario == 4) begin
      return 1;
    end
    case (p)
      int'(P_CQ)  : return (j == 0) ? 1 : 3;
      int'(P_FQ)  : return (j == 0) ? 2 : 4;
      int'(P_MRIF): return 1;
      int'(P_MSI) : return (j == 0) ? 3 : 2;
      int'(P_PQ)  : return (j == 0) ? 4 : 1;
      default     : return 1;
    endcase
  endfunction

  // AWADDR encodes marker | id | burst index, so the scoreboard can rebuild the
  // expected W data from the OBSERVED output AW (not from stimulus bookkeeping).
  function automatic logic [63:0] make_addr(input int p, input int j);
    return {32'h0, 8'h5A, 4'h0, 4'(p), 8'(j), 8'hA0};
  endfunction

  function automatic logic [63:0] exp_data(input int p, input int j, input int beat);
    return 64'hA500_0000_0000_0000 | (64'(p) << 32) | (64'(j) << 16) | 64'(beat);
  endfunction

  initial begin
    scenario = 1;
    if (!$value$plusargs("scenario=%d", scenario)) begin
      scenario = 1;
    end
    total_bursts = 0;
    total_beats  = 0;
    for (int p = 0; p < NumProd; p++) begin
      for (int j = 0; j < nburst_of(p); j++) begin
        total_bursts = total_bursts + 1;
        total_beats  = total_beats + beats_of(p, j);
      end
    end
    $display("[%0t] iommu_ds_if_write_tb: scenario=%0d total_bursts=%0d total_beats=%0d",
             $time, scenario, total_bursts, total_beats);
  end

  // ---------------------------------------------------------------------------
  // Producer-side signals (index == AWID)
  // ---------------------------------------------------------------------------
  axi_aw_chan_t p_aw       [NumProd];
  logic         p_aw_valid [NumProd];
  axi_w_chan_t  p_w        [NumProd];
  logic         p_w_valid  [NumProd];

  axi_req_t     prod_req   [NumProd];
  axi_resp_t    prod_resp  [NumProd];

  // Read-only producers (DDTW/PDTW/PTW/MSIPTW) tied off.  They never drive
  // AW/W and never receive a B response.
  axi_req_t     ro_req     [4];
  axi_resp_t    ro_resp    [4];

  always_comb begin
    for (int i = 0; i < NumProd; i++) begin
      prod_req[i]          = '0;
      prod_req[i].aw       = p_aw[i];
      prod_req[i].aw_valid = p_aw_valid[i];
      prod_req[i].w        = p_w[i];
      prod_req[i].w_valid  = p_w_valid[i];
      prod_req[i].b_ready  = 1'b1;
    end
  end

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      ro_req[i] = '0;
    end
  end

  // ---------------------------------------------------------------------------
  // DUT: the unmodified production wrapper (or --ds-source baseline copy).
  // ---------------------------------------------------------------------------
  axi_req_t  ds_req;
  axi_resp_t ds_resp;

  rv_iommu_ds_if #(
    .aw_chan_t  (axi_aw_chan_t),
    .w_chan_t   (axi_w_chan_t),
    .b_chan_t   (axi_b_chan_t),
    .ar_chan_t  (axi_ar_chan_t),
    .r_chan_t   (axi_r_chan_t),
    .axi_req_t  (axi_req_t),
    .axi_resp_t (axi_resp_t)
  ) i_dut (
    .clk_i               (clk_i),
    .rst_ni              (rst_n),

    .ds_resp_i           (ds_resp),
    .ds_req_o            (ds_req),

    .ddtw_req_i          (ro_req[0]),
    .ddtw_resp_o         (ro_resp[0]),

    .pdtw_req_i          (ro_req[1]),
    .pdtw_resp_o         (ro_resp[1]),

    .ptw_req_i           (ro_req[2]),
    .ptw_resp_o          (ro_resp[2]),

    .msiptw_req_i        (ro_req[3]),
    .msiptw_resp_o       (ro_resp[3]),

    .mrif_handler_req_i  (prod_req[P_MRIF]),
    .mrif_handler_resp_o (prod_resp[P_MRIF]),

    .cq_req_i            (prod_req[P_CQ]),
    .cq_resp_o           (prod_resp[P_CQ]),

    .fq_req_i            (prod_req[P_FQ]),
    .fq_resp_o           (prod_resp[P_FQ]),

    .pq_req_i            (prod_req[P_PQ]),
    .pq_resp_o           (prod_resp[P_PQ]),

    .msi_ig_req_i        (prod_req[P_MSI]),
    .msi_ig_resp_o       (prod_resp[P_MSI])
  );

  // ---------------------------------------------------------------------------
  // Per-producer AW / W drivers.
  //
  // AW sub-FSM: issues AW(n), holds VALID + payload until AWREADY, then AW(n+1).
  // W  sub-FSM: issues the beats of W(n), holds VALID + payload until WREADY,
  //             then W(n+1).  W(n) is only offered once the AW(n) of the same
  //             producer has been accepted; this keeps every offered W burst
  //             backed by an entry already present in the DUT's accepted-AW
  //             order (so the test never relies on W with no owner present,
  //             which the wrapper does not route).
  // ---------------------------------------------------------------------------
  for (genvar p = 0; p < NumProd; p++) begin : g_prod
    logic [7:0] aw_done;    // AWs accepted by this producer
    logic       aw_busy;
    logic [7:0] w_done;     // W bursts completed by this producer
    logic [7:0] w_beat;
    logic       w_busy;

    always_ff @(posedge clk_i) begin
      axi_aw_chan_t aw_tmp;
      axi_w_chan_t  w_tmp;

      if (!rst_n) begin
        p_aw_valid[p] <= 1'b0;
        p_w_valid[p]  <= 1'b0;
        aw_done <= 8'd0;
        aw_busy <= 1'b0;
        w_done  <= 8'd0;
        w_beat  <= 8'd0;
        w_busy  <= 1'b0;
      end else begin
        // ---------------- AW sub-FSM ----------------
        if (!aw_busy) begin
          if ((int'(aw_done) < nburst_of(int'(p))) &&
              ((scenario != 3) || (tb_cycle >= 32'd20))) begin
            aw_tmp        = '0;
            aw_tmp.id     = id_t'(p);
            aw_tmp.addr   = make_addr(int'(p), int'(aw_done));
            aw_tmp.len    = 8'(beats_of(int'(p), int'(aw_done)) - 1);
            aw_tmp.size   = 3'd3;
            aw_tmp.burst  = axi_pkg::BURST_INCR;
            p_aw[p]       <= aw_tmp;
            p_aw_valid[p] <= 1'b1;
            aw_busy       <= 1'b1;
          end
        end else begin
          if (prod_resp[p].aw_ready) begin
            p_aw_valid[p] <= 1'b0;
            aw_busy       <= 1'b0;
            aw_done       <= aw_done + 8'd1;
          end
        end

        // ---------------- W sub-FSM ----------------
        if (!w_busy) begin
          if ((int'(w_done) < nburst_of(int'(p))) &&
              ((scenario == 3) || (int'(aw_done) > int'(w_done)))) begin
            w_tmp        = '0;
            w_tmp.data   = exp_data(int'(p), int'(w_done), 0);
            w_tmp.strb   = {StrbWidth{1'b1}};
            w_tmp.last   = (beats_of(int'(p), int'(w_done)) == 1);
            p_w[p]       <= w_tmp;
            p_w_valid[p] <= 1'b1;
            w_beat       <= 8'd0;
            w_busy       <= 1'b1;
          end
        end else begin
          if (prod_resp[p].w_ready) begin
            if (int'(w_beat) == (beats_of(int'(p), int'(w_done)) - 1)) begin
              p_w_valid[p] <= 1'b0;
              w_busy       <= 1'b0;
              w_done       <= w_done + 8'd1;
              w_beat       <= 8'd0;
            end else begin
              w_tmp      = '0;
              w_tmp.data = exp_data(int'(p), int'(w_done), int'(w_beat) + 1);
              w_tmp.strb = {StrbWidth{1'b1}};
              w_tmp.last = ((int'(w_beat) + 1) == (beats_of(int'(p), int'(w_done)) - 1));
              p_w[p]     <= w_tmp;
              w_beat     <= w_beat + 8'd1;
            end
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // DS sink + scoreboard.  One clocked process owns all sink state; DUT
  // outputs are sampled with pre-edge values, sink ready/b_valid are registered.
  // ---------------------------------------------------------------------------
  logic        aw_ready_q = 1'b0;
  logic        w_ready_q  = 1'b0;
  logic        b_valid_q  = 1'b0;
  axi_b_chan_t b_data_q   = '0;

  always_comb begin
    ds_resp          = '0;
    ds_resp.aw_ready = aw_ready_q;
    ds_resp.w_ready  = w_ready_q;
    ds_resp.b_valid  = b_valid_q;
    ds_resp.b        = b_data_q;
  end

  logic [IdWidth-1:0] awq_id    [QDepth];
  logic [7:0]         awq_bidx  [QDepth];
  logic [7:0]         awq_beats [QDepth];
  logic [7:0]         awq_beat  [QDepth];
  integer             awq_head, awq_tail;

  logic [IdWidth-1:0] bq_id     [QDepth];
  integer             bq_head, bq_tail;

  integer errors;
  integer aw_hs;
  integer w_hs;
  integer w_bursts;
  integer b_sink_hs;

  integer aw_acc   [NumProd];   // producer-side AW handshakes
  integer w_burst  [NumProd];   // producer-side completed W bursts
  integer w_beat_c [NumProd];   // beat within current producer W burst
  integer b_acc    [NumProd];   // producer-side B handshakes

  logic [7:0] lfsr;
  integer     done_cnt;

  always @(posedge clk_i) begin
    logic [63:0] exp;
    integer      occ;
    integer      g;
    integer      sum_b;

    if (!rst_n) begin
      aw_ready_q <= 1'b0;
      w_ready_q  <= 1'b0;
      b_valid_q  <= 1'b0;
      b_data_q   <= '0;
      awq_head = 0; awq_tail = 0;
      bq_head  = 0; bq_tail  = 0;
      errors = 0; aw_hs = 0; w_hs = 0; w_bursts = 0; b_sink_hs = 0;
      lfsr = 8'h5A;
      done_cnt = 0;
      for (g = 0; g < NumProd; g = g + 1) begin
        aw_acc[g] = 0; w_burst[g] = 0; w_beat_c[g] = 0; b_acc[g] = 0;
      end
    end else begin
      lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

      // -------- producer-side ownership / B-routing guard --------
      for (g = 0; g < NumProd; g = g + 1) begin
        if (p_aw_valid[g] && prod_resp[g].aw_ready) begin
          aw_acc[g] = aw_acc[g] + 1;
        end
        if (p_w_valid[g] && prod_resp[g].w_ready) begin
          if (w_beat_c[g] == 0) begin
            if (aw_acc[g] <= w_burst[g]) begin
              errors = errors + 1;
              $display("[%0t] ERROR: producer %0d W burst %0d handshake with no matching accepted AW (aw_acc=%0d)",
                       $time, g, w_burst[g], aw_acc[g]);
            end
          end
          if (w_beat_c[g] == (beats_of(g, (w_burst[g] < nburst_of(g)) ? w_burst[g] : 0) - 1)) begin
            w_burst[g] = w_burst[g] + 1;
            w_beat_c[g] = 0;
          end else begin
            w_beat_c[g] = w_beat_c[g] + 1;
          end
        end
        if (prod_resp[g].b_valid) begin
          if (prod_resp[g].b.id !== id_t'(g)) begin
            errors = errors + 1;
            $display("[%0t] ERROR: producer %0d received B with id %0d (mis-routed B)",
                     $time, g, prod_resp[g].b.id);
          end
          b_acc[g] = b_acc[g] + 1;
        end
      end

      // -------- DS output AW handshake --------
      if (aw_ready_q && ds_req.aw_valid) begin
        if (ds_req.aw.id[IdWidth-1:0] !== ds_req.aw.addr[19:16]) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS AW id=%0d but AWADDR encodes id=%0d",
                   $time, ds_req.aw.id, ds_req.aw.addr[19:16]);
        end
        if ((ds_req.aw.addr[31:24] !== 8'h5A) || (ds_req.aw.addr[7:0] !== 8'hA0)) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS AW marker mismatch AWADDR=%h", $time, ds_req.aw.addr);
        end
        if (ds_req.aw.len !== 8'(beats_of(ds_req.aw.id[IdWidth-1:0], ds_req.aw.addr[15:8]) - 1)) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS AW len=%0d unexpected for id=%0d burst=%0d",
                   $time, ds_req.aw.len, ds_req.aw.id, ds_req.aw.addr[15:8]);
        end
        awq_id[awq_tail]    = ds_req.aw.id[IdWidth-1:0];
        awq_bidx[awq_tail]  = ds_req.aw.addr[15:8];
        awq_beats[awq_tail] = ds_req.aw.len + 8'd1;
        awq_beat[awq_tail]  = 8'd0;
        awq_tail = (awq_tail + 1) % QDepth;
        aw_hs = aw_hs + 1;
        $display("[%0t] DS AW accepted: id=%0d burst=%0d len=%0d addr=%h",
                 $time, ds_req.aw.id, ds_req.aw.addr[15:8], ds_req.aw.len, ds_req.aw.addr);
      end

      // -------- DS output W handshake --------
      if (w_ready_q && ds_req.w_valid) begin
        if (awq_head == awq_tail) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS W beat accepted with no outstanding AW expected", $time);
        end else begin
          exp = exp_data(awq_id[awq_head], awq_bidx[awq_head], awq_beat[awq_head]);
          if (ds_req.w.data !== exp) begin
            errors = errors + 1;
            $display("[%0t] ERROR: DS W data got=%h exp=%h (id=%0d burst=%0d beat=%0d of %0d)",
                     $time, ds_req.w.data, exp, awq_id[awq_head], awq_bidx[awq_head],
                     awq_beat[awq_head], awq_beats[awq_head]);
          end
          if (ds_req.w.strb !== {StrbWidth{1'b1}}) begin
            errors = errors + 1;
            $display("[%0t] ERROR: DS W strb=%h expected all-ones (id=%0d burst=%0d beat=%0d)",
                     $time, ds_req.w.strb, awq_id[awq_head], awq_bidx[awq_head],
                     awq_beat[awq_head]);
          end
          if (ds_req.w.last !== (awq_beat[awq_head] == (awq_beats[awq_head] - 8'd1))) begin
            errors = errors + 1;
            $display("[%0t] ERROR: DS W last=%0d unexpected (id=%0d burst=%0d beat=%0d of %0d)",
                     $time, ds_req.w.last, awq_id[awq_head], awq_bidx[awq_head],
                     awq_beat[awq_head], awq_beats[awq_head]);
          end
          if (awq_beat[awq_head] == (awq_beats[awq_head] - 8'd1)) begin
            bq_id[bq_tail] = awq_id[awq_head];
            bq_tail = (bq_tail + 1) % QDepth;
            awq_head = (awq_head + 1) % QDepth;
            w_bursts = w_bursts + 1;
          end else begin
            awq_beat[awq_head] = awq_beat[awq_head] + 8'd1;
          end
          w_hs = w_hs + 1;
        end
      end

      // -------- DS B handshake --------
      if (b_valid_q && ds_req.b_ready) begin
        bq_head = (bq_head + 1) % QDepth;
        b_sink_hs = b_sink_hs + 1;
      end

      // -------- sink output registers --------
      occ = (awq_tail + QDepth - awq_head) % QDepth;

      // AW backpressure.  Keep the number of accepted-but-uncompleted AWs low
      // enough that the DUT's internal 8-entry accepted-AW order FIFO can never
      // overflow (output occupancy <= 4; two further AWs may still sit in the
      // DUT AW spill register).
      // Scenario 4 keeps the external AW sink ready so the DUT's own
      // accepted-AW ownership FIFO is the only backpressure point.  Other
      // scenarios keep the output occupancy low.
      if (scenario == 4) begin
        aw_ready_q <= 1'b1;
      end else begin
        aw_ready_q <= (occ < 4) && lfsr[2];
      end

      // WREADY only once at least one DS AW handshake has been observed
      // ("hold sink WREADY until it has AW").  Scenario 4 additionally holds
      // WREADY low until a fixed cycle, never until >8 AW handshakes.
      if (scenario == 4) begin
        w_ready_q <= (tb_cycle >= W_RELEASE_CYCLE) && (occ > 0);
      end else begin
        w_ready_q <= (occ > 0) && lfsr[3];
      end

      if (bq_head != bq_tail) begin
        b_valid_q     <= 1'b1;
        b_data_q.id   <= bq_id[bq_head];
        b_data_q.resp <= axi_pkg::RESP_OKAY;
        b_data_q.user <= '0;
      end else begin
        b_valid_q     <= 1'b0;
      end

      // -------- completion --------
      sum_b = 0;
      for (g = 0; g < NumProd; g = g + 1) begin
        sum_b = sum_b + b_acc[g];
      end

      if ((aw_hs == total_bursts) && (w_hs == total_beats) &&
          (w_bursts == total_bursts) && (b_sink_hs == total_bursts) &&
          (sum_b == total_bursts)) begin
        done_cnt = done_cnt + 1;
      end else begin
        done_cnt = 0;
      end

      if (done_cnt == 4) begin
        if (aw_hs != total_bursts) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS AW count=%0d != total_bursts=%0d",
                   $time, aw_hs, total_bursts);
        end
        if (w_hs != total_beats) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS W beat count=%0d != total_beats=%0d",
                   $time, w_hs, total_beats);
        end
        if (w_bursts != total_bursts) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS W burst count=%0d != total_bursts=%0d",
                   $time, w_bursts, total_bursts);
        end
        if (b_sink_hs != total_bursts) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS B sink count=%0d != total_bursts=%0d",
                   $time, b_sink_hs, total_bursts);
        end
        if (sum_b != total_bursts) begin
          errors = errors + 1;
          $display("[%0t] ERROR: producer-side B count=%0d != total_bursts=%0d",
                   $time, sum_b, total_bursts);
        end
        for (g = 0; g < NumProd; g = g + 1) begin
          if (aw_acc[g] != nburst_of(g)) begin
            errors = errors + 1;
            $display("[%0t] ERROR: producer %0d AW count=%0d != expected=%0d",
                     $time, g, aw_acc[g], nburst_of(g));
          end
          if (w_burst[g] != nburst_of(g)) begin
            errors = errors + 1;
            $display("[%0t] ERROR: producer %0d W burst count=%0d != expected=%0d",
                     $time, g, w_burst[g], nburst_of(g));
          end
          if (b_acc[g] != nburst_of(g)) begin
            errors = errors + 1;
            $display("[%0t] ERROR: producer %0d B count=%0d != expected=%0d",
                     $time, g, b_acc[g], nburst_of(g));
          end
        end
        if (awq_head != awq_tail) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS AW queue not drained: head=%0d tail=%0d",
                   $time, awq_head, awq_tail);
        end
        if (bq_head != bq_tail) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS B response queue not drained: head=%0d tail=%0d",
                   $time, bq_head, bq_tail);
        end
        if (b_valid_q) begin
          errors = errors + 1;
          $display("[%0t] ERROR: DS B valid still asserted at completion", $time);
        end
        if (errors == 0) begin
          $display("[%0t] SCENARIO %0d PASS: bursts=%0d aw_hs=%0d w_beats=%0d w_bursts=%0d b_sink=%0d b_prod=%0d",
                   $time, scenario, total_bursts, aw_hs, w_hs, w_bursts, b_sink_hs, sum_b);
          $finish;
        end else begin
          $display("[%0t] SCENARIO %0d FAIL: errors=%0d aw_hs=%0d w_beats=%0d w_bursts=%0d b_sink=%0d total_bursts=%0d",
                   $time, scenario, errors, aw_hs, w_hs, w_bursts, b_sink_hs, total_bursts);
          $fatal(1);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Synchronous bounded cycle counter / watchdog.  The C++ driver also has a
  // bounded loop and returns nonzero if $finish never appears.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_n) begin
      tb_cycle <= 0;
    end else begin
      tb_cycle <= tb_cycle + 1;
      if (tb_cycle >= MaxCycles) begin
        $display("[%0t] SCENARIO %0d FAIL (watchdog): aw_hs=%0d w_beats=%0d w_bursts=%0d b_sink=%0d errors=%0d total_bursts=%0d",
                 $time, scenario, aw_hs, w_hs, w_bursts, b_sink_hs, errors, total_bursts);
        $fatal(1);
      end
    end
  end

endmodule
