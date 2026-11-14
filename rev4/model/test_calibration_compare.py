import copy
import csv
import tempfile
import unittest
from pathlib import Path

from calibration_compare import FIELDS, compare, read_events


def event(**changes):
    row = dict(epoch=0, cycle=3, sample='pre', event='memory_issue',
               transaction=0, **{'pass': 1}, phase=0, slot=0, kb=0,
               group=0, bank=-1, payload='0' * 128)
    row.update(changes)
    return row


class CalibrationCompareTests(unittest.TestCase):
    def read(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.csv'
            with path.open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=FIELDS)
                writer.writeheader()
                writer.writerows(rows)
            return read_events(path)

    def test_all_identity_fields_are_compared(self):
        expected = [event()]
        for field in FIELDS:
            with self.subTest(field=field):
                actual = copy.deepcopy(expected)
                actual[0][field] = {'event': 'memory_return', 'sample': 'post',
                                    'payload': '1' * 128}.get(field, 99)
                self.assertEqual(compare(expected, actual)['status'], 'failed')

    def test_same_sample_independent_channels(self):
        rows = [event(), event(event='credit')]
        self.assertEqual(compare(rows, list(reversed(rows)))['status'], 'passed')

    def test_missing_duplicate_extra_and_reordered_events(self):
        rows = [event(), event(cycle=4, transaction=1)]
        for actual in (rows[:1], rows + rows[-1:], rows + [event(event='credit')], list(reversed(rows))):
            self.assertEqual(compare(rows, actual)['status'], 'failed')

    def test_no_empty_or_required_channel_false_pass(self):
        self.assertEqual(compare([], [])['status'], 'failed')
        self.assertEqual(compare([event()], [event()], ['sync1'])['status'], 'failed')

    def test_reset_allows_new_epoch_cycle_zero(self):
        rows = [event(cycle=100), event(epoch=1, cycle=0, event='reset')]
        self.assertEqual(self.read(rows), rows)

    def test_invalid_trace_rejected(self):
        for rows in ([], [event(cycle=-1)], [event(transaction=-2)],
                     [event(payload='x' * 128)], [event(payload='z' * 128)],
                     [event(payload='0')], [event(sample='unknown')],
                     [event(), event(cycle=2)],
                     [event(sample='post'), event()],
                     [event(epoch=1), event(epoch=0, cycle=5)]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.read(rows)

    def test_hex_case_is_not_a_value_difference(self):
        self.assertEqual(self.read([event(payload='A'*128)])[0]['payload'], 'a'*128)


if __name__ == '__main__':
    unittest.main()
