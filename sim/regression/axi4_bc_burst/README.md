# AXI4 burst checks regression

Checks the AXI4 boundary checker (`rtl/ext_interfaces/rv_iommu_axi4_bc.sv`):
bursts that end exactly on a 4 KiB boundary are legal and must be allowed, and
the reserved `AxBURST = 2'b11` encoding must be rejected so the request is
terminated instead of leaving the request FSM waiting.

## Files

- `run.py`: builds both models with Verilator and runs every scenario
- `axi4_bc_sweep_tb.sv`: `rv_iommu_axi4_bc` alone, exhaustive sweep
- `axi4_bc_burst_tb.sv`: full IOMMU through `lint_checks.sv`, directed device writes
- `include/common_cells/assertions.svh`: forwards to `include/assertions.svh`
  (`rv_iommu_regmap.sv` includes the `common_cells/` path, which the repository
  does not ship)

## Run

From the repository root (Verilator only; tested with 5.022 and 5.052):

    python3 sim/regression/axi4_bc_burst/run.py
    python3 sim/regression/axi4_bc_burst/run.py -s reserved_burst,incr_single
    VERILATOR=/path/to/verilator python3 sim/regression/axi4_bc_burst/run.py

Each scenario prints a `PASS` or `FAIL` line with the observed values. The exit
status is nonzero if any scenario fails. Build and run take about 15-20 s.

## Scenarios

The sweep covers every `AxBURST`, every `AxSIZE` of the 64-bit bus, all 256
`AxLEN` values and every aligned page offset (7,864,320 inputs) and compares
the checker with the AXI4 4 KiB rule.

| Scenario | Kind | Checks |
| --- | --- | --- |
| `legal` | bug | no legal burst is rejected |
| `reserved` | bug | every request gets allow or violation |
| `crossing` | control | no illegal burst is allowed |
| `reserved_burst` | bug | an `AxBURST = 2'b11` write gets SLVERR; later reads from the same and from another device are accepted |
| `page_end_incr` | bug | INCR 8 x 8 bytes at page offset `0xfc0` is forwarded with 8 beats and gets OKAY |
| `incr_single`, `fixed_single` | control | single-beat writes are forwarded |
| `wrap_bad_len` | control | WRAP with `AxLEN = 0` gets SLVERR; later reads are accepted |
| `crossing_incr` | control | INCR 8 x 8 bytes at offset `0xfc8` (crosses the boundary) gets SLVERR |

## Expected results

With the fix all 9 scenarios pass. On the code before the fix the four `bug`
scenarios fail and the controls pass:

    FAIL legal: checked=7864320 legal_rejected=2168; expected 0
    FAIL reserved: checked=7864320 no_verdict=1966080; expected 0
    FAIL reserved_burst: burst=3 ... b_received=0 ... read_dev1=0 read_dev2=0 ...
    FAIL page_end_incr: burst=1 len=7 addr=0x4fc0 b_received=1 resp=2 forwarded_aw=0 ...
