import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


class CalibrationTraceSourceTests(unittest.TestCase):
    def test_optional_trace_and_sampling_contract(self):
        bench=(ROOT/'tb/tb_tile_v4.sv').read_text(encoding='utf-8')
        monitor=bench.split('integer calibration_fd = 0;',1)[1]
        self.assertIn('CALIBRATION_TRACE=%s',monitor)
        self.assertIn('epoch,cycle,sample,event,transaction,pass,phase,slot,kb,group,bank,payload',monitor)
        self.assertIn('if (calibration_fd)',monitor)
        self.assertIn('#1;',monitor)
        self.assertIn('"post", "pe_commit_visible"',monitor)
        self.assertNotIn('dut.',monitor.split('task automatic calibration_event',1)[0])
        for line in monitor.splitlines():
            self.assertNotRegex(line,r'^\s*dut\..*(?:<=| = )')
        for event in ('down','credit','memory_issue','memory_return','memory_consume','pe_accept','act_accept','quant_accept','bank_release','y_commit','drain_accept','up_beat','sync1','y_ready_visible'):
            self.assertIn('"'+event+'"',monitor)

    def test_runner_only_for_tile(self):
        runner=(ROOT/'scripts/run.py').read_text(encoding='utf-8')
        self.assertIn("parser.add_argument('--calibration-trace', action='store_true')",runner)
        self.assertIn("if test == 'tile' and args.calibration_trace:",runner)
        self.assertIn("calibration='not calibrated'",runner)


if __name__=='__main__':unittest.main()
