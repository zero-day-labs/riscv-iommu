# Dirty-bit check on IOTLB hits

Checks that a device write through a leaf PTE with D=0 raises a store page
fault also when the translation hits in the IOTLB. The IOMMU does not update
A/D bits in hardware (`capabilities.AMO_HWAD = 0`), so a write needs W, A and D
set in the leaf; the page-table walker checks D on a miss, and the IOTLB hit
path (`rtl/translation_logic/wrapper/rv_iommu_tw_sv39x4_pc.sv`) must check it
too.

## Files

- `run.py`: builds the model with Verilator and runs every scenario
- `iotlb_hit_dirty_tb.sv`: full IOMMU through `lint_checks.sv`, a memory model
  on the data-structure and downstream ports, directed device accesses
- `include/common_cells/assertions.svh`: forwards to `include/assertions.svh`
  (`rv_iommu_regmap.sv` includes the `common_cells/` path, which the repository
  does not ship)

## Run

From the repository root (Verilator only; tested with 5.022 and 5.052):

    python3 sim/regression/iotlb_hit_dirty/run.py
    python3 sim/regression/iotlb_hit_dirty/run.py -s rwa_nod_write_after_read_4k
    VERILATOR=/path/to/verilator python3 sim/regression/iotlb_hit_dirty/run.py

Each scenario prints a `PASS` or `FAIL` line with the observed values. The exit
status is nonzero if any scenario fails. Build and run take about 15-20 s.

## Scenarios

Device 1 uses first-stage translation only. The leaf is a 4 KiB page (IOVA
`0x40003000` to `0x1009000`) or a 2 MiB page (IOVA `0x80201000` to
`0x1001000`), and its flags are one of:

- `rwa_nod`: V R W U A, D=0
- `rwad`: V R W U A D
- `r_only`: V R U A D (no W)
- `r_noa`: V R U D (A=0)

In `write_after_read` scenarios the device reads the IOVA first, which caches
the leaf, so the write is an IOTLB hit. In `cold_write` scenarios the device
only writes, and the write walks the page table. The testbench checks the read
and write responses (OKAY or SLVERR), the downstream accesses, and the fault
queue records (cause 13 for a read, 15 for a write, `iotval` = IOVA).

| Scenario | Kind | Expected |
| --- | --- | --- |
| `rwa_nod_write_after_read_{4k,2m}` | bug | read OKAY; write SLVERR, no downstream write, cause 15 |
| `rwad_write_after_read_{4k,2m}` | control | read and write OKAY |
| `r_only_write_after_read_{4k,2m}` | control | read OKAY; write SLVERR, cause 15 |
| `r_noa_write_after_read_{4k,2m}` | control | read SLVERR, cause 13; write SLVERR, cause 15 |
| `rwa_nod_cold_write_{4k,2m}` | control | write SLVERR, cause 15 |
| `rwad_cold_write_{4k,2m}` | control | write OKAY |
| `r_only_cold_write_{4k,2m}` | control | write SLVERR, cause 15 |

## Expected result

Before the fix the two bug scenarios fail: the write after the read completes
with OKAY, reaches memory, and records no fault. The controls pass. With the
fix all fourteen scenarios pass.
