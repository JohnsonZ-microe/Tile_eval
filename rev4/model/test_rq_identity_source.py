import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RqIdentitySourceTests(unittest.TestCase):
    def test_read_only_monitor_has_independent_lifecycle_and_metadata(self):
        bench = (ROOT/'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        monitor = bench.split('begin : rq_identity_monitor', 1)[1].split('logic [127:0] exp_payload;', 1)[0]
        self.assertNotRegex(monitor, r'dut\.[\w.\[\]]+\s*(?:<=|=(?!=))')
        for text in ('rq_probe_consumed % 4', 'rq_probe_returned % 4', 'rq_probe_issued % 4',
                     'RQ probe pre-edge capacity violation', 'RQ probe missing scheduled return',
                     'RQ probe same-edge return bypass', 'RQ probe metadata/pass mismatch',
                     'RQ probe consumed data mismatch', 'RQ probe unknown returned data'):
            self.assertIn(text, monitor)
        self.assertLess(monitor.index('if (dut.sched_u.cons_fire)'), monitor.index('if (dut.rram_valid)'))
        self.assertNotIn('rq_push', monitor)
        self.assertNotIn('rq_fill', monitor)
        self.assertNotIn('rq_cons[', monitor)
        widths = [1, 1, 1, 1, 2, 4, 8, 6, 4, 3]
        self.assertEqual(sum(widths), 31)
        for field in ('slot', 'phase', 'bias', 'scale', 'bidx', 'swi', 'kb', 'g', 'ncols', 'fmt'):
            self.assertIn('dut.sched_u.head.' + field, monitor)

    def test_final_pass_requires_nonempty_and_conserved_probe(self):
        bench = (ROOT/'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        before_pass = bench.split('$display("PASS tile', 1)[0]
        for text in ('rq_probe_issued == 0', 'rq_probe_issued != rq_probe_returned',
                     'rq_probe_returned != rq_probe_consumed', 'CHECK rq_identity'):
            self.assertIn(text, before_pass)


if __name__ == '__main__':
    unittest.main()
