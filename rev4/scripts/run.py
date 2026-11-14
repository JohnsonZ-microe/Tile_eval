#!/usr/bin/env python3
"""Rev4 runner: local Python checks, VCS regression and DC entry points."""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB_DIR = '/dfs/app/tsmc_icdc/tsmc028/28HPCplus_RF_20260129/Standard_Cell_1/core_cell_library/gate_length_30nm/9-track/tcbn28hpcplusbwp30p140_190a/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp30p140_180a'
SIGMOID_SHA = 'b041becb8f31067459f0f9d9935d10af7cbe036817dc010a6624b41b89c6692c'
# Run products (snapshots, vectors, binaries, reports, manifests) go to
# PRODUCTS_DIR (server default /staff/ee/eezhyzhao/Desktop/Products); log
# files go to LOGS_DIR (server default ~/Desktop/Products/logs — same
# volume as the products, never the tsclient share). Each run uses the
# same <tool>-<stamp>-<pid> tag under both roots. On non-POSIX hosts
# without these paths the old in-tree results/ and logs/ are used.
DEFAULT_PRODUCTS = '/staff/ee/eezhyzhao/Desktop/Products'
DEFAULT_LOGS = '/staff/ee/eezhyzhao/Desktop/Products/logs'


def waveform_arguments(enabled, test, output):
    # Every bench accepts +VCD=<path>; math/modules share tb_math_v4 so the
    # file is named per test to avoid collisions in an --test all run.
    names = {'cells': 'cells_v4.vcd',
             'math': 'math_v4.vcd',
             'modules': 'modules_v4.vcd',
             'compute': 'compute_v4.vcd',
             'protocol': 'protocol_v4.vcd',
             'memory': 'memory_v4.vcd',
             'yacc': 'yacc_v4.vcd',
             'control': 'control_v4.vcd',
             'tile': 'tile_ffn_v4.vcd'}
    if not enabled or test not in names:
        return []
    return ['+VCD=' + str(Path(output) / names[test])]


def _writable(path):
    """True if path exists (or can be created) and accepts a test write."""
    try:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / '.write_probe'
        probe.write_text('ok')
        probe.unlink()
        return True
    except (OSError, IOError):
        return False


def pick_base(env_name, posix_default, fallback):
    # Priority: explicit env var > POSIX default if actually writable >
    # in-tree fallback. A stale NFS/share mount passes os.path.exists
    # but fails on real I/O with "Bad file descriptor" or similar,
    # so we probe with a write.
    value = os.getenv(env_name)
    if value:
        base = Path(os.path.expanduser(value))
        if not _writable(base):
            raise RuntimeError('%s=%s is not writable: %s'
                               % (env_name, value, base))
        return base
    candidate = Path(os.path.expanduser(posix_default))
    if os.name == 'posix':
        if _writable(candidate):
            return candidate
        # stale server mount (disconnected NFS/share): fall back to the
        # in-tree directory and warn on stderr
        sys.stderr.write(
            'WARNING: %s is not writable (stale mount?); using in-tree '
            '%s instead. Set %s to override.\n'
            % (candidate, fallback, env_name))
        return ROOT / fallback
    if candidate.exists() and _writable(candidate):
        return candidate
    return ROOT / fallback


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def cycle_argument(value):
    number = int(value)
    if number < 0 or number > 2147483647:
        raise argparse.ArgumentTypeError('cycle count must be in 0..2147483647')
    return number


def diagnostic_arguments(args, test):
    if test != 'tile':
        return []
    return ['+PROGRESS_CYCLES=%d' % args.progress_cycles,
            '+WAIT_LIMIT=%d' % args.wait_limit,
            '+MAX_CYCLES=%d' % args.max_cycles]


