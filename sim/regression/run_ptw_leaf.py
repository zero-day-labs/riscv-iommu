#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Verilate and run the bounded rv_iommu_ptw leaf-boundary regression.

Target tree
-----------
The repository root is two directories above this file:

    <root>/sim/regression/run_ptw_leaf.py   ->   <root>

Only paths inside this repository (<root>/rtl, <root>/packages and
<root>/vendor) are used.  The former CVA6 platform location
(cva6/corev_apu/riscv-iommu) is never referenced.

Build
-----
Builds the UNMODIFIED production
<root>/rtl/translation_logic/rv_iommu_ptw.sv together with
sim/regression/iommu_ptw_leaf_tb.sv and sim/regression/iommu_ptw_leaf_tb.cpp
using the Verilator 4.x (--cc --exe --build) flow with an explicit C++ clock
driver.  No --binary and no --timing; no timescale directive is added (avoids
TIMESCALEMOD).

The DUT is the real PTW; the page-table memory is a real read-only AXI AR/R
port driven from C++.  No FSM signal is forced and no internal branch is
mirrored.

The test wrapper is pinned to the upstream rv_iommu_ptw port list and does not
expose any e3_level_o output.

Usage
-----
    # production RTL (after the leaf fix) -- all scenarios must PASS
    python3 sim/regression/run_ptw_leaf.py

    # saved before-baseline copy, isolated output directory
    python3 sim/regression/run_ptw_leaf.py --ptw-source /path/to/rv_iommu_ptw.before.sv --out /tmp/iommu-ptw-leaf-before

    # only the legal 4 KiB read counterexample (scenario 1)
    python3 sim/regression/run_ptw_leaf.py --scenarios 1

    # compile the model but do not run any scenario
    python3 sim/regression/run_ptw_leaf.py --build-only

Exit status is nonzero if the build fails or if any scenario reports a mismatch.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT   = Path(__file__).resolve().parents[2]
HERE   = Path(__file__).resolve().parent
VENDOR = ROOT / 'vendor'

DEFAULT_PTW = ROOT / 'rtl' / 'translation_logic' / 'rv_iommu_ptw.sv'

TB     = HERE / 'iommu_ptw_leaf_tb.sv'
TB_CPP = HERE / 'iommu_ptw_leaf_tb.cpp'
TOP    = 'iommu_ptw_leaf_tb'

COMMON = VENDOR / 'common_cells' / 'src'
AXI    = VENDOR / 'axi' / 'src'
PKG    = ROOT / 'packages'

# Exactly the modules/packages needed by rv_iommu_ptw.sv and its wrapper.
SOURCES = [
    COMMON / 'cf_math_pkg.sv',
    AXI    / 'axi_pkg.sv',
    PKG    / 'rv_iommu_cfg_pkg.sv',
    PKG    / 'rv_iommu_reg_pkg.sv',
    PKG    / 'rv_iommu_pkg.sv',
]

INCDIRS = [
    VENDOR / 'axi' / 'include',
    VENDOR / 'common_cells' / 'include',
]

DEFINES = ['+define+ASSERTS_OFF']

ALL_SCENARIOS = ('1', '2', '3', '4', '5', '6', '7')


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
    ap.add_argument('--ptw-source', type=Path, default=DEFAULT_PTW,
                    help='rv_iommu_ptw.sv under test (default: production '
                         'rtl/translation_logic/rv_iommu_ptw.sv); pass the saved '
                         'before.sv to reproduce the baseline')
    ap.add_argument('--out', type=Path, default=None,
                    help='output directory (obj dir + logs); the default is a '
                         'fresh tempfile.mkdtemp() OUTSIDE this repository')
    ap.add_argument('--scenarios', default=','.join(ALL_SCENARIOS),
                    help='comma-separated scenario list (default all)')
    ap.add_argument('--build-only', action='store_true',
                    help='compile the model but do not run any scenario')
    opts = ap.parse_args()

    ptw_source = require(opts.ptw_source.resolve())
    tb         = require(TB)
    tb_cpp     = require(TB_CPP)

    if opts.out is None:
        out_dir = Path(tempfile.mkdtemp(prefix='iommu-ptw-leaf-'))
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

    sources = [require(p) for p in SOURCES] + [ptw_source, tb]

    build_log = out_dir / 'build.log'
    args = [
        'verilator',
        '--cc',
        '--exe',
        '--build',
        '-Wall',
        '-Wno-fatal',
        '--top-module', TOP,
        '--Mdir', str(obj_dir),
    ] + DEFINES
    for inc in INCDIRS:
        args += ['-I{}'.format(inc)]
    args += [str(p) for p in sources]
    args += [str(tb_cpp)]

    print('run_ptw_leaf: ptw_source={}'.format(ptw_source))
    print('run_ptw_leaf: out={}'.format(out_dir))
    print('run_ptw_leaf: build cmd: {} ...'.format(' '.join(args[:8])))

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
    print('run_ptw_leaf: exe={}'.format(exe))

    if opts.build_only:
        return 0

    results = []
    for sc in scenarios:
        run_log  = out_dir / 'run-scenario-{}.log'.format(sc)
        run_args = [str(exe), '+scenario={}'.format(sc)]
        print('run_ptw_leaf: running {}'.format(' '.join(run_args)))
        with run_log.open('w') as log:
            run = subprocess.run(run_args, stdout=log, stderr=subprocess.STDOUT)
        sys.stdout.write(tail(run_log, 40))
        results.append((sc, run.returncode))
        if run.returncode != 0:
            print('run_ptw_leaf: scenario {} FAILED (rc={})'.format(sc, run.returncode))

    rc = 0
    print('run_ptw_leaf: summary')
    for sc, r in results:
        status = 'PASS' if r == 0 else 'FAIL(rc={})'.format(r)
        print('  scenario {} -> {}'.format(sc, status))
        if r != 0:
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
