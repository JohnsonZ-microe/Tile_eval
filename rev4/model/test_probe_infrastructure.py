import tempfile
import unittest
from pathlib import Path

from trace_compare import compare, read_events
from vector_check import math_rows


class ProbeInfrastructureTests(unittest.TestCase):
    def test_bad_math_vectors_fail(self):
        bad = ['', 'FM 0 0', 'FM 0 0 0 junk', 'SG 10000 0',
               'QU x 0 0', 'UNKNOWN 0', 'AC 0 0 0 0 0']
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'vectors.txt'
            for payload in bad:
                path.write_text(payload)
                with self.subTest(payload=payload), self.assertRaises(ValueError):
                    math_rows(path)
            path.write_text('FM 0 0 0\nSG c2ca a\nQU 0 0 69\n')
            self.assertEqual(math_rows(path), 3)

    def test_trace_does_not_ignore_missing_duplicate_or_latency(self):
        expected = [dict(cycle=3, event='pe_commit', transaction=0, value=8)]
        self.assertEqual(compare(expected, expected)['status'], 'passed')
        for actual in ([], expected*2, [dict(expected[0], cycle=4)],
                       [dict(expected[0], transaction=1)],
                       expected + [dict(cycle=4,event='unexpected',transaction=0,value=0)]):
            self.assertEqual(compare(expected, actual)['status'], 'failed')

    def test_trace_requires_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trace.csv'
            path.write_text('cycle,event,transaction,value\n')
            with self.assertRaises(ValueError):
                read_events(path)


if __name__ == '__main__':
    unittest.main()
