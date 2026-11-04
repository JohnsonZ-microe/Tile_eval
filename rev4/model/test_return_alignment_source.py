import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / 'rtl'


class ReturnAlignmentSourceTests(unittest.TestCase):
    def test_hold_tags_follow_two_register_return(self):
        text = (ROOT / 'pe4_sched.sv').read_text(encoding='utf-8')
        for prefix in ('stg', 'hbuf'):
            self.assertIn('{0}_kb_qq <= {0}_kb_q;'.format(prefix), text)
        self.assertIn('hold_v[stg_kb_qq[0]]', text)
        self.assertIn('hold_hv[hbuf_kb_qq[0]]', text)
        self.assertNotIn('hold_hv[hbuf_kb_q[0]]', text)

    def test_final_cast_uses_multiplier_valid(self):
        text = (ROOT / 'pe4_act.sv').read_text(encoding='utf-8')
        self.assertIn('.out_valid(m3_valid[t]), .result(m3[t])', text)
        self.assertIn('out_valid <= m3_valid[0];', text)
        self.assertIn('if (m3_valid[t]) h[t] <= fp32_to_bf16(m3[t]);', text)
        self.assertNotIn('out_valid <= vpipe[15];', text)


if __name__ == '__main__':
    unittest.main()
