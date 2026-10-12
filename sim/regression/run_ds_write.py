#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Verilate and run the bounded rv_iommu_ds_if write-path regression.

Target tree
-----------
The repository root is two directories above this file:

    <root>/sim/regression/run_ds_write.py   ->   <root>

Only paths inside this repository (<root>/rtl and <root>/vendor) are used.
The former CVA6 platform location (cva6/corev_apu/riscv-iommu) is never
referenced.

Build
-----
Builds the UNMODIFIED production
<root>/rtl/ext_interfaces/rv_iommu_ds_if.sv together with
sim/regression/iommu_ds_if_write_tb.sv and
sim/regression/iommu_ds_if_write_tb.cpp using the Verilator 4.x
(--cc --exe --build) flow with an explicit C++ clock driver.  No --binary and
no --timing are used.

Vendor sources: only this repository's vendor tree (<root>/vendor), i.e. the
axi/ + common_cells/ modules actually needed by rv_iommu_ds_if.  The
fifo_v3 / ariane_pkg dependency chain used by the iDMA test is NOT pulled in.

Usage
-----
    # production RTL (after fix)
    python3 sim/regression/run_ds_write.py

    # saved before-baseline copy, isolated output directory
    python3 sim/regression/run_ds_write.py --ds-source /path/to/before.sv --out /tmp/iommu-ds-if-write-before

    # old baseline only (scenario 1)
    python3 sim/regression/run_ds_write.py --scenarios 1

    # compile the model but do not run any scenario
    python3 sim/regression/run_ds_write.py --build-only

Exit status is nonzero if the build fails, if any scenario reports a mismatch,
or if a scenario times out.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
VENDOR = ROOT / 'vendor'

DEFAULT_DS = ROOT / 'rtl' / 'ext_interfaces' / 'rv_iommu_ds_if.sv'
TB         = HERE / 'iommu_ds_if_write_tb.sv'
TB_CPP     = HERE / 'iommu_ds_if_write_tb.cpp'
TOP        = 'iommu_ds_if_write_tb'

COMMON = VENDOR / 'common_cells' / 'src'
AXI    = VENDOR / 'axi' / 'src'

# Exactly the modules needed by rv_iommu_ds_if.sv and its dependencies.
SOURCES = [
    COMMON / 'cf_math_pkg.sv',
    AXI    / 'axi_pkg.sv',
    COMMON / 'lzc.sv',
    COMMON / 'fifo_v3.sv',
    COMMON / 'spill_register_flushable.sv',
    COMMON / 'spill_register.sv',
    COMMON / 'rr_arb_tree.sv',
    COMMON / 'stream_arbiter_flushable.sv',
    COMMON / 'stream_arbiter.sv',
    COMMON / 'stream_mux.sv',
    COMMON / 'stream_demux.sv',
]

INCDIRS = [
    VENDOR / 'axi' / 'include',
    VENDOR / 'common_cells' / 'include',
]

# Disable common_cells / AXI assertions (same idea as test_nonblock_banked.py).
DEFINES = ['+define+ASSERTS_OFF', '+define+COMMON_CELLS_ASSERTS_OFF']

ALL_SCENARIOS = ('1', '2', '3', '4')


def require(path: Path) -> Path:
    if not path.exists():
        sys.exit('required file missing: {}'.format(path))
    return path


def tail(path: Path, lines: int = 240) -> str:
    try:
        text = path.read_text(errors='replace').splitlines()
    except OSError:
        return ''
    return '\n'.join(text[-lines:]) + '\n'


def find_exe(obj_dir: Path, top: str):
    cand = obj_dir / ('V' + top)
    if cand.is_file() and os.access(str(cand), os.X_OK):
        return cand
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument('--ds-source', type=Path, default=DEFAULT_DS,
                    help='rv_iommu_ds_if.sv under test (default: production '
                         'rtl/ext_interfaces/rv_iommu_ds_if.sv); pass a saved '
                         'before.sv to reproduce the baseline')
    ap.add_argument('--out', type=Path, default=None,
                    help='output directory (obj dir + logs); the default is a '
                         'fresh tempfile.mkdtemp() OUTSIDE this repository')
    ap.add_argument('--scenarios', default=','.join(ALL_SCENARIOS),
                    help='comma-separated scenario list (default 1,2,3,4)')
    ap.add_argument('--build-only', action='store_true',
                    help='compile the model but do not run any scenario')
    opts = ap.parse_args()

    ds_source = require(opts.ds_source.resolve())
    tb        = require(TB)
    tb_cpp    = require(TB_CPP)

    if opts.out is None:
        out_dir = Path(tempfile.mkdtemp(prefix='iommu-ds-if-write-'))
    else:
        out_dir = opts.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    obj_dir = out_dir / 'obj'
    obj_dir.mkdir(parents=True, exist_ok=True)

    scenarios = [s.strip() for s in opts.scenarios.split(',') if s.strip()]
    if not scenarios:
        sys.stderr.write('empty scenario list\n')
        return 1
    bad = [s for s in scenarios if s not in ALL_SCENARIOS]
    if bad:
        sys.stderr.write('unknown scenario(s): {}\n'.format(','.join(bad)))
        return 1

    for inc in INCDIRS:
        if not inc.exists():
            sys.exit('required include directory missing: {}'.format(inc))

    sources = [require(p) for p in SOURCES] + [ds_source, tb]

    build_log = out_dir / 'build.log'
    args = [
        'verilator',
        '--cc',
        '--exe',
        '--build',
        '-Wno-fatal',
        '--top-module', TOP,
        '--Mdir', str(obj_dir),
    ] + DEFINES
    for inc in INCDIRS:
        args += ['-I{}'.format(inc)]
    args += [str(p) for p in sources]
    args += [str(tb_cpp)]

    print('run_ds_write: ds_source={}'.format(ds_source))
    print('run_ds_write: out={}'.format(out_dir))
    print('run_ds_write: build cmd: {} ...'.format(' '.join(args[:8])))

    with build_log.open('w') as log:
        build = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT)
    if build.returncode != 0:
        sys.stderr.write(tail(build_log))
        sys.stderr.write('verilator build FAILED (rc={})\n'.format(build.returncode))
        return 1

    exe = find_exe(obj_dir, TOP)
    if exe is None:
        sys.stderr.write(tail(build_log))
        sys.stderr.write('verilator did not produce an executable for {}\n'.format(TOP))
        return 1
    print('run_ds_write: exe={}'.format(exe))

    if opts.build_only:
        return 0

    results = []
    for sc in scenarios:
        run_log  = out_dir / 'run-scenario-{}.log'.format(sc)
        run_args = [str(exe), '+scenario={}'.format(sc)]
        print('run_ds_write: running {}'.format(' '.join(run_args)))
        with run_log.open('w') as log:
            run = subprocess.run(run_args, stdout=log, stderr=subprocess.STDOUT)
        sys.stdout.write(tail(run_log, 60))
        results.append((sc, run.returncode))
        if run.returncode != 0:
            print('run_ds_write: scenario {} FAILED (rc={})'.format(sc, run.returncode))

    rc = 0
    print('run_ds_write: summary')
    for sc, r in results:
        status = 'PASS' if r == 0 else 'FAIL(rc={})'.format(r)
        print('  scenario {} -> {}'.format(sc, status))
        if r != 0:
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
