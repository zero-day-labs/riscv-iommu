# PTW leaf-boundary regression — `rv_iommu_ptw` (`fix/ptw-leaf-level`)

Test-only, self-checking Verilator regression for the leaf handling of the
upstream `rtl/translation_logic/rv_iommu_ptw.sv`.  The DUT is the real PTW;
the page-table memory is a real read-only AXI AR/R port driven from C++.  No
RTL is modified here and no internal signal is forced.

## Files

- `run_ptw_leaf.py`       — runner
- `iommu_ptw_leaf_tb.sv`  — test-only wrapper around the PTW
- `iommu_ptw_leaf_tb.cpp` — Verilator driver + page-table memory model

## Run (from the repository root)

    git submodule update --init vendor/axi vendor/common_cells
    python3 sim/regression/run_ptw_leaf.py                 # scenarios 1..7
    python3 sim/regression/run_ptw_leaf.py --scenarios 1   # subset
    python3 sim/regression/run_ptw_leaf.py --ptw-source /path/to/rv_iommu_ptw.before.sv --out /tmp/ptw-before
    python3 sim/regression/run_ptw_leaf.py --build-only    # compile the model only

Scenarios:

1. Sv39 4 KiB read leaf (3 AR reads).
2. Sv39 4 KiB write leaf.
3. Sv39 2 MiB read leaf (superpage).
4. Sv39 1 GiB read leaf (superpage).
5. invalid leaf (V=0) -> LOAD page fault.
6. write to leaf with D=0 -> STORE page fault.
7. two-stage Sv39/Sv39x4 walk, all levels 4 KiB.

The oracle (single IOTLB update, PPN/page-size/flags, AR/R counts, fault
cause) is unchanged from the original regression; scenarios are not weakened.

Exit status is nonzero on build failure or any scenario mismatch.  Logs
(`build.log`, `run-scenario-<n>.log`) are written to a fresh
`tempfile.mkdtemp()` outside the repository unless `--out` is given.

## Status

Tested on 2026-10-12 with Verilator 4.038 against `mc/dti-ats` baseline
`c80bba7ae74b54b50eb1028e6efd4292661ca75b` and this fix:

- Baseline scenarios 1 and 2: legal 4 KiB read/write produce one update followed
  by an erroneous page fault (cause 13/15); both regressions fail.
- Fixed: all seven scenarios pass. Valid leaves produce one update and no
  error; invalid V and clear D still fault without an update. The two-stage
  case completes 15 AR / 15 R handshakes with no pending response. The driver
  observes idle cycles after the update to catch a late error.

To reproduce the baseline without changing the working tree:

    git show c80bba7:rtl/translation_logic/rv_iommu_ptw.sv > /tmp/rv_iommu_ptw.before.sv
    python3 sim/regression/run_ptw_leaf.py --ptw-source /tmp/rv_iommu_ptw.before.sv --scenarios 1,2

Both baseline scenarios must fail. These are standalone PTW simulations,
not full-system or FPGA timing validation.
