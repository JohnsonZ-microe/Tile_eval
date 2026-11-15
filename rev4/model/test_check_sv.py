"""Exercise the optional SV compiler gate with valid and invalid HDL."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).resolve().parents[1] / 'scripts/check_sv.py'

@unittest.skipUnless(importlib.util.find_spec('pyslang'), 'optional pyslang is not installed')
class SemanticCompilerGateTests(unittest.TestCase):
    def compile_source(self, source):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'tb').mkdir()
            (root / 'scripts/rtl.f').write_text('', encoding='utf-8')
            (root / 'tb/tb_tile_v4.sv').write_text(source, encoding='utf-8')
            shim = '''import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('checker', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.ROOT = pathlib.Path.cwd()
sys.argv = ['check_sv.py', '--worker', '--test', 'tile']
sys.exit(m.main())
'''
            return subprocess.run([sys.executable, '-B', '-c', shim, str(CHECKER)], cwd=root,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_valid_design_passes(self):
        result = self.compile_source('module tb_tile_v4; logic value; initial value = 0; endmodule')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_undeclared_reference_fails(self):
        result = self.compile_source('module tb_tile_v4; initial missing = 1; endmodule')
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_probe_declaration_order_fails(self):
        result = self.compile_source('module tb_tile_v4; initial value = 0; logic value; endmodule')
        self.assertNotEqual(result.returncode, 0, result.stdout)

if __name__ == '__main__':
    unittest.main()
