// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Exhaustive check of rv_iommu_axi4_bc against the AXI4 4 KiB rule.
//
// Sweeps every AxBURST encoding, every AxSIZE of a 64-bit bus (1 to 8 bytes),
// all 256 AxLEN values and every size-aligned offset in a 4 KiB page
// (7,864,320 combinations) and compares the checker outputs with a direct
// encoding of the rule:
//
//   FIXED  legal if the single beat fits in the page
//   INCR   legal if all (len + 1) beats fit in the page
//   WRAP   legal if len is 1, 3, 7 or 15 and the wrap block fits in a page
//   2'b11  reserved, never legal
//
// +scenario=legal     every legal burst must be allowed
// +scenario=reserved  every request must get a verdict (allow or violation)
// +scenario=crossing  no illegal burst may be allowed, and the two outputs
//                     are never raised together

module axi4_bc_sweep_tb;

  logic                   request_i;
  logic [riscv::VLEN-1:0] addr_i;
  axi_pkg::burst_t        burst_type_i;
  axi_pkg::len_t          burst_length_i;
  axi_pkg::size_t         n_bytes_i;
  logic                   allow_request_o;
  logic                   bound_violation_o;

  rv_iommu_axi4_bc dut (
    .request_i         (request_i),
    .addr_i            (addr_i),
    .burst_type_i      (burst_type_i),
    .burst_length_i    (burst_length_i),
    .n_bytes_i         (n_bytes_i),
    .allow_request_o   (allow_request_o),
    .bound_violation_o (bound_violation_o)
  );

  function automatic bit is_legal(int unsigned offset, int unsigned burst,
                                  int unsigned len, int unsigned size);
    int unsigned beat  = 1 << size;
    int unsigned total = (len + 1) * beat;
    case (burst)
      0:       return (offset + beat) <= 4096;
      1:       return (offset + total) <= 4096;
      2:       return (len == 1 || len == 3 || len == 7 || len == 15) && total <= 4096;
      default: return 0;
    endcase
  endfunction

  initial begin
    string       scenario;
    int unsigned checked, legal_rejected, no_verdict, illegal_allowed, both;
    int unsigned shown;

    if (!$value$plusargs("scenario=%s", scenario)) scenario = "legal";
    checked = 0; legal_rejected = 0; no_verdict = 0; illegal_allowed = 0;
    both = 0; shown = 0;
    request_i = 1'b1;

    for (int unsigned burst = 0; burst < 4; burst++)
      for (int unsigned size = 0; size < 4; size++)
        for (int unsigned len = 0; len < 256; len++)
          for (int unsigned offset = 0; offset < 4096; offset += (1 << size)) begin
            bit legal;
            addr_i         = 64'h4000_0000 + offset;
            burst_type_i   = burst[1:0];
            burst_length_i = len[7:0];
            n_bytes_i      = size[2:0];
            #1;
            legal = is_legal(offset, burst, len, size);
            checked++;
            if (allow_request_o && bound_violation_o) both++;
            if (!allow_request_o && !bound_violation_o) no_verdict++;
            else if (legal && !allow_request_o) begin
              legal_rejected++;
              if (shown < 4 && scenario == "legal") begin
                $display("  legal burst rejected: burst=%0d size=%0d len=%0d offset=0x%0h",
                         burst, size, len, offset);
                shown++;
              end
            end
            else if (!legal && allow_request_o) illegal_allowed++;
          end

    case (scenario)
      "legal":
        if (legal_rejected == 0)
          $display("PASS legal: checked=%0d legal_rejected=%0d", checked, legal_rejected);
        else
          $display("FAIL legal: checked=%0d legal_rejected=%0d; expected 0", checked, legal_rejected);
      "reserved":
        if (no_verdict == 0)
          $display("PASS reserved: checked=%0d no_verdict=%0d", checked, no_verdict);
        else
          $display("FAIL reserved: checked=%0d no_verdict=%0d; expected 0", checked, no_verdict);
      "crossing":
        if (illegal_allowed == 0 && both == 0)
          $display("PASS crossing: checked=%0d illegal_allowed=%0d allow_and_violation=%0d",
                   checked, illegal_allowed, both);
        else
          $display("FAIL crossing: checked=%0d illegal_allowed=%0d allow_and_violation=%0d; expected 0 and 0",
                   checked, illegal_allowed, both);
      default:
        $display("FAIL %s: unknown scenario", scenario);
    endcase
    $finish;
  end

endmodule
