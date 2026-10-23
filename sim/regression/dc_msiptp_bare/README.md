# dc_msiptp_bare

Directed regression for the device-context check that `DC.msiptp.MODE` must
be Off when `DC.iohgatp.MODE` is Bare (`rtl/translation_logic/cdw/`). The
specification reserves every other `msiptp` mode in that case and recommends
reporting "DDT entry misconfigured" (cause 259). The test runs on the full
IOMMU as instantiated by `lint_checks.sv` (which uses the process-context
CDW, `rv_iommu_cdw_pc`).

Device 1's context uses first-stage Sv39 with one 1 GiB identity leaf, and
the `iohgatp`/`msiptp` modes of the scenario. The fault queue is enabled.
Device 1 issues one write to IOVA 0x4000, which is not an MSI address.

| Scenario | Kind | `iohgatp` | `msiptp` | Expected |
| --- | --- | --- | --- | --- |
| `bare_flat` | bug | Bare | Flat | error response (SLVERR), nothing written, one fault record: cause 259, ttyp 3, did 1 |
| `bare_off` | control | Bare | Off | OKAY, written to 0x4000, no fault record |
| `sv39x4_flat` | control | Sv39x4 (1 GiB identity) | Flat | OKAY, written to 0x4000, no fault record |

## Running

Needs only Verilator (tested with 5.022 and 5.052). From the repository root:

    python3 sim/regression/dc_msiptp_bare/run.py
    python3 sim/regression/dc_msiptp_bare/run.py -s bare_flat
    VERILATOR=/path/to/verilator python3 sim/regression/dc_msiptp_bare/run.py

The build takes about 10 s with `-j 8`; the three simulations take well
under a second.

## Expected result

With the fix all three scenarios pass. Without it (`main` at 18ad30a) the
reserved context is accepted and the write goes through:

    FAIL bare_flat: iohgatp=0 msiptp=1 write_done=1 resp=0 written=1 addr=0000000000004000 data=1111222233334444 records=[]; expected iohgatp=0 msiptp=1 write_done=1 resp=2 written=0 records=[slot0:cause=259,ttyp=3,did=1]
    PASS bare_off: iohgatp=0 msiptp=0 write_done=1 resp=0 written=1 addr=0000000000004000 data=1111222233334444 records=[]
    PASS sv39x4_flat: iohgatp=8 msiptp=1 write_done=1 resp=0 written=1 addr=0000000000004000 data=1111222233334444 records=[]
