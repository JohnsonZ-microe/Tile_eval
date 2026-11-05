import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DrainAlarmSourceTests(unittest.TestCase):
    def test_full_drain_releases_slot(self):
        source = (ROOT / 'model' / 'vectors.py').read_text(encoding='utf-8')
        self.assertIn('(1 << 16) | (80 << 8)', source)
        data = (1 << 16) | (80 << 8)
        self.assertEqual((data >> 8) & 255, 80)
        self.assertEqual((data >> 16) & 1, 1)
        rtl = (ROOT / 'rtl' / 'tile_ffn_v4.sv').read_text(encoding='utf-8')
        self.assertIn('drain_lastseg <= ctrl_data[16];', rtl)

    def test_alarm_field_offsets(self):
        source = (ROOT / 'rtl' / 'pe4_sched.sv').read_text(encoding='utf-8')
        self.assertIn("err_first_bit_n, 10'b0, err_q_n}", source)
        status = 1 << 18
        payload = (5 << 40) | (18 << 32) | status
        self.assertEqual(payload, 0x0000051200040000)
        self.assertEqual(payload & 0xffffffff, status)
        self.assertEqual((payload >> 32) & 255, 18)
        self.assertEqual((payload >> 40) & 255, 5)


if __name__ == '__main__':
    unittest.main()
