import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FinalDrainSourceTests(unittest.TestCase):
    def setUp(self):
        self.source = (ROOT / 'tb/tb_tile_v4.sv').read_text()
        self.groups = {}
        assignments = re.findall(r'assign drain_blocked\[(\d+)\] = (.*?);',
                                 self.source, re.S)
        self.assertEqual(len(assignments), 12)
        for index, expression in assignments:
            if int(index) == 0:
                self.assertRegex(expression, r'pstate === 3\x27d0')
                self.assertRegex(expression, r'pstate === 3\x27d1')
                continue
            self.assertRegex(expression, r"^\([\w.\[\]{}, ]+ !== '0\)$")
            self.groups[int(index)] = re.findall(r'[a-zA-Z_]\w*(?:\[\d+\])?(?:\.[a-zA-Z_]\w*(?:\[\d+\])?)*',
                                                 expression.split('!==')[0])

    def evaluate_source_groups(self, state, values):
        blocked = int(state not in (0, 1))
        for index, signals in self.groups.items():
            if any(values.get(signal, 0) != 0 for signal in signals):
                blocked |= 1 << index
        return blocked

    def test_idle_and_run_are_quiescent(self):
        for state in (0, 1):
            self.assertEqual(self.evaluate_source_groups(state, {}), 0)
        for state in (2, 3, 4, 5, 6, 7, 'x', 'z'):
            self.assertNotEqual(self.evaluate_source_groups(state, {}), 0)

    def test_each_busy_or_unknown_signal_blocks(self):
        for index, signals in self.groups.items():
            for signal in signals:
                for value in (1, 'x', 'z'):
                    with self.subTest(signal=signal, value=value):
                        self.assertEqual(self.evaluate_source_groups(1, {signal: value}),
                                         1 << index)

    def test_required_resources_are_present(self):
        signals = set(signal for group in self.groups.values() for signal in group)
        self.assertTrue({'dut.sched_u.slot[0].valid', 'dut.sched_u.slot[1].valid',
                         'dut.sched_u.cap_cnt', 'dut.sched_u.rq_cnt',
                         'dut.pe_u.busy', 'dut.sched_u.pend_act',
                         'dut.sched_u.pend_commit', 'dut.yacc_u.commit_busy',
                         'dut.yacc_u.dstate', 'dut.bus_u.active_valid',
                         'dut.bus_u.hup_valid', 'dut.yb_valid', 'dut.st_valid',
                         'dut.alarm_valid', 'dut.stf_cnt'}.issubset(signals))
        self.assertNotIn('dut.sched_u.err_q', signals)
        self.assertNotIn('err_line', signals)

    def test_consecutive_idle_and_timeout_preserved(self):
        drain = self.source.split('begin : drain', 1)[1].split('if (sync1_count', 1)[0]
        self.assertIn('@(negedge clk);', drain)
        self.assertIn('while (idle < 200)', drain)
        self.assertIn("idle = (drain_blocked === 12'b0) ? idle + 1 : 0;", drain)
        self.assertIn('waited >= wait_limit && idle < 200', drain)
        self.assertIn('diagnostic_timeout("final_drain")', drain)
        idle = 0
        for blocked in [0] * 199 + [1] + [0] * 199:
            idle = idle + 1 if blocked == 0 else 0
            self.assertLess(idle, 200)
        self.assertEqual(idle + 1, 200)

    def test_scoreboard_and_diagnostics_retained(self):
        self.assertIn('slot_valid=%b%b cap=%0d drain_blocked=%03x', self.source)
        self.assertIn('up_payload !== e_payload', self.source)
        self.assertIn("dut.sched_u.err_q !== 22'h0e0004", self.source)
        self.assertIn('if (e_valid)', self.source)
        self.assertIn('sync1_count != 24', self.source)


if __name__ == '__main__':
    unittest.main()
