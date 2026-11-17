"""Y-only continuous replay with explicit next-edge credit-return assumption."""
from pathlib import Path
import sys,json,hashlib,csv
ROOT=Path(__file__).resolve().parents[5]
sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from drain_driven_output_replay import DrainDrivenOutputReplay
OUT=Path(__file__).parent
results=[]
for prediction in json.loads((OUT.parent/'20261116-d-commit-inputs/checks.json').read_text()):
 run=prediction['run'];path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 assert hashlib.sha256(path.read_bytes()).hexdigest()==prediction['trace_sha256']
 downs={};actual=[];actual_ready=[];actual_drains=[]
 with path.open() as f:
  for r in csv.DictReader(f):
   c=int(r['cycle'])
   if r['event']=='down':downs[c]=(int(r['payload'],16),int(r['transaction']))
   if r['event']=='up_beat' and int(r['transaction'])&3==1:actual.append((c,int(r['transaction'])))
   if r['event']=='y_ready_visible':actual_ready.append((c,int(r['bank']),int(r['transaction'])))
   if r['event']=='drain_accept':actual_drains.append((c,int(r['bank']),int(r['transaction']),int(r['payload'],16)))
 commits={x['cycle']:x['command'] for x in prediction['prediction']['commits']}
 model=DrainDrivenOutputReplay();credit=0;beats=[];ready=[];drains=[]
 for c in range(max(downs)+2000):
  payload,sb=downs.get(c,(0,0))
  e=model.tick(valid=c in downs,payload=payload,sideband=sb,commit=commits.get(c),up_credit=credit)
  credit=int(e['bus_post']['up_valid'])
  assert not e['bus_post']['up_credit_err'] and not e['y']['drain']['illegal']
  if credit:beats.append((c+1,e['bus_post']['up_sideband']))
  if e['y']['commit']['set_applied'] is not None:ready.append((c,*e['y']['commit']['set_applied']))
  if e['drain_command'] is not None:
   d=e['drain_command'];drains.append((c,d['bank'],d['slot'],d['start']<<8|d['count']))
 checks=dict(beats=beats==actual,ready=ready==actual_ready,drains=drains==actual_drains,empty=not model.output.y.valid_slots)
 result=dict(run=run,passed=all(checks.values()),checks=checks,predicted_beats=beats,actual_beats=actual,predicted_ready=ready,actual_ready=actual_ready,trace_sha256=prediction['trace_sha256'],assumptions='Y-only bus, six initial credits, one credit returned next edge per transmitted beat; upstream commit prediction retains isolated phase assumptions; no numeric payload checking')
 results.append(result)
 print(json.dumps(dict(run=run,checks=checks,beats=len(beats),ready=len(ready),drains=len(drains))),flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
