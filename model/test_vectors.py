from pathlib import Path
import tempfile
import unittest

from generate_vectors import build_cycles, write_array_vectors


class VectorTests(unittest.TestCase):
    def test_reproducible_and_format_coverage(self):
        cycles, coverage = build_cycles(817, 'full')
        self.assertEqual(cycles, build_cycles(817, 'full')[0])
        for fmt in range(6):
            for tokens in range(1, 5):
                self.assertIn(f'format_{fmt}_tokens_{tokens}', coverage)
            for dimension in (5120, 2304):
                self.assertIn(f'format_{fmt}_K_{dimension}', coverage)
        self.assertEqual(len({sample['tag'] for sample in cycles}), len(cycles))
        for sample in cycles:
            self.assertLess(sample['weights'], 1 << 1024)
            self.assertLess(sample['activations'], 1 << 1024)

    def test_scoreboard_reset_and_latency(self):
        cycles, _ = build_cycles(41, 'smoke')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            count = write_array_vectors(output, cycles)
            rows = [[int(field, 16) for field in line.split()] for line in (output / 'array.txt').read_text().splitlines()]
            pending = {}
            seen = 0
            sticky = 0
            for cycle, row in enumerate(rows):
                self.assertEqual(len(row), 22)
                rst, valid = row[:2]
                if not rst:
                    pending.clear()
                    sticky = 0
                if row[12]:
                    self.assertEqual(pending.pop(cycle), row[14])
                    sticky |= row[18]
                    seen += 1
                if rst and valid:
                    pending[cycle + 4] = row[11]
                self.assertEqual(row[19], sticky)
                self.assertEqual(row[21], int(bool(pending)))
            self.assertEqual(seen, count)
            self.assertFalse(pending)
            self.assertEqual(len((output / 'rf.txt').read_text().splitlines()), 320)


if __name__ == '__main__':
    unittest.main()
