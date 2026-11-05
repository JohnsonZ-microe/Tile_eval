import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rev4_runner', ROOT / 'scripts/run.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.manifest = {'commands': [], 'rtl_validation': 'not started'}

    def run_process(self, source, timeout=10, test='tile'):
        return RUNNER.execute_logged(
            [sys.executable, '-B', '-u', '-c', source],
            self.path / 'run_tile.log', self.path, dict(os.environ), timeout,
            self.manifest, self.path / 'manifest.json', test)

    def saved_record(self):
        saved = json.loads((self.path / 'manifest.json').read_text())
        self.assertEqual(saved['simulations']['tile'],
                         self.manifest['simulations']['tile'])
        self.assertGreaterEqual(saved['simulations']['tile']['seconds'], 0)
        return saved['simulations']['tile']

    def test_pass_and_running_manifest(self):
        self.run_process("import json; from pathlib import Path; "
                         "assert json.loads(Path('manifest.json').read_text())"
                         "['rtl_validation'] == 'running'; "
                         "print('PROGRESS event=heartbeat cycle=10'); "
                         "print('PASS tile beats=439')")
        record = self.saved_record()
        self.assertEqual(record['status'], 'passed')
        self.assertEqual(record['last_progress'], 'PROGRESS event=heartbeat cycle=10')
        self.assertEqual(record['returncode'], 0)

    def test_nonzero_exit(self):
        with self.assertRaises(RuntimeError):
            self.run_process("print('PASS tile'); raise SystemExit(3)")
        self.assertEqual(self.saved_record()['status'], 'failed')
        self.assertEqual(self.manifest['failed_step'], 'run_tile.log')

    def test_missing_pass(self):
        with self.assertRaises(RuntimeError):
            self.run_process("print('loaded 53843 RRAM words')")
        record = self.saved_record()
        self.assertEqual(record['status'], 'failed')
        self.assertIsNone(record['last_progress'])

    def test_fail_cannot_be_hidden_by_pass(self):
        with self.assertRaises(RuntimeError):
            self.run_process("print('FAIL beat 0'); print('PASS tile')")
        self.assertEqual(self.saved_record()['status'], 'failed')

    def test_timeout_retains_log_and_progress(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_process("import time; print('PROGRESS cycle=42', flush=True); "
                             "time.sleep(30)", timeout=2)
        record = self.saved_record()
        self.assertEqual(record['status'], 'timeout')
        self.assertEqual(record['last_progress'], 'PROGRESS cycle=42')
        self.assertEqual(self.manifest['rtl_validation'], 'timeout')
        self.assertIn('PROGRESS cycle=42', (self.path / 'run_tile.log').read_text())

    def test_pre_simulation_failure_remains_not_started(self):
        with self.assertRaises(RuntimeError):
            self.run_process('raise SystemExit(1)', test=None)
        self.assertEqual(self.manifest['rtl_validation'], 'not started')

    def test_tile_only_plusargs(self):
        args = argparse.Namespace(progress_cycles=0, wait_limit=23, max_cycles=99)
        values = RUNNER.diagnostic_arguments(args, 'tile')
        self.assertEqual(values, ['+PROGRESS_CYCLES=0', '+WAIT_LIMIT=23', '+MAX_CYCLES=99'])
        self.assertEqual(RUNNER.diagnostic_arguments(args, 'math'), [])
        command = [sys.executable, '-B', '-c', 'import sys; print(" ".join(sys.argv[1:])); print("PASS tile")'] + values
        log = RUNNER.execute_logged(command, self.path / 'args.log', self.path,
                                    dict(os.environ), 10, self.manifest,
                                    self.path / 'manifest.json', 'tile')
        for value in values:
            self.assertIn(value, log)

    def test_invalid_cli_arguments(self):
        for option, value in [('--progress-cycles', '-1'), ('--wait-limit', '0'),
                              ('--max-cycles', '0'), ('--max-cycles', '2147483648')]:
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/run.py'),
                                     'vcs', option, value], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, universal_newlines=True,
                                    timeout=10)
            self.assertEqual(result.returncode, 2)


class WatchdogSourceTests(unittest.TestCase):
    def test_all_waits_have_diagnostic_timeout(self):
        source = (ROOT / 'tb/tb_tile_v4.sv').read_text()
        for reason in ('wait_phase', 'wait_y_ready', 'wait_y_packet',
                       'wait_x_credit', 'final_drain', 'global_cycles'):
            self.assertIn('diagnostic_timeout("%s")' % reason, source)
        diagnostic = source.split('task automatic print_progress', 1)[1].split('endtask', 1)[0]
        self.assertIn('$fflush();', diagnostic)
        self.assertNotRegex(diagnostic, r'dut\.[\w.]+\s*(?:<=|=(?!=))')
        for name in ('PROGRESS_CYCLES', 'WAIT_LIMIT', 'MAX_CYCLES'):
            self.assertIn('$value$plusargs("%s=%%d"' % name, source)


if __name__ == '__main__':
    unittest.main()
