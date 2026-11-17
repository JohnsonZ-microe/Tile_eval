"""Compare external-only conditional retirement predictions against RTL."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from calibration_stimulus import extract
from retirement_prediction import predict
from y_control_replay import YControlReplay
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
    predicted_commits=[(x['epoch'],x['cycle'],x['command']['bank'],x['command']['mask']) for x in prediction['commits']]
    actual_commits=[(r['epoch'],r['cycle'],r['bank'],int(r['payload'],16)) for r in rows if r['event']=='y_commit']
    model=YControlReplay();pending={x['cycle']:x for x in prediction['commits']};ready=[]
    for cycle in range(max(pending)+1000):
        item=pending.get(cycle)
        if item is not None and model.commit.state!='idle':raise ValueError('predicted commit collides with busy engine')
        e=model.tick(commit=item['command'] if item is not None else None)
        if e['commit']['set_applied'] is not None:ready.append((0,cycle,*e['commit']['set_applied']))
    actual_ready=[(r['epoch'],r['cycle'],r['bank'],r['transaction']) for r in rows if r['event']=='y_ready_visible']
    result=dict(run=run,passed=expected==actual and predicted_commits==actual_commits and ready==actual_ready,
                predicted_commits=predicted_commits,actual_commits=actual_commits,predicted_ready=ready,actual_ready=actual_ready,predicted_sync1=expected,actual_sync1=actual,
                prediction=prediction,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    results.append(result)
    print(json.dumps(dict(run=run,passed=result['passed'],predicted=len(expected),actual=len(actual),commits_match=predicted_commits==actual_commits,ready_match=ready==actual_ready,
                         first_mismatches=[(a,b) for a,b in zip(expected,actual) if a!=b][:3])),flush=True)
    del rows
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
