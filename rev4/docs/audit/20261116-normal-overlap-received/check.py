"""Audit received runs without modifying their logs or manifests."""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[5]
REV = ROOT / 'Tile_eval/rev4'
OUT = Path(__file__).parent
sys.path[:0] = [str(REV/'model'), str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from hbank_trace_replay import replay as hbank_replay
from quant_guard_trace_replay import replay as guard_replay

RUNS = ['vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706']

def sha(data):
    return hashlib.sha256(data).hexdigest()

results = []
for name in RUNS:
    directory = ROOT/'Tile_eval/logs'/name
    manifest = json.loads((directory/'manifest.json').read_text(encoding='utf-8'))
    test = manifest['test']
    files = ['scripts/rtl.f', 'scripts/run.py', 'tb/tb_'+test+'_v4.sv']
    files += [s.strip() for s in (REV/'scripts/rtl.f').read_text().splitlines()
              if s.strip() and not s.lstrip().startswith('#')]
    matches = []
    for file in files:
        data = (REV/file).read_bytes()
        snapshot_name = 'rtl/rev3_' + Path(file).name if file.startswith('../rev3/rtl/') else file
        recorded = manifest['sources'].get(snapshot_name)
        matches.append(dict(file=file, recorded=recorded, raw=sha(data),
                            normalized_lf=sha(data.replace(b'\r\n', b'\n')),
                            matches=recorded in (sha(data), sha(data.replace(b'\r\n', b'\n')))))
    logpath = directory/('run_'+test+'.log')
    log = logpath.read_text(encoding='utf-8') if logpath.exists() else ''
    record = dict(run=name, test=test, status=manifest['rtl_validation'],
                  exit_code=(directory/'exit_code.txt').read_text().strip(),
                  simulation_command=manifest['commands'][-1],
                  sources=matches, mismatch_files=[x['file'] for x in matches if not x['matches']],
                  markers=[line for line in log.splitlines() if line.startswith(('CHECK ', 'PASS ', 'Fatal:', 'FAIL '))],
                  artifacts={p.name:dict(bytes=p.stat().st_size, sha256=sha(p.read_bytes()))
                             for p in directory.iterdir() if p.is_file() and p.name != '.sync.json'})
    if name in RUNS[:4] and test == 'tile':
        trace = read_events(directory/'calibration-events.csv')
        for label, replay in [('hbank', hbank_replay), ('quant_guard', guard_replay)]:
            try:
                record[label] = replay(trace)
            except ValueError as error:
                record[label] = dict(status='failed', reason=str(error))
        del trace
    results.append(record)
    print(json.dumps({k:v for k,v in record.items() if k in
                      ('run','status','mismatch_files','hbank','quant_guard')}, ensure_ascii=False), flush=True)
(OUT/'checks.json').write_text(json.dumps(results, indent=2)+'\n', encoding='utf-8')
