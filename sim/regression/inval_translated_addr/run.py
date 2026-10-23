#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build and run the inval_translated_addr regression with Verilator.

Run from anywhere; the repository root is three levels above this file:

    python3 sim/regression/inval_translated_addr/run.py               # all scenarios
    python3 sim/regression/inval_translated_addr/run.py -s a,b        # a subset
    python3 sim/regression/inval_translated_addr/run.py --list        # list scenarios
    VERILATOR=/path/to/verilator python3 sim/regression/inval_translated_addr/run.py

The testbench instantiates the full IOMMU through the repository's
lint_checks.sv top, with the same include directories as the Makefile.
Each scenario runs in its own simulation and prints one PASS or FAIL line
with the values it observed.  The exit status is nonzero if the build
fails or any scenario does not pass.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

# Include directories of the repository Makefile (INC).  The local "include"
# directory comes first: it only provides common_cells/assertions.svh, which
# rv_iommu_regmap.sv includes but the repository does not ship.
INCDIRS = [HERE / 'include'] + [ROOT / d for d in (
    'packages/dependencies',
    'packages/rv_iommu',
    'vendor',
    'include',
    'rtl',
    'rtl/translation_logic',
    'rtl/translation_logic/cdw',
    'rtl/translation_logic/ptw',
    'rtl/translation_logic/wrapper',
    'rtl/software_interface',
    'rtl/software_interface/regmap',
    'rtl/software_interface/wrapper',
    'rtl/ext_interfaces',
)]

WARN_FLAGS = ['-Wno-fatal', '-Wno-lint', '-Wno-style', '-Wno-LATCH',
              '-Wno-MULTIDRIVEN', '-Wno-TIMESCALEMOD']

# One entry per simulation model: top module and source files.
BUILDS = {
    'top': dict(top='inval_translated_addr_tb',
                sources=[ROOT / 'lint_checks.sv', HERE / 'inval_translated_addr_tb.sv']),
}

# (name, build, plusargs, kind, description).  kind is 'bug' for a scenario
# that fails before the fix and 'control' for one that passes on both.
SCENARIOS = [
    ('read_inval_sweep', 'top', ['+scenario=read_inval_sweep'], 'bug',
     'warm read repeated 0-24 cycles after IODIR.INVAL_DDT is submitted'),
    ('write_inval_sweep', 'top', ['+scenario=write_inval_sweep'], 'bug',
     'warm write repeated 0-24 cycles after IODIR.INVAL_DDT is submitted'),
    ('read_no_inval', 'top', ['+scenario=read_no_inval'], 'control',
     'warm read repeated without an invalidation'),
    ('write_no_inval', 'top', ['+scenario=write_no_inval'], 'control',
     'warm write repeated without an invalidation'),
    ('read_inval_done', 'top', ['+scenario=read_inval_done'], 'control',
     'read repeated after the invalidation completed'),
    ('write_inval_done', 'top', ['+scenario=write_inval_done'], 'control',
     'write repeated after the invalidation completed'),
]

TIMEOUT_S = 600


def build(verilator, name, spec, out, jobs):
    mdir = out / ('obj_' + name)
    args = [verilator, '--binary', '--timing', '--sv',
            '--top-module', spec['top'], '--Mdir', str(mdir),
            '-j', str(jobs)] + WARN_FLAGS
    args += ['-I{}'.format(d) for d in INCDIRS]
    args += [str(s) for s in spec['sources']]
    log = out / ('build_' + name + '.log')
    with log.open('w') as fh:
        rc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT).returncode
    exe = mdir / ('V' + spec['top'])
    if rc != 0 or not exe.is_file():
        sys.stdout.write(''.join(log.read_text(errors='replace').splitlines(True)[-40:]))
        print('build {} FAILED (rc={}), log: {}'.format(name, rc, log))
        return None
    return exe


def run_one(exe, sc, out):
    name, _, plusargs, _, _ = sc
    log = out / ('run_' + name + '.log')
    t0 = time.time()
    try:
        p = subprocess.run([str(exe)] + plusargs, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=TIMEOUT_S,
                           universal_newlines=True)
        text, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        text, rc = (e.output or '') if isinstance(e.output, str) else '', -1
        text += '\nFAIL {}: simulation timed out after {} s\n'.format(name, TIMEOUT_S)
    log.write_text(text)
    lines = [l for l in text.splitlines() if l.startswith(('PASS', 'FAIL'))]
    ok = rc == 0 and lines and all(l.startswith('PASS') for l in lines)
    return name, ok, lines, rc, time.time() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-s', '--scenarios', default='',
                    help='comma-separated subset (default: all)')
    ap.add_argument('--list', action='store_true', help='list scenarios and exit')
    ap.add_argument('--out', type=Path, default=None,
                    help='build/log directory (default: a new temporary directory)')
    ap.add_argument('--verilator', default=os.environ.get('VERILATOR', 'verilator'),
                    help='verilator executable (default: $VERILATOR or verilator)')
    ap.add_argument('-j', '--jobs', type=int, default=min(8, os.cpu_count() or 1))
    ap.add_argument('--keep', action='store_true',
                    help='keep the temporary directory')
    opts = ap.parse_args()

    if opts.list:
        for name, _, _, kind, desc in SCENARIOS:
            print('{:28s} {:8s} {}'.format(name, kind, desc))
        return 0
    want = [s for s in opts.scenarios.split(',') if s]
    unknown = sorted(set(want) - {s[0] for s in SCENARIOS})
    if unknown:
        print('unknown scenario(s): ' + ', '.join(unknown))
        return 2
    selected = [s for s in SCENARIOS if not want or s[0] in want]

    if shutil.which(opts.verilator) is None:
        print('verilator not found: ' + opts.verilator)
        return 2
    tmp = opts.out is None
    out = Path(tempfile.mkdtemp(prefix='inval_translated_addr-')) if tmp else opts.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    ver = subprocess.run([opts.verilator, '--version'], stdout=subprocess.PIPE,
                         universal_newlines=True).stdout.strip()
    print('{} | root {} | out {}'.format(ver, ROOT, out))

    exes = {}
    for b in sorted({s[1] for s in selected}):
        exes[b] = build(opts.verilator, b, BUILDS[b], out, opts.jobs)
        if exes[b] is None:
            return 1

    with ThreadPoolExecutor(max_workers=opts.jobs) as pool:
        results = list(pool.map(lambda sc: run_one(exes[sc[1]], sc, out), selected))

    failed = 0
    kinds = {s[0]: s[3] for s in SCENARIOS}
    for name, ok, lines, rc, dt in results:
        for l in lines or ['FAIL {}: no result line (exit status {})'.format(name, rc)]:
            print(l)
        failed += not ok
    print('summary:')
    for name, ok, _, rc, dt in results:
        print('  {:28s} {:8s} {:4s} ({:.1f} s)'.format(
            name, kinds[name], 'PASS' if ok else 'FAIL', dt))
    print('{} of {} scenarios passed'.format(len(results) - failed, len(results)))
    if tmp and not opts.keep and not failed:
        shutil.rmtree(str(out), ignore_errors=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
