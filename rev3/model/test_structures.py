import random
import re
import unittest
from pathlib import Path
from structures import cpa, multiply24, signed_sum
from vectors import latency, schedule, stimuli


class StructureTests(unittest.TestCase):
    def test_segmented_cpa(self):
        rng = random.Random(31029)
        for width in [1,31,32,33,42,48,64,285]:
            mask = (1 << width)-1
            pairs = [(0,0),(mask,1),(mask,mask),(1 << (width-1),1 << (width-1))]
            pairs += [((1 << boundary)-1,1) for boundary in range(1,width)]
            pairs += [(rng.getrandbits(width),rng.getrandbits(width)) for _ in range(2000)]
            for left,right in pairs:
                self.assertEqual(cpa(left,right,width),(left+right)&mask)

    def test_partial_products(self):
        rng = random.Random(31030)
        values = [0,1,4095,4096,4097,0x7fffff,0x800000,0xffffff]
        pairs = [(left,right) for left in values for right in values]
        pairs += [(rng.getrandbits(24),rng.getrandbits(24)) for _ in range(10000)]
        for left,right in pairs:
            self.assertEqual(multiply24(left,right),left*right)

    def test_signed_correction_and_absolute(self):
        rng = random.Random(31031)
        for width in [42,285]:
            mask = (1 << width)-1
            for iteration in range(2000):
                magnitudes = [rng.getrandbits(width-7) for _ in range(32)]
                signs = [rng.randrange(2) for _ in range(32)]
                if iteration < 33:
                    signs = [int(index < iteration) for index in range(32)]
                if iteration == 0:
                    magnitudes = [0]*32
                    signs = [1]*32
                total = sum(-value if sign else value for value,sign in zip(magnitudes,signs))
                encoded = signed_sum(magnitudes,signs,width)
                self.assertEqual(encoded,total & mask)
                magnitude = cpa(encoded ^ mask,1,width) if encoded >> (width-1) else encoded
                self.assertEqual(magnitude,abs(total))

    def test_latency_contract_and_sources(self):
        root = Path(__file__).resolve().parents[1]
        package = (root/'rtl/pe3_pkg.sv').read_text()
        constants = {name:int(value) for name,value in re.findall(r'localparam int (\w+) = (\d+);',package)}
        self.assertEqual(constants['SCALE_STAGES'],constants['SHIFT_STAGES']+constants['MUL_STAGES'])
        self.assertEqual(constants['ADD_STAGES'],constants['RF_READ_STAGES']+constants['FPADD_STAGES'])
        self.assertEqual(constants['DOT_STAGES'],9+constants['ROUND_STAGES'])
        self.assertEqual(latency(),35)
        for path in (root/'tb').glob('*.sv'):
            self.assertRegex(path.read_text(),r'^module \w+;\s*timeunit 1ns;\s*timeprecision 1ps;')
        samples,_ = stimuli(2026,'smoke')
        rows,_,stats = schedule(samples)
        self.assertGreaterEqual(stats['longest_accept_run'],40)
        pending = set()
        canceled = 0
        for sample,expected in rows:
            if not sample['rst']:
                canceled += len(pending)
                pending.clear()
            else:
                if expected['valid']:
                    self.assertIn(expected['tag'],pending)
                    pending.remove(expected['tag'])
                if sample['valid'] and expected['ready']:
                    self.assertNotIn(sample['tag'],pending)
                    pending.add(sample['tag'])
        self.assertFalse(pending)
        self.assertGreaterEqual(canceled,latency())
        self.assertEqual(stats['accepts']-stats['commits'],canceled)
        self.assertFalse(rows[-1][1]['busy'])


if __name__ == '__main__':
    unittest.main()