def execute_logged(command, logfile, cwd, environment, timeout,
                   manifest, manifest_path, test=None):
    command = list(map(str, command))
    manifest['commands'].append(command)
    manifest['current_step'] = logfile.name
    record = dict(status='running', seconds=None, last_progress=None)
    if test:
        manifest.setdefault('simulations', {})[test] = record
        manifest['rtl_validation'] = 'running'
    manifest_path.write_text(json.dumps(manifest, indent=1))
    print('Running: ' + ' '.join(command), flush=True)
    started = time.monotonic()
    verbose = os.getenv('VERBOSE', '').strip() in ('1', 'true', 'yes')
    try:
        if verbose:
            # tee mode: a daemon thread streams output to both the log file
            # and the terminal; the main thread enforces the timeout via
            # proc.wait() — a blocking for-loop on stdout would never reach
            # the timeout check when the process goes quiet.
            import threading
            proc = subprocess.Popen(command, cwd=str(cwd), env=environment,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT,
                                    universal_newlines=True)
            handle = logfile.open('w')

            def pump():
                for line in proc.stdout:
                    handle.write(line)
                    handle.flush()
                    sys.stdout.write(line)
                    sys.stdout.flush()

            reader = threading.Thread(target=pump, daemon=True)
            reader.start()
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                raise
            finally:
                reader.join(timeout=5)
                handle.close()
            done_rc = proc.returncode
            class _R:
                returncode = done_rc
            done = _R()
        else:
            with logfile.open('w') as output:
                done = subprocess.run(command, cwd=str(cwd), env=environment,
                                      stdout=output, stderr=subprocess.STDOUT,
                                      timeout=timeout)
        record['returncode'] = done.returncode
        log = logfile.read_text(errors='replace')
        if done.returncode:
            raise RuntimeError('%s exited %d; see %s' %
                               (command[0], done.returncode, logfile))
        if test and (not re.search(r'^PASS ' + re.escape(test) + r'\b', log, re.M)
                     or re.search(r'^\s*(FAIL\b|Fatal:|FATAL\b)', log, re.M)):
            raise RuntimeError('Missing clean PASS in ' + test)
        if test == 'yacc':
            overlap = re.findall(r'^CHECK yacc_overlap banks=2 offsets=86 packets=172 yields=([0-9]+)\s*$', log, re.M)
            passed = re.findall(r'^PASS yacc packets=300 cycles=([0-9]+)\s*$', log, re.M)
            identities = re.findall(r'^CHECK yacc_read_identity rows=3000\s*$', log, re.M)
            if len(overlap) != 1 or len(passed) != 1 or int(overlap[0]) <= 0 or int(passed[0]) <= 0:
                raise RuntimeError('Missing complete yacc overlap evidence')
            if len(identities) != 1 or log.index('CHECK yacc_read_identity') > log.index('PASS yacc'):
                raise RuntimeError('Missing complete yacc read identity evidence')
            if log.index('CHECK yacc_overlap') > log.index('PASS yacc'):
                raise RuntimeError('Yacc overlap evidence follows PASS')
            record['coverage'] = dict(packets=300, overlap_banks=2, overlap_offsets=86, overlap_packets=172,
                                      overlap_yields=int(overlap[0]), read_identity_rows=3000)
        record['status'] = 'passed'
        return log
    except subprocess.TimeoutExpired:
        record['status'] = 'timeout'
        manifest['failed_step'] = logfile.name
        raise
    except Exception:
        record['status'] = 'failed'
        manifest['failed_step'] = logfile.name
        raise
    finally:
        record['seconds'] = time.monotonic() - started
        if logfile.exists():
            with logfile.open(errors='replace') as output:
                for line in output:
                    if line.startswith('PROGRESS '):
                        record['last_progress'] = line.rstrip()
        if test:
            manifest['rtl_validation'] = record['status']
        manifest.setdefault('steps', {})[logfile.name] = record
        manifest_path.write_text(json.dumps(manifest, indent=1))


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument('tool', choices=['local', 'vcs', 'dc'])
    parser.add_argument('--suite', choices=['legacy', 'smoke', 'full'], default='full')
    parser.add_argument('--seed', type=int, default=817)
    parser.add_argument('--test', choices=['all', 'cells', 'math', 'modules', 'compute', 'protocol', 'memory', 'yacc', 'control', 'tile'],
                        default='all')
    parser.add_argument('--top', default='tile_ffn_v4')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--waves', action='store_true', default=os.getenv('WAVES') == '1')
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--calibration-trace', action='store_true')
    parser.add_argument('--overlap', action='store_true')
    parser.add_argument('--credit-period', type=cycle_argument, default=1)
    parser.add_argument('--input-gap', type=cycle_argument, default=1)
    parser.add_argument('--progress-cycles', type=cycle_argument, default=10000)
    parser.add_argument('--wait-limit', type=cycle_argument, default=2000000)
    parser.add_argument('--max-cycles', type=cycle_argument, default=20000000)
    args = parser.parse_args()
    if args.wait_limit == 0 or args.max_cycles == 0 or args.credit_period == 0:
        parser.error('--wait-limit and --max-cycles must be positive')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y%m%dT%H%M%SZ')
    tag = '%s-%s-%s' % (args.tool, stamp, os.getpid())
    products_root = pick_base('PRODUCTS_DIR', DEFAULT_PRODUCTS, 'results')
    logs_root = pick_base('LOGS_DIR', DEFAULT_LOGS, 'logs')
    out = (args.out or products_root / tag).resolve()
    out.mkdir(parents=True, exist_ok=False)
    logdir = (logs_root / tag).resolve()
    logdir.mkdir(parents=True, exist_ok=False)
    manifest = dict(tool=args.tool, seed=args.seed, suite=args.suite,
                    test=args.test, top=args.top, started_utc=stamp,
                    python=sys.version, commands=[], status='running',
                    products_dir=str(out), log_dir=str(logdir),
                    rtl_validation='not started', timing='not verified',
                    diagnostics=dict(progress_cycles=args.progress_cycles,
                                     wait_limit=args.wait_limit,
                                     max_cycles=args.max_cycles),
                    sram='behavioural arrays; no macro mapping')
    status = 1
    try:
        snap = out / 'snapshot'
        for name in ['rtl', 'tb', 'model', 'scripts', 'syn', 'docs']:
            shutil.copytree(str(ROOT / name), str(snap / name),
                            ignore=shutil.ignore_patterns('__pycache__',
                                                          '*.pyc'))
        oracle = ROOT.parent / 'model'
        frozen = json.loads((ROOT / 'docs/baseline.json').read_text())
        if digest(oracle / 'reference.py') != \
                frozen['sha256']['model/reference.py']:
            raise RuntimeError('Frozen revision-1 oracle hash mismatch')
        shutil.copytree(str(oracle), str(snap / 'oracle'),
                        ignore=shutil.ignore_patterns('__pycache__',
                                                      '*.pyc'))
        for f in (ROOT.parent / 'rev3' / 'rtl').glob('*.sv'):
            shutil.copy(str(f), str(snap / 'rtl' / ('rev3_' + f.name)))
            want = frozen['sha256'].get('rev3/rtl/' + f.name)
            if want and digest(f) != want:
                raise RuntimeError('Frozen rev3 source changed: %s' % f.name)
        if digest(ROOT / 'rtl/pe4_sigmoid_rom.hex') != SIGMOID_SHA:
            raise RuntimeError('sigmoid ROM hash mismatch')
        manifest['sources'] = {
            str(p.relative_to(snap)): digest(p)
            for p in snap.rglob('*') if p.is_file()}
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        timeout = int(os.getenv('TIMEOUT_SECONDS',
                                '345600' if args.tool == 'dc' else '1800'))
        if timeout <= 0:
            raise ValueError('TIMEOUT_SECONDS must be positive')
        manifest['timeout_seconds'] = timeout

        def run(command, name, test=None):
            return execute_logged(command, logdir / name, snap, environment,
                                  timeout, manifest, out / 'manifest.json', test)

        run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
             'model', '-p', 'test_*.py'], 'python_reference.log')
        run([sys.executable, '-B', 'model/vectors.py', '--outdir',
             str(out / 'vectors'), '--seed', str(args.seed), '--suite', args.suite], 'vectors.log')
        run([sys.executable, '-B', 'model/compute_trace.py', '--out',
             str(out / 'vectors/compute_trace.txt'), '--seed', str(args.seed)],
            'compute_trace.log')
        run([sys.executable, '-B', 'model/vector_check.py',
             str(out / 'vectors')], 'vector_check.log')
        for f in (ROOT / 'rtl').glob('*.sv'):
            text = f.read_text(errors='replace')
            if re.search(r'\b(real|shortreal)\b', text):
                raise RuntimeError('banned construct in ' + f.name)
            # structural sanity: balanced modules/packages (catches accidental
            # clobbering of RTL files, which the banned scan alone misses)
            is_pkg = re.search(r'\bpackage\s+\w+', text) is not None
            n_mod = len(re.findall(r'\bmodule\b', text))
            n_end = len(re.findall(r'\bendmodule\b', text))
            if n_mod != n_end or (n_mod == 0 and not is_pkg):
                raise RuntimeError('unbalanced modules in %s (%d/%d)'
                                   % (f.name, n_mod, n_end))
        all_rtl = ' '.join(f.read_text(errors='replace')
                           for f in (ROOT / 'rtl').glob('*.sv'))
        for need in ['tile_ffn_v4', 'pe4_sched', 'pe4_bus', 'pe4_act',
                     'pe4_quant', 'pe4_hbuf', 'pe4_yacc', 'pe4_fmul',
                     'pe4_sram', 'pe4_staging', 'pe4_fmul_probe',
                     'pe4_bb_rom']:
            if not re.search(r'\bmodule\s+' + need + r'\b', all_rtl):
                raise RuntimeError('missing RTL module ' + need)
        sources = []
        for ln in (snap / 'scripts/rtl.f').read_text().splitlines():
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            if ln.startswith('../rev3/rtl/'):
                # rev3 sources are snapshotted into rtl/ as rev3_<name>.sv
                sources.append(str(snap / 'rtl' /
                                   ('rev3_' + Path(ln).name)))
            else:
                sources.append(str(snap / ln))
        filelist = out / 'rtl.f'
        filelist.write_text('\n'.join('"%s"' % p.replace('\\', '/')
                                      for p in sources) + '\n')
        if args.tool == 'vcs':
            exe = shutil.which(os.getenv('VCS', 'vcs'))
            if not exe:
                raise RuntimeError('VCS not found')
            for test in (['cells', 'math', 'modules', 'compute', 'protocol', 'memory', 'yacc', 'control', 'tile'] if args.test == 'all'
                         else [args.test]):
                top = {'cells': 'tb_cells_v4', 'math': 'tb_math_v4', 'modules': 'tb_math_v4',
                       'compute': 'tb_compute_v4',
                       'protocol': 'tb_protocol_v4', 'memory': 'tb_memory_v4',
                       'yacc': 'tb_yacc_v4', 'control': 'tb_control_v4', 'tile': 'tb_tile_v4'}[test]
                binary = out / ('simv_' + test)
                clog = run([exe, '-full64', '-sverilog',
                            '-timescale=1ns/1ps', '-debug_access+all',
                            '-f', str(filelist),
                            str(snap / 'tb' / (top + '.sv')), '-top', top,
                            '-Mdir=' + str(out / ('csrc_' + test)),
                            '-o', str(binary)], 'compile_%s.log' % test)
                if re.search(r'^\s*Error[-:]', clog, re.M):
                    raise RuntimeError('VCS compile errors in ' + test)
                cmd = [str(binary),
                       '+VECTORS=' + str(out / 'vectors'),
                       '+SIGMOID_HEX=' + str(snap / 'rtl' /
                                             'pe4_sigmoid_rom.hex')]
                cmd.extend(waveform_arguments(args.waves, test, out))
                cmd.extend(diagnostic_arguments(args, test))
                if test == 'modules':
                    cmd.extend(['+RESULT_NAME=modules', '+MATH_FILE=modules.txt', '+BUBBLE_MASK=3',
                                '+RESET_AFTER=13'])
                if test == 'tile' and args.trace:
                    cmd.append('+TRACE=' + str(out / 'tile-events.csv'))
                if test == 'tile' and args.calibration_trace:
                    cmd.append('+CALIBRATION_TRACE=' + str(out / 'calibration-events.csv'))
                    manifest['calibration_trace'] = dict(schema=2, file='calibration-events.csv',
                        sampling='pre: inputs consumed at edge; post: registered outputs visible after edge',
                        cycle_origin='first active rising edge after reset = 0; epoch increments on subsequent reset',
                        calibration='not calibrated')
                if test == 'tile':
                    cmd.extend(['+CRED_PERIOD=%d' % args.credit_period,
                                '+GAP=%d' % args.input_gap])
                    if args.overlap:
                        cmd.append('+OVERLAP')
                log = run(cmd, 'run_%s.log' % test, test)
            manifest['rtl_validation'] = 'passed'
        elif args.tool == 'dc':
            exe = shutil.which(os.getenv('DC_SHELL', 'dc_shell'))
            if not exe:
                raise RuntimeError('dc_shell not found')
            target = os.getenv('TARGET_DB')
            if not target:
                raise RuntimeError('Set TARGET_DB')
            lib = Path(target)
            if not lib.is_absolute():
                lib = Path(os.getenv('LIB_DIR', LIB_DIR)) / lib
            if lib.suffix != '.db' or not lib.is_file():
                raise RuntimeError('TARGET_DB not readable: %s' % lib)
            environment.update(TARGET_DB=str(lib.resolve()),
                               DC_RUN_DIR=str(out), TOP=args.top,
                               FILELIST=str(filelist))
            manifest['library'] = dict(path=str(lib.resolve()),
                                       sha256=digest(lib))
            log = run([exe, '-f', str(snap / 'syn/run_dc.tcl')],
                      'dc_console.log')
            if re.search(r'^\s*Error:', log, re.M) or \
                    not (out / 'SYNTHESIS_COMPLETED').exists():
                raise RuntimeError('DC did not complete')
            manifest['mapping'] = 'completed; review reports'

        manifest['status'] = 'completed'
        status = 0
    except Exception as error:
        manifest['error'] = str(error)
        manifest['status'] = ('timeout' if isinstance(error, subprocess.TimeoutExpired)
                              else 'failed')
        if args.tool == 'vcs' and manifest.get('simulations'):
            manifest['rtl_validation'] = manifest['status']
        manifest.setdefault('failed_step', manifest.get('current_step', 'setup'))
    manifest['waveforms'] = [{'file': path.name, 'bytes': path.stat().st_size}
                             for path in sorted(out.glob('*.vcd'))]
    manifest['seconds'] = time.monotonic() - started
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=1))
    (out / 'exit_code.txt').write_text('%d\n' % status)
    (logdir / 'exit_code.txt').write_text('%d\n' % status)
    # mirror manifest and checks to the logs directory for one-stop access
    try:
        shutil.copy2(str(out / 'manifest.json'), str(logdir / 'manifest.json'))
        checks = out / 'vectors' / 'checks.json'
        if checks.exists():
            shutil.copy2(str(checks), str(logdir / 'checks.json'))
    except OSError:
        pass  # logs dir may be unwritable; products copies are authoritative
    print(json.dumps({k: manifest.get(k) for k in
                      ('status', 'error', 'rtl_validation', 'products_dir',
                       'log_dir', 'seconds')}))
    return status


if __name__ == '__main__':
    sys.exit(main())
