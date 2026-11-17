from pathlib import Path
import sys,json,hashlib
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'NPU_eval/af'),str(ROOT/'Tile_eval/rev4/model')]
from calibration_compare import read_events
from calibration_stimulus import extract
from gu_capture_prediction import predict_gu_captures
results=[]
for run in ('vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706'):
 path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 rows=read_events(path)
 prediction=predict_gu_captures(extract(rows),assume_idle_context=True,assume_uncontended_core=True)
 expected=[r['cycle']+1 for r in prediction]
 actual=[r['cycle'] for r in rows if r['event']=='act_accept' and r['transaction']==0]
 result=dict(run=run,passed=expected==actual,prediction=prediction,predicted_act_start=expected,actual_act_start=actual,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
 results.append(result)
 print(json.dumps(dict(run=run,passed=result['passed'],predicted=len(expected),actual=len(actual))),flush=True)
 del rows
(Path(__file__).parent/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
