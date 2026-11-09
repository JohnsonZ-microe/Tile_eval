import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('wave_runner', ROOT / 'scripts/run.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class ProtocolWaveTests(unittest.TestCase):
    def test_wave_arguments(self):
        output = Path('results with spaces')
        # every bench now dumps waves when enabled (was protocol/tile only)
        names = {'cells': 'cells_v4.vcd',
                 'math': 'math_v4.vcd',
                 'modules': 'modules_v4.vcd',
                 'protocol': 'protocol_v4.vcd',
                 'memory': 'memory_v4.vcd',
                 'yacc': 'yacc_v4.vcd',
                 'control': 'control_v4.vcd',
                 'tile': 'tile_ffn_v4.vcd'}
        for test, vcd in names.items():
            self.assertEqual(RUNNER.waveform_arguments(False, test, output), [])
            self.assertEqual(RUNNER.waveform_arguments(True, test, output),
                             ['+VCD=' + str(output / vcd)])
        self.assertEqual(RUNNER.waveform_arguments(True, 'unknown', output), [])

    def test_dump_includes_dut_and_is_optional(self):
        benches = ['tb_cells_v4', 'tb_math_v4', 'tb_memory_v4',
                   'tb_yacc_v4', 'tb_control_v4', 'tb_protocol_v4',
                   'tb_tile_v4']
        for bench_name in benches:
            bench = (ROOT / ('tb/%s.sv' % bench_name)).read_text(encoding='utf-8')
            self.assertIn('if ($value$plusargs("VCD=%s", vcdfile))', bench,
                          bench_name + ' lacks the +VCD plusarg')
            self.assertIn('$dumpfile(vcdfile);', bench, bench_name)
            self.assertIn('$dumpvars(0, %s);' % bench_name, bench, bench_name)
        self.assertIn('PASS protocol fifo=',
                      (ROOT / 'tb/tb_protocol_v4.sv').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
