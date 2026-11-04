import re
import unittest
from pathlib import Path


class SchedulerEventSourceTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / 'rtl/pe4_sched.sv'
        self.text = re.sub(r'//[^\n]*', '', path.read_text(encoding='utf-8'))

    def test_events_are_current_cycle_not_overwritten_registers(self):
        self.assertIn('assign cons_fire = head_ready_q || head_scale_q || pe_accept;', self.text)
        self.assertIn('assign cap_push = pe_accept;', self.text)
        self.assertNotRegex(self.text, r'\b(?:cons_fire|cap_push)\s*<=')

    def test_consume_advances_and_releases_head(self):
        self.assertRegex(self.text, r'if \(cons_fire\) begin\s+rq_cons <= rq_cons \+ 2\x27d1;\s+rq\[rq_cons\[1:0\]\]\.full <= 1\x27b0;')
        assignment = re.search(r'rq_cnt <= rq_cnt(.*?);', self.text, re.S).group(1)
        self.assertIn('cons_fire', assignment)
        self.assertIn('iss_fire0', assignment)
        self.assertIn('iss_fire1', assignment)

    def test_capture_uses_same_accept_event(self):
        self.assertRegex(self.text, r'else if \(pe_accept\) begin\s+cap_q\[cap_head\[5:0\]\] <=')
        self.assertRegex(self.text, r'cap_cnt <= cap_cnt \+ \(cap_push .*?-\s*\(pe_out_valid', re.S)


if __name__ == '__main__':
    unittest.main()
