import random
import unittest
from vectors import latency, schedule, stimuli, transaction
from reference import fp_add, fp_mul, fp_shift, apply_scale, round_fp32, power2
import compact


class CompactTests(unittest.TestCase):
    def test_random_arithmetic(self):
        rng = random.Random(9917)
        for index in range(20000):
            left, right = rng.getrandbits(32), rng.getrandbits(32)
            self.assertEqual(compact.add(left,right),fp_add(left,right),('add',hex(left),hex(right)))
            self.assertEqual(compact.mul(left,right),fp_mul(left,right),('mul',hex(left),hex(right)))
            amount = rng.randrange(-254,255)
            self.assertEqual(compact.shift(left,amount),fp_shift(left,amount))
            fmt, scale = rng.randrange(6), rng.randrange(256)
            self.assertEqual(compact.scale(left,fmt,scale,right),apply_scale(left,fmt,scale,right))

    def test_cancellation_and_boundaries(self):
        values = [0,1,2,3,0x7fffff,0x800000,0x800001,0x3f800000,0x3f800001,0x7f7fffff,0x7f800000,0x7fc00000]
        values += [value | 0x80000000 for value in values]
        for left in values:
            for right in values:
                self.assertEqual(compact.add(left,right),fp_add(left,right))
                self.assertEqual(compact.mul(left,right),fp_mul(left,right))
        rng = random.Random(12)
        for index in range(3000):
            left = rng.randrange(0x7f800000)
            for offset in [-1,0,1]:
                right = max(0,min(0x7f7fffff,left+offset)) | 0x80000000
                self.assertEqual(compact.add(left,right),fp_add(left,right))

    def test_normalization_and_csa(self):
        rng = random.Random(144)
        for width,quantum in [(42,-18),(285,-142)]:
            mask = (1 << width)-1
            for index in range(1000):
                values = [rng.randrange(-(1 << (width-7)),1 << (width-7)) for _ in range(32)]
                total = sum(values)
                operands = [value & mask for value in values]
                while len(operands)>2:
                    reduced = []
                    for start in range(0,len(operands)-2,3):
                        first,second,third = operands[start:start+3]
                        reduced.extend([first^second^third,((first&second)|(first&third)|(second&third)) << 1 & mask])
                    reduced.extend(operands[len(operands)//3*3:])
                    operands = reduced
                self.assertEqual(sum(operands)&mask,total&mask)
                self.assertEqual(compact.rounded(total<0,abs(total),quantum),round_fp32(total*power2(quantum)))

    def test_protocol_schedule(self):
        samples,coverage = stimuli(817,'smoke')
        rows,rf,stats = schedule(samples)
        self.assertEqual(latency(),35)
        self.assertGreaterEqual(stats['longest_accept_run'],40)
        self.assertGreater(stats['stalls'],0)
        for index,(sample,expected) in enumerate(rows[:-1]):
            if sample['rst'] and sample['valid'] and not expected['ready']:
                self.assertEqual(sample,rows[index+1][0])
        self.assertEqual(rows[-1][1]['busy'],0)


if __name__ == '__main__':
    unittest.main()
