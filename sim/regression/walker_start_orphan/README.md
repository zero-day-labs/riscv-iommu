# walker_start_orphan

Directed regression for two related walker problems:

- The page-table and context walkers lose their start request after an
  invalidation, so a request that misses never starts a walk
  (`walker_start_tb.sv`).
- A walk keeps running after its request has ended (an orphaned walk) and
  installs its result or reports its error against another request
  (`orphan_walk_tb.sv`).

Each testbench drives the full IOMMU through the repository's
`lint_checks.sv` top, with one small AXI memory on the data-structure port and
one on the completion port. Device contexts are in extended format in a
one-level DDT. Each scenario resets the IOMMU between runs and prints one
`PASS` or `FAIL` line. A request counts as unanswered after 2000 cycles. A
negative delay means the invalidation is submitted before the requests are
issued.

| Scenario | Testbench | Kind | What it does |
|---|---|---|---|
| `ddt_inval_between_walks` | walker_start | bug | Device 4 (context cached) reads an unmapped IOVA, so its walk ends in a page fault, while device 1 writes a mapped IOVA. `IODIR.INVAL_DDT` (all devices) and `IOFENCE.C` are submitted at delays -6..10 cycles relative to the two requests. Device 1's write and a later read from device 2 must complete with OKAY at all 17 delays. |
| `ddt_inval_two_stage` | walker_start | bug | As `ddt_inval_between_walks`, with an Sv39x4 second stage (4 KiB identity pages) for device 4, so its faulting walk is longer, and delays -8..15 (24 delays). |
| `no_inval` | walker_start | control | Same traffic without the invalidation. |
| `flush_at_walk_end` | walker_start | bug | Device 3 (context cached) writes an IOVA that misses in the IOTLB. `IOTINVAL.VMA` for GSCID 5 (used by no device) and `IOFENCE.C` are submitted at delays -5..10 relative to the write, so at some delays the flush executes in the cycle the walk installs its result. The write and a later read from device 2 must complete at all 16 delays. |
| `flush_after_walk` | walker_start | control | Same invalidation, submitted after the write has completed. |
| `cross_device_hit` | orphan_walk | bug | Device 1 uses both stages (PSCID 5, GSCID 1) and device 4 only the first stage, with the same PSCID value 5. Device 4's context is cached. Device 1 writes IOVA 0x4000_5000; k1 cycles later software clears device 1's `tc.V` and submits `IODIR.INVAL_DDT` for device 1 and `IOFENCE.C`; k2 cycles after that device 4 writes the same IOVA, which it has not mapped. 128 combinations: k1 = 0..15, k2 = 0, 2, 4, 8, second-stage leaf 2 MiB or 1 GiB. Device 4's data must not reach memory in any combination. |
| `cross_device_fault` | orphan_walk | bug | As `cross_device_hit`, and device 4's write must also be answered with SLVERR in every combination. |
| `no_context_inval` | orphan_walk | control | Same traffic without clearing `tc.V` and without `IODIR.INVAL_DDT`. Device 4's write must be answered with SLVERR and must not reach memory. |
| `own_page_after_inval` | orphan_walk | control | As `cross_device_hit`, but device 4 writes its own page (IOVA 0x4000_7008). It must be answered OKAY and arrive at 0x100c008. |
| `fault_record_did` | orphan_walk | bug | Device 4 (context cached) reads an IOVA whose level-1 PTE is invalid. Software clears device 4's `tc.V` and submits `IODIR.INVAL_DDT` for device 4 and `IOFENCE.C` at delays -10..5 cycles relative to the read. Every fault-queue record must have TTYP 2 (untranslated read) and DID 4. |
| `inval_after_fault` | orphan_walk | control | Same, with the invalidation after the read completed: one record, cause 13, TTYP 2, DID 4. |

## Running

Needs only Verilator (tested with 5.022 and 5.052) and Python 3. From the
repository root:

    python3 sim/regression/walker_start_orphan/run.py
    python3 sim/regression/walker_start_orphan/run.py -s cross_device_fault
    VERILATOR=/path/to/verilator python3 sim/regression/walker_start_orphan/run.py

`run.py` builds two simulation models (one per testbench). The builds and all
eleven scenarios take about 25 s.

## Expected results

