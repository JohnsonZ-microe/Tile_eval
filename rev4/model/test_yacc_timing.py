import unittest
from tile_cycles import yacc_commit_schedule


class YaccCommitTimingTests(unittest.TestCase):
    def test_observed_sparse_mask_1010(self):
        # First transaction in the 20261114 VCS waveform, absolute edges.
        result = yacc_commit_schedule(10, 14)
        self.assertEqual([r['cycle'] for r in result['row_reads']],
                         [16,38,60,82,104,126,148,170,192,214,
                          237,259,281,303,325,347,369,391,413,435])
        self.assertEqual(result['publications'], [236,457])
        self.assertEqual(result['idle_visible'], 457)
        self.assertEqual(result['writes'][-1], 457)

    def test_observed_trailing_mask_0101(self):
        result = yacc_commit_schedule(5, 689)
        self.assertEqual(result['publications'], [910,1131])
        self.assertEqual(result['idle_visible'], 1132)
        self.assertEqual(result['row_reads'][10], dict(cycle=911,lane=2,row=0))

    def test_observed_single_lane_commits(self):
        for mask, publication in ((1,221), (2,222)):
            result = yacc_commit_schedule(mask)
            self.assertEqual(result['publications'], [publication])
            self.assertEqual(result['idle_visible'], 224)

    def test_empty_mask_scans_all_lanes(self):
        result = yacc_commit_schedule(0)
        self.assertEqual(result['writes'], [])
        self.assertEqual(result['publications'], [])
        self.assertEqual(result['idle_visible'], 5)

    def test_full_mask_follows_rtl_sequencer(self):
        # RTL-derived expectation; this mask is NOT covered by supplied VCD.
        result = yacc_commit_schedule(15)
        self.assertEqual(result['publications'], [221,441,661,881])
        self.assertEqual(result['idle_visible'], 881)

    def test_invalid_mask(self):
        for mask in (-1,16,1.5):
            with self.assertRaises(ValueError):
                yacc_commit_schedule(mask)


if __name__ == '__main__':
    unittest.main()
