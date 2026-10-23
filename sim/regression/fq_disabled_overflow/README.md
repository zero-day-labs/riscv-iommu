# fq_disabled_overflow

Directed regression for `rtl/software_interface/rv_iommu_fq_handler.sv`,
run on the full IOMMU as instantiated by `lint_checks.sv`.

Device 1 has a valid device context. Device 3 has none, so each of its
writes faults with cause 258 and produces one fault record. Each scenario
sends one write from device 1, then N faulting writes from device 3, reads
`fqh`/`fqt`/`fqcsr`, and finally sends one read from device 1.

| Scenario | Kind | Setup | Expected |
| --- | --- | --- | --- |
| `fq_disabled` | bug | FQ disabled (reset state), 8 faults | all 8 faulting writes get an error response, 0 records, device 1 read served |
| `fq_overflow` | bug | FQ enabled, 4 entries, `fqh` left at 0, 20 faults | all 20 complete, 3 records in slots 0-2, `fqt = 3`, `fqcsr.fqof = 1`, device 1 read served |
| `fq_fits` | control | FQ enabled, 4 entries, 3 faults | 3 records, `fqt = 3`, `fqof = 0`, device 1 read served |

Each record is also checked for cause 258, ttyp 3 (untranslated write),
device ID 3 and `iotval` equal to the faulting address.

## Running

Needs only Verilator (tested with 5.022 and 5.052). From the repository root:

    python3 sim/regression/fq_disabled_overflow/run.py
    python3 sim/regression/fq_disabled_overflow/run.py -s fq_overflow
    VERILATOR=/path/to/verilator python3 sim/regression/fq_disabled_overflow/run.py

The build takes about 10 s with `-j 8`; the three simulations take well
under a second.

## Expected result

With the fix all three scenarios pass. Without it (`main` at 18ad30a):

    FAIL fq_disabled: faults_completed=4/8 error_responses=4 records=0 slots=[] fqh=0 fqt=0 fqcsr=00000000 fqof=0 device1_read_served=0; expected ...
    FAIL fq_overflow: faults_completed=20/20 error_responses=20 records=20 slots=[0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3,0,1,2,3] fqh=0 fqt=0 fqcsr=00010001 fqof=0 device1_read_served=1; expected ...
    PASS fq_fits: faults_completed=3/3 error_responses=3 records=3 slots=[0,1,2] fqh=0 fqt=3 fqcsr=00010001 fqof=0 device1_read_served=1 (117 cycles)

In `fq_disabled` the fifth faulting write never gets a response and
device 1's read is never accepted. In `fq_overflow` the tail wraps over
unread records and `fqof` is never set.
