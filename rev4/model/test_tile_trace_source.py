import re
import unittest
from pathlib import Path


class TileTraceSourceTests(unittest.TestCase):
    def test_trace_dependencies_declared_before_use(self):
        root = Path(__file__).resolve().parents[1]
        bench = (root / 'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        first_trace = bench.index('task automatic trace_event')
        for declaration in ('logic up_valid;', 'logic [23:0] up_sideband;',
                            'logic sync0, sync1, err_line;',
                            'longint unsigned cycle_count = 0;',
                            'longint unsigned rq_probe_cycle = 0;'):
            self.assertEqual(bench.count(declaration), 1)
            self.assertLess(bench.index(declaration), first_trace)

    def test_bank_release_trace_uses_connected_bank(self):
        root = Path(__file__).resolve().parents[1]
        bench = (root / 'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        top = (root / 'rtl/tile_ffn_v4.sv').read_text(encoding='utf-8')
        self.assertNotRegex(bench, r'dut\.hbuf_bank\b')
        self.assertIn('trace_event("bank_release", dut.hbuf_release_bank, 0)', bench)
        self.assertIn('.hbuf_release_bank(hbuf_release_bank)', top)
        self.assertIn('.own_release_bank(hbuf_release_bank)', top)
        release_event = next(line for line in bench.splitlines()
                             if 'calibration_event("pre", "bank_release"' in line)
        self.assertIn("int'(dut.hbuf_release_bank)", release_event)


if __name__ == '__main__':
    unittest.main()
