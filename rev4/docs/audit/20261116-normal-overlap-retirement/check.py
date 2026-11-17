"""Compare external-only conditional retirement predictions against RTL."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from calibration_stimulus import extract
from retirement_prediction import predict
OUT=Path(__file__).parent
results=[]
for run in ('vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706'):
    path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
    rows=read_events(path)
    # No observed output is passed into predict(). Compare only afterwards.
    prediction=predict(extract(rows),assume_idle_context=True,assume_isolated_bus=True,
                       assume_idle_y_commit=True,initial_credit=6)
    expected=[(r['epoch'],r['cycle']+1) for r in prediction['retirements']]
    actual=[(r['epoch'],r['cycle']) for r in rows if r['event']=='sync1']
    result=dict(run=run,passed=expected==actual,predicted_sync1=expected,actual_sync1=actual,
                prediction=prediction,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    results.append(result)
    print(json.dumps(dict(run=run,passed=result['passed'],predicted=len(expected),actual=len(actual),
                         first_mismatches=[(a,b) for a,b in zip(expected,actual) if a!=b][:3])),flush=True)
    del rows
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
