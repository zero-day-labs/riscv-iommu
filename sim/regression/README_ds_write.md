# DS write-path regression — `rv_iommu_ds_if` (`fix/ds-write-owner`)

Test-only, self-checking Verilator regression for the DS write path
(AW / W / B for CQ, FQ, MRIF handler, MSI IG, PQ) of the upstream
`rtl/ext_interfaces/rv_iommu_ds_if.sv`.  No RTL is modified here.

## Files

- `run_ds_write.py`          — runner
- `iommu_ds_if_write_tb.sv`  — testbench (instantiates the DUT)
- `iommu_ds_if_write_tb.cpp` — Verilator clock driver

## Run (from the repository root)

    git submodule update --init vendor/axi vendor/common_cells
    python3 sim/regression/run_ds_write.py                 # scenarios 1,2,3,4
    python3 sim/regression/run_ds_write.py --scenarios 1   # subset
    python3 sim/regression/run_ds_write.py --ds-source /path/to/before.sv --out /tmp/ds-before
    python3 sim/regression/run_ds_write.py --build-only    # compile the model only

Scenarios:

1. FQ only — one FQ burst (AWID=1, AWLEN=3): minimal `AW accepted but no W`.
2. All five writers active; distinct data, lengths 1..4, concurrent bursts.
3. CQ W offered before its AW (no W with an empty accepted-AW owner queue).
4. Twelve 1-beat FQ AWs; external WREADY held low until a fixed cycle.

Exit status is nonzero on build failure, scenario mismatch, or watchdog
timeout.  Logs (`build.log`, `run-scenario-<n>.log`) are written to a fresh
`tempfile.mkdtemp()` outside the repository unless `--out` is given.

## Status

Tested on 2026-10-12 with Verilator 4.038 against `mc/dti-ats` baseline
`c80bba7ae74b54b50eb1028e6efd4292661ca75b` and this fix:

- Baseline scenario 1: watchdog failure with AW=1, W beats=0, B=0.
- Fixed scenario 1: 1 burst, 4 W beats; scenario 2: 9 bursts, 21 W beats;
  scenario 3: 1 burst, 4 W beats; scenario 4: 12 bursts, 12 W beats.
  All four scenarios pass data, strobes, WLAST, response ownership and drain.

To reproduce the baseline without changing the working tree:

    git show c80bba7:rtl/ext_interfaces/rv_iommu_ds_if.sv > /tmp/rv_iommu_ds_if.before.sv
    python3 sim/regression/run_ds_write.py --ds-source /tmp/rv_iommu_ds_if.before.sv --scenarios 1

The first regression must fail on the baseline. These are standalone DS
interface simulations, not a claim of full-system or PRI/PQ generator validation.
