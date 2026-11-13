"""Source-contract checks only; not an HDL compiler or RTL simulation."""
from pathlib import Path
import unittest


class MemoryResetSourceTests(unittest.TestCase):
    def test_probe_is_required_before_pass(self):
        source=(Path(__file__).resolve().parents[1]/'tb/tb_memory_v4.sv').read_text(encoding='utf-8')
        self.assertIn('for (integer age = 1; age <= 2; age++)',source)
        self.assertIn('hold_requests <= 1',source)
        self.assertIn('if (reset_checked != 4) $fatal',source)
        self.assertLess(source.index('if (reset_checked != 4)'),source.index('PASS memory'))
        self.assertIn('reset_probes=%0d',source)

    def test_reset_asserts_pending_and_checks_recovery(self):
        source=(Path(__file__).resolve().parents[1]/'tb/tb_memory_v4.sv').read_text(encoding='utf-8')
        task=source.split('task automatic reset_inflight',1)[1].split('endtask',1)[0]
        self.assertIn("rram.outstanding !== 2'(age)",task)
        self.assertIn('@(posedge clk); #1;',task)
        self.assertIn('sr = hold_requests; rd_req = hold_requests; rreq = hold_requests;',task)
        for diagnostic in ('stale return after reset','h recovery data','XS lost across reset',
                           'X lost across reset','external memory recovery latency/data',
                           'duplicate recovery return'):
            self.assertIn(diagnostic,task)
        self.assertIn('memory global watchdog',source)


if __name__=='__main__':unittest.main()
