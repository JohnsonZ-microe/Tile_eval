import unittest
from calibration_stimulus import extract
from test_calibration_compare import event


def reset(epoch=0):
    return event(epoch=epoch, cycle=0, event='reset', payload='0'*128)


def down(**changes):
    fields = dict(cycle=2, event='down', transaction=9, **{'pass': 1})
    fields.update(changes)
    return event(**fields)


class CalibrationStimulusTests(unittest.TestCase):
    def test_outputs_never_feed_inputs(self):
        base = [reset(), down()]
        observations = [event(cycle=3), event(cycle=4, event='up_beat', payload='f'*128)]
        self.assertEqual(extract(base), extract(base + observations))
        observations[0]['cycle'] = 99999
        observations[1]['payload'] = 'a'*128
        self.assertEqual(extract(base), extract(base + observations))

    def test_edges_payload_and_credit_preserved(self):
        credit = event(cycle=2, event='credit', payload=format(3, '0128x'))
        rows = extract([reset(), credit, down(payload='f'*128), down(cycle=9)])
        self.assertEqual([r['cycle'] for r in rows], [0, 2, 2, 9])
        self.assertEqual(rows[1]['payload'], 'f'*128)
        self.assertEqual(rows[1]['sideband'], 9)
        self.assertEqual(rows[2]['value'], 3)
        self.assertEqual(rows, extract([reset(), down(payload='f'*128), credit, down(cycle=9)]))

    def test_new_epoch_requires_reset(self):
        self.assertEqual(len(extract([reset(), down(), reset(1), down(epoch=1)])), 4)
        with self.assertRaises(ValueError):
            extract([reset(), down(), down(epoch=1)])

    def test_invalid_inputs_fail(self):
        cases = [[down()], [reset()], [reset(), down(), down()],
                 [reset(), down(sample='post')], [reset(), down(transaction=-1)],
                 [reset(), down(transaction=1 << 32)], [reset(), down(**{'pass': 2})],
                 [reset(), down(), reset()],
                 [reset(), down(), event(cycle=3, event='credit')],
                 [reset(), down(), event(cycle=3, event='credit', payload=format(4, '0128x'))]]
        for rows in cases:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                extract(rows)
