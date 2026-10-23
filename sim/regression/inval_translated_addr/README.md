# Translated address under a concurrent invalidation

Checks that a translated device request is forwarded to the address that was
translated, even when an `IODIR.INVAL_DDT` executes in the cycle after the
translation completes. `rtl/riscv_iommu.sv` forwards the request one cycle
after `trans_valid`; the forwarded `AxADDR` must be the address captured at
`trans_valid`, not the live translation output.

## Files

- `run.py`: builds the model with Verilator and runs every scenario
- `inval_translated_addr_tb.sv`: full IOMMU through `lint_checks.sv`, a memory
  model on the data-structure and downstream ports, directed device accesses
  and command-queue submissions
- `include/common_cells/assertions.svh`: forwards to `include/assertions.svh`
  (`rv_iommu_regmap.sv` includes the `common_cells/` path, which the repository
  does not ship)

## Run

From the repository root (Verilator only; tested with 5.022 and 5.052):

    python3 sim/regression/inval_translated_addr/run.py
    python3 sim/regression/inval_translated_addr/run.py -s read_inval_sweep
    VERILATOR=/path/to/verilator python3 sim/regression/inval_translated_addr/run.py

Each scenario prints a `PASS` or `FAIL` line with the observed values. The exit
status is nonzero if any scenario fails. Build and run take about 10-15 s.

## Scenarios

Device 1 uses first-stage translation only; IOVA `0x400025a8` maps to
`0x10065a8`. Each run starts from reset, accesses the IOVA once to fill the
DDTC and the IOTLB, and then repeats the access. The testbench checks that the
repeated access reaches `0x10065a8` exactly once with an OKAY response, and that
the read returns the data stored there (or that the write updates it).

| Scenario | Kind | Before the repeated access |
| --- | --- | --- |
| `read_inval_sweep` | bug | `IODIR.INVAL_DDT` (all devices) and `IOFENCE.C` are submitted; the read is issued 0 to 24 cycles after the `cqt` write, one run per gap |
| `write_inval_sweep` | bug | same, with a write |
| `read_no_inval` | control | nothing |
| `write_no_inval` | control | nothing |
| `read_inval_done` | control | the same commands, and `cqh` has reached `cqt` |
| `write_inval_done` | control | same, with a write |

## Expected result

Before the fix both sweeps fail at gaps 0 and 1: the access is forwarded to
address `0x0` with an OKAY response. The controls pass. With the fix all six
scenarios pass.
