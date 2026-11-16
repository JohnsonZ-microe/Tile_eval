"""Composed H path replay; ownership pulses remain observed inputs."""
from pathlib import Path
import hashlib
import json
import sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from h_path_trace_replay import replay
OUT=Path(__file__).parent
results=[]
for run in ('vcs-20261115T151442Z-8320','vcs-20261115T221329Z-18837'):
    path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
    rows=read_events(path)
    result=replay(rows)
    result.update(run=run,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    results.append(result)
    print(json.dumps(dict(run=run,status=result['status'],accepted=result['accepted_writes'],
                         ready_edges=len(result['ready_edges']),mismatches=len(result['mismatches']),
                         canceled=result['canceled'],route_rejections=result['route_rejections'])),flush=True)
    del rows
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
sources=['h_path_replay.py','h_path_trace_replay.py','h_quant_routing.py','hbank_ownership.py',
         'quant_write_guard.py','tests/test_h_path_replay.py']
(OUT/'model-sources.json').write_text(json.dumps({s:hashlib.sha256((ROOT/'NPU_eval/af'/s).read_bytes()).hexdigest()
                                                for s in sources},indent=2)+'\n',encoding='utf-8')
raise SystemExit(0 if all(r['status']=='passed' for r in results) else 1)
