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
        for test in ('protocol', 'tile'):
            self.assertEqual(RUNNER.waveform_arguments(False, test, output), [])
        self.assertEqual(RUNNER.waveform_arguments(True, 'protocol', output),
                         ['+VCD=' + str(output / 'protocol_v4.vcd')])
        self.assertEqual(RUNNER.waveform_arguments(True, 'tile', output),
                         ['+VCD=' + str(output / 'tile_ffn_v4.vcd')])
        self.assertEqual(RUNNER.waveform_arguments(True, 'math', output), [])

    def test_dump_includes_dut_and_is_optional(self):
        bench = (ROOT / 'tb/tb_protocol_v4.sv').read_text(encoding='utf-8')
        self.assertIn('if ($value$plusargs("VCD=%s", vcdfile))', bench)
        self.assertIn('$dumpfile(vcdfile);', bench)
        self.assertIn('$dumpvars(0, tb_protocol_v4);', bench)
        self.assertIn('PASS protocol fifo=', bench)


if __name__ == '__main__':
    unittest.main()