Without the fix (`main`):

    FAIL ddt_inval_between_walks: 5 of 17 run(s) failed (delay -5,-4,-3,-2,-1: device-4 read SLVERR, device-1 write no response in 2000 cycles, device-2 read no response in 2000 cycles); expected every run to complete with OKAY
    FAIL ddt_inval_two_stage: 4 of 24 run(s) failed (delay 8,9,10,11: device-4 read SLVERR, device-1 write no response in 2000 cycles, device-2 read no response in 2000 cycles); expected every run to complete with OKAY
    PASS no_inval: 1 of 1 run(s) completed, final read done at cycle 106
    FAIL flush_at_walk_end: 2 of 16 run(s) failed (delay 0,1: device-3 write no response in 2000 cycles, device-2 read no response in 2000 cycles); expected every run to complete with OKAY
    PASS flush_after_walk: 1 of 1 run(s) completed, final read done at cycle 94
    FAIL cross_device_hit: device-4 write reached memory in 28 of 128 combinations (e.g. 2M k1=4 k2=0: OKAY at 0x1009000; 2M k1=4 k2=2: OKAY at 0x1009000; 2M k1=4 k2=4: OKAY at 0x1009000); expected 0
    FAIL cross_device_fault: 28 of 128 combinations wrong (e.g. 2M k1=4 k2=0: OKAY at 0x1009000; 2M k1=4 k2=2: OKAY at 0x1009000; 2M k1=4 k2=4: OKAY at 0x1009000); expected SLVERR without reaching memory in all
    PASS no_context_inval: device-4 write answered SLVERR without reaching memory in 128 of 128 combinations
    PASS own_page_after_inval: device-4 write answered OKAY and arrived at 0x100c008 in 128 of 128 combinations
    FAIL fault_record_did: 5 of 16 runs wrong (delay -5,-4,-3,-2,-1; e.g. record cause 258 ttyp 0 did 0); expected only records with TTYP 2 and DID 4
    PASS inval_after_fault: only TTYP 2 / DID 4 records in 1 of 1 runs: cause 13 ttyp 2 did 4 (1)
    5 of 11 scenarios passed

With the fix:

    PASS ddt_inval_between_walks: 17 of 17 run(s) completed, final read done at cycle 106-121
    PASS ddt_inval_two_stage: 24 of 24 run(s) completed, final read done at cycle 142-162
    PASS no_inval: 1 of 1 run(s) completed, final read done at cycle 106
    PASS flush_at_walk_end: 16 of 16 run(s) completed, final read done at cycle 88-98
    PASS flush_after_walk: 1 of 1 run(s) completed, final read done at cycle 94
    PASS cross_device_hit: device-4 write reached memory in 0 of 128 combinations (no response in 0)
    PASS cross_device_fault: device-4 write answered SLVERR without reaching memory in 128 of 128 combinations
    PASS no_context_inval: device-4 write answered SLVERR without reaching memory in 128 of 128 combinations
    PASS own_page_after_inval: device-4 write answered OKAY and arrived at 0x100c008 in 128 of 128 combinations
    PASS fault_record_did: only TTYP 2 / DID 4 records in 16 of 16 runs: cause 13 ttyp 2 did 4 (6), cause 258 ttyp 2 did 4 (5), no record (5)
    PASS inval_after_fault: only TTYP 2 / DID 4 records in 1 of 1 runs: cause 13 ttyp 2 did 4 (1)
    11 of 11 scenarios passed

On `main` the 28 cross-device combinations are all 2 MiB ones (k1 = 4-8, 10,
11, every k2), and device 4's write lands in device 1's page at 0x1009000. The
simulation log of each scenario (`run_<scenario>.log` in the output directory)
lists every delay or combination with its responses.

## Why the two parts are tested together

Each part of the fix alone leaves some of these scenarios failing:

- With only the walker start part, a walk whose cache entry was flushed while
  it ran starts again if its request is still present when the walker returns
  to IDLE. When that request ends with a fault in the same cycle, the new walk
  is orphaned and its error is charged to the next request: device 1's write
  is answered with SLVERR at delay -6 in `ddt_inval_between_walks` and at
  delays -6..7 in `ddt_inval_two_stage`. The orphan-walk scenarios fail as on
  `main`.
- With only the orphaned-walk part, the walker start scenarios fail as on
  `main`, and in the 28 cross-device combinations device 4's write no longer
  reaches memory but is never answered (`cross_device_fault`): the orphaned
  walk is still running when device 4's request misses in the IOTLB, and the
  page-table walker consumes that start edge while busy.

In `fault_record_did`, at delays -5..-1 the read's own page fault is not
recorded, with or without the fix; on `main` the only record at those delays
is the one with TTYP 0 and DID 0.
