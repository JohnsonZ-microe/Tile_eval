import random
import struct
import unittest
from fractions import Fraction

from reference import (ArrayReference, CANON_NAN, INF, apply_scale, decode, decode_bf16,
                       dot32, fp_add, fp_mul, fp_shift, fp_value, pack, power2, round_fp32)


class NumericTests(unittest.TestCase):
    def test_roundtrip_all_bf16(self):
        for code in range(65536):
            value = fp_value(code << 16)
            expected = CANON_NAN if value == 'nan' else code << 16
            self.assertEqual(round_fp32(value, bool(code & 32768)), expected)

    def test_decode_exact(self):
        for fmt, count in ((0, 16), (1, 256), (2, 256), (3, 256), (4, 16)):
            for code in range(count):
                self.assertEqual(fp_value(decode_bf16(code, fmt) << 16), decode(code, fmt))
        self.assertEqual(decode(7, 0), 6)
        self.assertEqual(decode(8, 4), -8)
        self.assertEqual(decode(126, 1), 448)
        self.assertEqual(decode(1, 1), power2(-9))

    def test_rounding_boundaries(self):
        self.assertEqual(round_fp32(1 + power2(-24)), 0x3F800000)
        self.assertEqual(round_fp32(1 + 3 * power2(-24)), 0x3F800002)
        self.assertEqual(round_fp32(power2(-150)), 0)
        self.assertEqual(round_fp32(3 * power2(-150)), 2)
        self.assertEqual(round_fp32(power2(-126) - power2(-150)), 0x00800000)
        self.assertEqual(round_fp32(power2(128) - power2(103)), INF)
        self.assertEqual(round_fp32(-power2(-151)), 0x80000000)

    def test_specials(self):
        self.assertEqual(fp_add(INF, INF | 0x80000000), CANON_NAN)
        self.assertEqual(fp_mul(INF, 0), CANON_NAN)
        self.assertEqual(fp_add(0x80000000, 0x80000000), 0x80000000)
        self.assertEqual(fp_add(0x3F800000, 0xBF800000), 0)
        self.assertEqual(fp_mul(0x80000000, 0xBF800000), 0)
        self.assertEqual(dot32([0x7F80] + [0] * 31, [0] * 32, 5), CANON_NAN)

    def test_exact_cancellation(self):
        weights = [0x7F7F, 0x3F80, 0xFF7F] + [0] * 29
        self.assertEqual(dot32(weights, [0x38] * 32, 5), 0x3F800000)
        self.assertEqual(dot32([0x0001] * 32, [1] * 32, 5), round_fp32(32 * power2(-142)))

    def test_scale_rounding_order(self):
        self.assertEqual(apply_scale(1, 2, 126, 0x40000000), 0)
        self.assertEqual(fp_mul(1, 0x3F800000), 1)
        self.assertEqual(apply_scale(0x3F800000, 0, 255, 255), 0x3F800000)
        self.assertEqual(apply_scale(1, 0, 126, 128), 1)

    def test_host_arithmetic_crosscheck(self):
        rng = random.Random(817)
        for _ in range(2000):
            left_bits, right_bits = rng.getrandbits(32), rng.getrandbits(32)
            if (left_bits >> 23) & 255 == 255 or (right_bits >> 23) & 255 == 255:
                continue
            left = struct.unpack('!f', struct.pack('!I', left_bits))[0]
            right = struct.unpack('!f', struct.pack('!I', right_bits))[0]
            for operation, actual in ((left + right, fp_add(left_bits, right_bits)), (left * right, fp_mul(left_bits, right_bits))):
                try:
                    expected = struct.unpack('!I', struct.pack('!f', operation))[0]
                except OverflowError:
                    expected = INF | (0x80000000 if operation < 0 else 0)
                self.assertEqual(actual, expected)

    def test_accumulation_and_rejection(self):
        model = ArrayReference()
        transaction = dict(fmt=0, weights=pack([2] * 256, 4), activations=pack([0x38] * 128, 8),
                           ascales=pack([127] * 4, 8), wscales=pack([127] * 8, 32), mask=15,
                           base=0, first=1, last=0)
        self.assertEqual(model.execute(transaction)['results'] & 0xFFFFFFFF, round_fp32(32))
        transaction['first'] = 0
        self.assertEqual(model.execute(transaction)['results'] & 0xFFFFFFFF, round_fp32(64))
        transaction['base'] = 79
        self.assertEqual(model.execute(transaction)['error'], 2)
        self.assertEqual(model.rf[0][0], round_fp32(64))


if __name__ == '__main__':
    unittest.main()
