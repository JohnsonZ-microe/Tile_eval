import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('summarize_dc',str(ROOT/'scripts/summarize_dc.py'))
reporting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporting)


class ReportingTests(unittest.TestCase):
    def check_report(self,setup,hold):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder/'qor.rpt').write_text(
                'Critical Path Slack: 0.00\nWorst Hold Violation: 0.00\n'
                'No. of Violating Paths: %s\nNo. of Hold Violations: %s\n' % (setup,hold))
            (folder/'timing_setup.rpt').write_text('Startpoint: input\nEndpoint: output\n')
            return reporting.summarize(folder)

    def test_rounded_zero_with_violations_fails(self):
        self.assertEqual(self.check_report(1,0)['slack_status'],'FAIL')
        self.assertEqual(self.check_report(0,1)['slack_status'],'FAIL')

    def test_missing_counts_are_unknown(self):
        self.assertEqual(self.check_report('N/A',0)['slack_status'],'unknown')
        self.assertEqual(self.check_report(0,0)['slack_status'],'no_reported_violations')


if __name__ == '__main__':
    unittest.main()
