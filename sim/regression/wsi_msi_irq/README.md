# WSI and MSI interrupt signalling

Directed simulation of the full IOMMU (`lint_checks.sv` top) that checks two
things about interrupt signalling:

- **WSI with shared vectors.** With `fctl.WSI = 1`, each pending bit in `ipsr`
  must drive the wire selected by its `icvec` field, also when several sources
  share one vector. `wsi_iofence_shared` uses `icvec = 0` (the reset value) and
  an `IOFENCE.C` with WSI=1: `ipsr.cip` is set and wire 0 must rise.
  `wsi_fault_shared` uses `icvec = 0x110` (civ=0, fiv=1, pmiv=1, the layout
  Linux programs for two wires) and one fault: `ipsr.fip` is set and wire 1
  must rise. Both also check that no other wire rises.
- **MSI edges during a write.** With `fctl.WSI = 0`, every 0->1 transition of
  a pending bit must send an MSI. `msi_edge_b_held` sends the first MSI (fault
  1), holds its B response, clears `fip`, consumes the fault record, and causes
  fault 2, which sets `fip` again; then it releases the B response. It expects
  two MSI writes, each to the programmed address `0x9000` with data `0x55`, and
  `fqt = 2`.

Controls, which pass with and without the fix: `wsi_iofence_distinct` and
`wsi_fault_distinct` (the same with `icvec = 0x210`, one source per vector),
and `msi_edge_no_hold` (the MSI sequence with the B response returned at once).

The testbench drives the programming interface directly, serves the
data-structure port from a small memory model that can hold B responses, and
causes faults with device writes while `ddtp` is in its reset mode.

## Running

Needs only Verilator (tested with 5.022 and 5.052). From the repository root:

    python3 sim/regression/wsi_msi_irq/run.py
    python3 sim/regression/wsi_msi_irq/run.py -s msi_edge_b_held
    VERILATOR=/path/to/verilator python3 sim/regression/wsi_msi_irq/run.py

The exit status is 0 only if every scenario prints a PASS line. A build and
run of all six scenarios takes about 12 s.

## Expected results

With the fix, all six scenarios pass:

    PASS wsi_iofence_shared: icvec=0000 ipsr.cip=1 wire0 rises@41, wire1 never, wire2 never, wire3 never
    PASS wsi_fault_shared: icvec=0110 fault cause=256 ipsr.fip=1 wire0 never, wire1 rises@41, wire2 never, wire3 never
    PASS msi_edge_b_held: fqt=2, fip set again (read) at cycle 91, 2 MSI(s): [addr=0000000000009000 data=00000055 cycle 55] [addr=0000000000009000 data=00000055 cycle 114]

Before the fix, the three scenarios above fail (the controls pass):

    FAIL wsi_iofence_shared: icvec=0000 ipsr.cip=1 wire0 never, wire1 never, wire2 never, wire3 never; expected ipsr.cip=1 and only wire 0 rises
    FAIL wsi_fault_shared: icvec=0110 fault cause=256 ipsr.fip=1 wire0 never, wire1 never, wire2 never, wire3 never; expected cause=256, ipsr.fip=1 and only wire 1 rises
    FAIL msi_edge_b_held: fqt=2, fip set again (read) at cycle 91, 1 MSI(s): [addr=0000000000009000 data=00000055 cycle 55]; expected fqt=2 and two MSIs, each addr=0000000000009000 data=00000055

Cycle numbers count from the end of reset and are printed for information
only; the checks do not depend on them.
