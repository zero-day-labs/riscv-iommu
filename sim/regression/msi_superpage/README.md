# msi_superpage

Directed simulation of the full IOMMU (`lint_checks.sv` top) for device writes
that the first stage translates with a 2 MiB or 1 GiB leaf while MSI address
translation is on. The device context uses an Sv39 first stage, an Sv39x4
second stage with 4 KiB leaves, and a flat MSI page table. Each scenario
issues one 32-bit write from device 1. The testbench checks the write
response, the downstream address and data, the first MSI page-table entry
read, and the fault-queue record.

| Scenario | Kind | Setup | Expected |
|---|---|---|---|
| `msi_page_4k` | control | pattern 4, mask 0, IOVA `0x4000` via a 4 KiB leaf | MSI PTE 0 read, write to `0x2002000` |
| `msi_page_1g` | bug | same, via a 1 GiB leaf | MSI PTE 0 read, write to `0x2002000` |
| `plain_page_4k` | control | pattern 0, no valid MSI PTE, IOVA `0x4000` via a 4 KiB leaf | no MSI PTE read, write to `0x604000` |
| `plain_page_1g` | bug | same, via a 1 GiB leaf | no MSI PTE read, write to `0x604000` |
| `ifile1_2m` | bug | pattern `0x30000`, mask 1, interrupt file 1 via a 2 MiB leaf | MSI PTE 1 read, write to `0x2005008` |
| `ifile1_2m_pte0_valid` | bug | same, and MSI PTE 0 valid, pointing at `0x2002000` | MSI PTE 1 read, write to `0x2005008` |
| `ifile1_4k` | control | interrupt file 1 via 4 KiB leaves | MSI PTE 1 read, write to `0x2005008` |
| `ifile0_mask0_2m` | control | pattern `0x30000`, mask 0, via a 2 MiB leaf | MSI PTE 0 read, write to `0x2005008` |

## Running

From the repository root (only Verilator is needed; tested with 5.022 and
5.052):

    python3 sim/regression/msi_superpage/run.py
    python3 sim/regression/msi_superpage/run.py -s ifile1_2m --out build/msi
    VERILATOR=/path/to/verilator python3 sim/regression/msi_superpage/run.py

`--list` lists the scenarios. The exit status is nonzero if the build fails or
any scenario does not pass. One build plus all scenarios takes about 15 s.

## Expected result

With the fix all 8 scenarios pass. Without it, the four `bug` scenarios fail
and the controls pass:

    FAIL msi_page_1g: resp=OKAY write=0x604000 data=0x2a msipt_read=none fault_cause=none; expected resp=OKAY write=0x2002000 data=0x2a msipt_read=0x90000 fault_cause=none
    FAIL plain_page_1g: resp=SLVERR write=none data=none msipt_read=0x90000 fault_cause=262; expected resp=OKAY write=0x604000 data=0x2a msipt_read=none fault_cause=none
    FAIL ifile1_2m: resp=SLVERR write=none data=none msipt_read=0x90000 fault_cause=262; expected resp=OKAY write=0x2005008 data=0x2a msipt_read=0x90010 fault_cause=none
    FAIL ifile1_2m_pte0_valid: resp=OKAY write=0x2002008 data=0x2a msipt_read=0x90000 fault_cause=none; expected resp=OKAY write=0x2005008 data=0x2a msipt_read=0x90010 fault_cause=none
