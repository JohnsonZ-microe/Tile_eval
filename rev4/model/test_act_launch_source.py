import re
import unittest
from pathlib import Path


class ActLaunchSourceTests(unittest.TestCase):
    def setUp(self):
        self.text = (Path(__file__).resolve().parents[1] /
                     'rtl/pe4_sched.sv').read_text(encoding='utf-8')

    def test_valid_uses_current_state_not_previous_column(self):
        self.assertIn('assign act_in_valid = rst_n && (pstate == P_ACT);', self.text)
        self.assertNotRegex(self.text, r'\bact_in_valid\s*<=')
        self.assertIn('act_g[t] = gu_snap[act_c][t];', self.text)
        self.assertIn('if (act_c != 35) act_c <= act_c + 1;', self.text)
        self.assertIn('else pstate <= P_ACTW;', self.text)

    def test_every_act_entry_resets_both_indices(self):
        entries = re.findall(r'pstate <= P_ACT;\s+act_c <= 0;\s+act_cout <= 0;', self.text)
        self.assertEqual(len(entries), 2)
        self.assertEqual(self.text.count('pstate <= P_ACT;'), 2)

    def test_bias_columns_do_not_wrap_at_32(self):
        self.assertIn('bias_gb[act_c]', self.text)
        self.assertIn('bias_ub[act_c]', self.text)
        self.assertNotIn("bias_gb[5'(act_c)]", self.text)


if __name__ == '__main__':
    unittest.main()
