#!/usr/bin/env python3
"""Local SV semantic compilation; never claims simulated RTL correctness.

Requires optional pyslang==12.1.0 (install in a separate environment).
Run from any working directory. Each top is compiled in an isolated subprocess.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TOPS = ('cells', 'math', 'compute', 'protocol', 'memory', 'yacc', 'control', 'tile', 'promotion')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', choices=TOPS + ('all',), default='tile')
    parser.add_argument('--out', type=Path, help='new evidence directory; must not already exist')
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        import pyslang
        from pyslang.driver import Driver
    except ImportError:
        parser.exit(2, 'Missing optional dependency: install pyslang==12.1.0 in your local tools environment.\n')
    if args.worker:
        if args.test == 'all':
            parser.error('worker requires one test')
        driver = Driver()
        driver.addStandardArgs()
        top = 'tb_' + args.test + '_v4'
        # Parent fixes cwd to ROOT. No shell expansion is used.
        if not driver.parseCommandLine('slang -f scripts/rtl.f tb/' + top + '.sv --top ' + top + ' --timescale 1ns/1ps'):
            return 2
        if not driver.processOptions() or not driver.parseAllSources():
            driver.reportDiagnostics(False)
            return 1
        compilation = driver.createCompilation()
        driver.reportCompilation(compilation, False)
        return 0 if driver.reportDiagnostics(False) else 1
    tests = TOPS if args.test == 'all' else (args.test,)
    sources = [ROOT / 'scripts/rtl.f', Path(__file__).resolve()]
    sources += [ROOT / line.strip() for line in (ROOT / 'scripts/rtl.f').read_text().splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
    sources += [ROOT / 'tb' / ('tb_' + test + '_v4.sv') for test in tests]
    result = dict(tool='pyslang', version=pyslang.__version__,
                  scope='SystemVerilog parsing and semantic elaboration only; no simulation, synthesis or PPA validation',
                  sources={str(path.resolve().relative_to(ROOT.parent)).replace('\\', '/'):
                           hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, tests=[])
    if args.out:
        args.out.mkdir(parents=True, exist_ok=False)
    for test in tests:
        process = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()), '--worker', '--test', test],
                                 cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = process.stdout.decode('utf-8', errors='replace')
        print(test + ': ' + ('passed' if process.returncode == 0 else 'failed'))
        if args.out:
            (args.out / (test + '.log')).write_text(text, encoding='utf-8')
        else:
            print(text)
        result['tests'].append(dict(test=test, exit_code=process.returncode, passed=process.returncode == 0))
    result['passed'] = all(test['passed'] for test in result['tests'])
    if args.out:
        (args.out / 'checks.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return 0 if result['passed'] else 1

if __name__ == '__main__':
    sys.exit(main())
