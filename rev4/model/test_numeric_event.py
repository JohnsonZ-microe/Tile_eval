import re
import unittest
from pathlib import Path


class NumericEventTests(unittest.TestCase):
    def test_held_error_does_not_reassert_after_clear(self):
        text = (Path(__file__).resolve().parents[1] /
                'rtl/pe4_sched.sv').read_text(encoding='utf-8')
        expression = re.search(r'err_events\[ERR_NUMERIC\]\s*=\s*([^;]+);', text).group(1)
        self.assertIn(expression, ('quant_err', 'quant_ov && quant_err'))
        def event(valid, error):
            return error if expression == 'quant_err' else valid and error
        sticky = event(True, True)
        self.assertTrue(sticky)
        sticky = (sticky and not True) or event(False, True)
        self.assertFalse(sticky, 'held quant_err must not reassert during a bubble')
        self.assertTrue(event(True, True))
        self.assertFalse(event(True, False))


if __name__ == '__main__':
    unittest.main()
