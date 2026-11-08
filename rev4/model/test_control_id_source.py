import unittest
from pathlib import Path


class ControlIdentitySourceTests(unittest.TestCase):
    def test_register_layout_and_parameter_connection(self):
        root = Path(__file__).resolve().parents[1]
        sched = (root / 'rtl/pe4_sched.sv').read_text(encoding='utf-8')
        top = (root / 'rtl/tile_ffn_v4.sv').read_text(encoding='utf-8')
        bench = (root / 'tb/tb_control_v4.sv').read_text(encoding='utf-8')
        self.assertIn("{init_done, 19'b0, 4'd3, 2'b0, TILE_ID}", sched)
        self.assertIn("if (!rst_n) init_done <= 1'b0;", sched)
        self.assertIn("else init_done <= 1'b1;", sched)
        self.assertIn('.TILE_ID(SRC_ID[5:0])', top)
        self.assertIn("32'h80000300 | {26'b0, TEST_ID}", bench)
        self.assertNotIn('control(target,2,0,16)', bench)
        self.assertIn('up_payload !== expected_data[tail]', bench)
        for tile_id in range(64):
            expected = 0x80000300 | tile_id
            self.assertEqual(expected & 63, tile_id)
            self.assertEqual((expected >> 8) & 15, 3)
            self.assertEqual(expected >> 31, 1)


if __name__ == '__main__':
    unittest.main()
