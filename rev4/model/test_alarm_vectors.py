import unittest

from vectors import initial_numeric_alarm


class AlarmVectorTests(unittest.TestCase):
    def test_reserved_activation_alarm(self):
        for code in (0x7f, 0xff):
            for byte in (0, 31, 63):
                staging = {'x': {(0, 0): code << (8 * byte)}}
                alarm = initial_numeric_alarm(staging, 5)
                self.assertEqual(alarm['payload'], 0x51200040000)
                self.assertEqual(alarm['type'], 2)
                self.assertEqual(alarm['tag'], 0xf3)
                self.assertTrue(alarm['last'])

    def test_no_alarm_invented_for_legal_inputs(self):
        for code in (0, 0x7e, 0xfe, 0x80):
            with self.assertRaises(ValueError):
                initial_numeric_alarm({'x': {(0, 0): code}}, 5)

    def test_pass_identifier_is_not_hardcoded(self):
        alarm = initial_numeric_alarm({'x': {(2, 17): 0x7f}}, 19)
        self.assertEqual(alarm['payload'] >> 40, 19)


if __name__ == '__main__':
    unittest.main()
