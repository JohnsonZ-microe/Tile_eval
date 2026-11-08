import re
import unittest
from pathlib import Path


class YaccWatchdogSourceTests(unittest.TestCase):
    def test_commit_wait_counter_resets_on_each_entry(self):
        source = (Path(__file__).resolve().parents[1] /
                  'tb/tb_yacc_v4.sv').read_text()
        self.assertRegex(source, r'integer waited;\s+waited = 0;\s+'
                         r'while \(commit_busy !== 0\)')
        self.assertNotRegex(source, r'integer waited\s*=')
        self.assertIn('if (waited > 10000)', source)
        self.assertIn('tick(); waited++;', source)
        for field in ('bank', 'group', 'part', 'waited', 'cycles',
                      'state', 'lane', 'row', 'mask', 'addb_vo', 'add_vo'):
            self.assertIn(field + '=%', source)
        self.assertIn('if (packets != 128)', source)


if __name__ == '__main__':
    unittest.main()
