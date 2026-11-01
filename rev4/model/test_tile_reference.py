"""Unit tests for the rev4 golden reference (python -m unittest)."""
import hashlib
import math
import random
import struct
import unittest
from fractions import Fraction

import tile_reference as tr
from tile_reference import ArrayReference, fp_add, fp_mul, fp_value  # noqa: F401


class TestFmul(unittest.TestCase):
    def test_against_oracle(self):
        rng = random.Random(817)
        corners = [0, 0x80000000, 0x3F800000, 0x7F800000, 0xFF800000,
                   0x7FC00000, 0x00800000, 0x00000001, 0x7F7FFFFF,
                   0x00000002, 0x00400000, 0x33800000, 0x477FFF00]
        pairs = [(rng.randrange(0, 1 << 32), rng.randrange(0, 1 << 32))
                 for _ in range(4000)]
        pairs += [(a, b) for a in corners for b in corners]
        for a, b in pairs:
            self.assertEqual(tr.fmul(a, b), fp_mul(a, b),
                             'fmul(%08x,%08x)' % (a, b))


class TestE4M3(unittest.TestCase):
    def test_encoder_against_bruteforce(self):
        rng = random.Random(31)
        cases = []
        for _ in range(400):
            code = rng.randrange(0, 0x7F80) | (rng.choice([0, 1]) << 15)
            cases.append((code << 16, rng.randrange(-30, 40)))
        for e in (-22, -9, 0, 7, 15, 60, 120):
            for code in (0x0000, 0x0001, 0x007F, 0x3F80, 0x4000, 0x4120,
                         0x42F6, 0xBF80, 0x7F7F, 0x0002, 0x8000, 0x8001):
                cases.append((code << 16, e))
        for x, e in cases:
            got = tr.e4m3_encode(x, e)
            want = tr.e4m3_from_value(fp_value(x), e, bool(x >> 31))
            self.assertEqual(got, want, 'e4m3(%08x,%d)' % (x, e))

    def test_quantize_matches_direct(self):
        rng = random.Random(97)
        for _ in range(600):
            codes = [rng.randrange(0, 0x7F80) for _ in range(32)]
            q, se = tr.quantize_block(codes)
            amax = max([abs(fp_value(c << 16)) for c in codes]
                       + [Fraction(1, 10000)])
            ratio = amax / 448
            e_direct = 0
            while Fraction(2) ** e_direct < ratio:
                e_direct += 1
            while Fraction(2) ** e_direct >= ratio * 2:
                e_direct -= 1
            if Fraction(2) ** e_direct < ratio:
                e_direct += 1
            self.assertEqual(se, e_direct + 127, 'se for %s' % codes[:4])
            for j, c in enumerate(codes):
                v = fp_value(c << 16)
                want = tr.e4m3_from_value(Fraction(v), e_direct)
                self.assertEqual(q[j], want, 'q[%d] block %s e=%d'
                                 % (j, codes[:4], e_direct))


class TestSigmoid(unittest.TestCase):
    def test_specials(self):
        self.assertEqual(tr.sigmoid(0x0000), 0x3F000000)
        self.assertEqual(tr.sigmoid(0x8000), 0x3F000000)
        self.assertEqual(tr.sigmoid(0x7F80), 0x3F800000)
        self.assertEqual(tr.sigmoid(0xFF80), 0x00000000)
        self.assertEqual(tr.sigmoid(0x7FC0), 0x7FC00000)

    def test_monotone_and_range(self):
        prev = -1.0
        for code in range(0x0000, 0x7F80, 7):
            v = tr.of_fp32(tr.sigmoid(code))
            self.assertTrue(0.0 <= v <= 1.0)
            self.assertGreaterEqual(v, prev - 1e-12)
            prev = v


class TestScenario(unittest.TestCase):
    def test_fp4_pass_runs(self):
        import vectors as vec
        out = None
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            stats = vec.main_wrapper(out, seed=817)
            self.assertEqual(stats['scenarios'], 12)
            self.assertGreater(stats['beats'], 0)
            # flit/expect/rram files exist and sizes are sane
            self.assertTrue((out / 'flits.txt').exists())
            self.assertTrue((out / 'expect.txt').exists())
            words = (out / 'rram.hex').read_text().splitlines()
            self.assertTrue(all(len(w.split()[-1]) == 256 for w in words))


class TestAuditProbes(unittest.TestCase):
    """Probes from the 2026-10-31 audit, kept as permanent regression."""

    def test_all_ones_dot32_r4_001(self):
        # R4-001: 32 x (1.0 x 1.0) must round to FP32 32.0 (0x42000000)
        self.assertEqual(fp_mul(0x3F800000, 0x3F800000), 0x3F800000)
        total = 0
        for _ in range(32):
            total = fp_add(total, 0x3F800000)
        self.assertEqual(total, 0x42000000)

    def test_golden_pass_changes_with_weights_r4_001(self):
        import vectors as vec
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as td:
            vec.main_wrapper(td, seed=817)
            expect = (Path(td) / 'expect.txt').read_text().splitlines()
        nonzero = [l for l in expect if l.startswith('U 0 ')
                   and int(l.split()[-1], 16) != 0]
        self.assertGreater(len(nonzero), 0,
                           'H_UP beats must be nonzero once the matrix '
                           'actually accumulates (R4-001)')

    def test_sigmoid_far_negative_subnormal_r4_009(self):
        # BF16 -101 = 0xC2CA; sigmoid(-101) ~= e^-101 ~= 1.3e-44
        # -> FP32 subnormal 0x0000000a
        self.assertEqual(tr.sigmoid(0xC2CA), 0x0000000A)
        # monotone non-decreasing, no premature zero region above -149ish
        prev = -1.0
        for code in range(0xC180, 0xBF80, 3):   # large finite negatives
            v = tr.of_fp32(tr.sigmoid(code))
            self.assertTrue(v >= prev - 1e-45)
            prev = v

    def test_bf16_cast_keeps_nan_r4_010(self):
        self.assertEqual(tr.fp32_to_bf16(0x7F800001), 0x7FC0)
        self.assertEqual(tr.fp32_to_bf16(0xFFC00001), 0xFFC0)
        self.assertEqual(tr.fp32_to_bf16(0x7F800000), 0x7F80)  # inf stays

    def test_wslot_low_half_r4_033(self):
        ref = tr.TileRef({}, 3)                 # fp8-bf16, 16-bit scales
        self.assertEqual(ref._wslot(0x3F00), 0x3F00)   # low, not << 16
        ref4 = tr.TileRef({}, 4)                # int4, BF16 scales
        self.assertEqual(ref4._wslot(0xBF80), 0xBF80)


if __name__ == '__main__':
    unittest.main()
