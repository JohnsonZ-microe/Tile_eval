import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / 'rtl'


class MultiTokenSourceTests(unittest.TestCase):
    def test_staging_ready_waits_for_last_lane(self):
        text = (ROOT / 'pe4_sched.sv').read_text(encoding='utf-8')
        for flag in ('xs_popped[exp_grp]', 'x_popped[xfifo_out_idx]'):
            self.assertIn('if (exp_lane + 1 >= gl) ' + flag + ' <= 1;', text)
        for count in range(1, 5):
            accepted = [lane for lane in range(count) if lane + 1 >= count]
            self.assertEqual(accepted, [count - 1])

    def test_each_completed_lane_publishes_its_own_slot(self):
        text = (ROOT / 'pe4_yacc.sv').read_text(encoding='utf-8')
        self.assertRegex(text, r'if \(row_sel == 9\) begin\s+v_set_req <= 1;\s+v_set_bank <= cbank;\s+v_set_slot <= cur_slot;')
        self.assertNotIn('v_set_slot <= cslots[l];', text)
        done = text.split('CDONE: begin', 1)[1].split('end', 1)[0]
        self.assertNotIn('v_set_req', done)


if __name__ == '__main__':
    unittest.main()
