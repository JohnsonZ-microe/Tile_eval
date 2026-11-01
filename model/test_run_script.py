import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
if not BASH and Path('C:/Program Files/Git/bin/bash.exe').exists():
    BASH = 'C:/Program Files/Git/bin/bash.exe'


@unittest.skipUnless(BASH, 'Bash unavailable; shell argument tests skipped')
class RunScriptTests(unittest.TestCase):
    def test_optional_arguments_without_empty_arrays(self):
        source = (ROOT / 'scripts/run_vcs.sh').read_text(encoding='utf-8')
        loop = source[source.index('for target in math array; do'):]
        harness = '''set -euo pipefail
timeout() {
    local kind=run log_file=""
    if [[ "$2" == "$VCS" ]]; then kind=compile; fi
    printf '%s\\n' "$@" > "$RESULTS/args_${target}_${kind}.txt"
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -l ]]; then shift; log_file="$1"; fi
        shift
    done
    printf 'PASS %s\\n' "$target" > "$log_file"
}
'''
        for waves, fsdb in [('0', False), ('1', False), ('0', True), ('1', True)]:
            with self.subTest(waves=waves, fsdb=fsdb), tempfile.TemporaryDirectory(prefix='pe script ') as directory:
                output = Path(directory)
                environment = os.environ.copy()
                for key in ('FSDB_PLI_TAB', 'FSDB_PLI_LIB'):
                    environment.pop(key, None)
                environment.update(ROOT='/source with spaces', RESULTS=output.as_posix(),
                                   VCS='/tool with spaces/vcs', WAVES=waves, TEST='all', TIMEOUT_SECONDS='30')
                if fsdb:
                    environment.update(FSDB_PLI_TAB='/plugin path/novas.tab', FSDB_PLI_LIB='/plugin path/pli.a')
                result = subprocess.run([BASH, '-c', harness + loop], env=environment,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        universal_newlines=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for target in ('math', 'array'):
                    compile_args = (output / f'args_{target}_compile.txt').read_text().splitlines()
                    run_args = (output / f'args_{target}_run.txt').read_text().splitlines()
                    self.assertNotIn('', compile_args + run_args)
                    self.assertIn('/tool with spaces/vcs', compile_args)
                    self.assertEqual(any(arg.startswith('+VCD=') for arg in run_args), waves == '1' and target == 'array')
                    self.assertEqual(any(arg.startswith('+FSDB=') for arg in run_args), fsdb and target == 'array')
                    if fsdb:
                        self.assertIn('/plugin path/novas.tab', compile_args)
                        self.assertIn('/plugin path/pli.a', compile_args)


if __name__ == '__main__':
    unittest.main()
