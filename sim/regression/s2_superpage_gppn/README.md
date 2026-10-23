# Second-stage superpage regression

Checks the system physical address of a device access when first-stage and
second-stage translation are both enabled and the second-stage leaf is a
2 MiB or 1 GiB superpage. Inside the superpage, the low PPN bits must come
from the guest physical page selected by the first stage
(`rtl/translation_logic/wrapper/rv_iommu_tw_sv39x4_pc.sv`, IOTLB hit path).

## Files

- `run.py`: builds the model with Verilator and runs every scenario
- `s2_superpage_gppn_tb.sv`: full IOMMU through `lint_checks.sv`, a memory
  model on the data-structure and downstream ports, directed device accesses
- `include/common_cells/assertions.svh`: forwards to `include/assertions.svh`
  (`rv_iommu_regmap.sv` includes the `common_cells/` path, which the repository
  does not ship)

## Run

From the repository root (Verilator only; tested with 5.022 and 5.052):

    python3 sim/regression/s2_superpage_gppn/run.py
    python3 sim/regression/s2_superpage_gppn/run.py -s s1_4k_s2_2m
    VERILATOR=/path/to/verilator python3 sim/regression/s2_superpage_gppn/run.py

Each scenario prints a `PASS` or `FAIL` line with the observed addresses. The
exit status is nonzero if any scenario fails. Build and run take about 10-15 s.

## Scenarios

Device 1 writes an IOVA and then reads it back; the read hits the IOTLB entry
that the write's walk installed. The second stage is an identity map. The
testbench checks the downstream address of both accesses, the responses and
the data read back.

| Scenario | Kind | First stage | Second stage | Expected address |
| --- | --- | --- | --- | --- |
| `s1_4k_s2_2m` | bug | IOVA `0x40003000`, 4 KiB leaf to GPA `0x1009000` | 2 MiB leaves | `0x1009000` |
| `s1_4k_s2_1g` | bug | IOVA `0x40003000`, 4 KiB leaf to GPA `0x1009000` | 1 GiB leaf | `0x1009000` |
| `s1_2m_s2_1g` | bug | IOVA `0x80201000`, 2 MiB leaf to GPA `0x1000000` | 1 GiB leaf | `0x1001000` |
| `s1_2m_s2_2m` | control | IOVA `0x80201000`, 2 MiB leaf to GPA `0x1000000` | 2 MiB leaves | `0x1001000` |
| `s2_only_4k` | control | Bare | GPA `0x40002000`, 4 KiB leaf to `0x100b000` | `0x100b000` |

## Expected result

Before the fix the three bug scenarios fail: the accesses go to `0x1001000`
(`s1_4k_s2_2m`) and `0x1000` (`s1_4k_s2_1g`, `s1_2m_s2_1g`). The controls pass.
With the fix all five scenarios pass.
