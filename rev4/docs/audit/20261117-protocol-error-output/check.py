"""H/Y continuous replay with explicit next-edge credit-return assumption."""
from pathlib import Path
import sys,json,hashlib,csv
ROOT=Path(__file__).resolve().parents[5]
sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from alarm_control_output_replay import AlarmControlOutputReplay
from alarm_replay import AlarmReplay
OUT=Path(__file__).parent
capture_records=json.loads((OUT.parent/'20261116-gu-capture-inputs/checks.json').read_text())
numeric=json.loads((OUT.parent/'20261116-first-gu-numeric/checks.json').read_text())
committed_errors={x['cycle']+35:x['error'] for x in numeric['classified']}
reference_inputs=None
results=[]
for prediction in json.loads((OUT.parent/'20261116-d-commit-inputs/checks.json').read_text()):
 run=prediction['run'];path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 assert hashlib.sha256(path.read_bytes()).hexdigest()==prediction['trace_sha256']
 captures_record=next(x for x in capture_records if x['run']==run)
 assert captures_record['trace_sha256']==prediction['trace_sha256']
 captures={x['cycle']:(x['tokens'],x['pass_id']) for x in captures_record['prediction']}
 credits={};downs={};actual=[];actual_ready=[];actual_drains=[];actual_alarm=[]
 with path.open() as f:
  for r in csv.DictReader(f):
   c=int(r['cycle'])
   if r['event']=='credit':credits[c]=int(r['payload'],16)
   if r['event']=='down':downs[c]=(int(r['payload'],16),int(r['transaction']))
   if r['event']=='up_beat':
    actual.append((c,int(r['transaction'])))
    if int(r['transaction'])&3==2:actual_alarm.append((c,int(r['payload'],16)))
   if r['event']=='y_ready_visible':actual_ready.append((c,int(r['bank']),int(r['transaction'])))
   if r['event']=='drain_accept':actual_drains.append((c,int(r['bank']),int(r['transaction']),int(r['payload'],16)))
 relevant=[(c,p,s) for c,(p,s) in downs.items() if (s&7 in (1,2) and (s>>3)&255==5) or (s&7==0 and (s>>3)&255==5 and p&3==0)]
 if reference_inputs is None:reference_inputs=relevant
 else:assert relevant==reference_inputs
 commits={x['cycle']:x['command'] for x in prediction['prediction']['commits']}
 model=AlarmControlOutputReplay(lambda address: (_ for _ in ()).throw(ValueError("unmodeled register read")));credit=0;beats=[];ready=[];drains=[];retired=[];contention=0;sticky=previous=0;alarm_beats=[]
 for c in range(max(downs)+2000):
  h=model.output.output.output.uplink.epilogue
  contention+=int(h is not None and h.state=='hup' and model.output.output.output.y.drain.valid)
  payload,sb=downs.get(c,(0,0))
  new=sticky & ~previous;previous=sticky;sticky|=committed_errors.get(c,0)
  e=model.tick(valid=c in downs,payload=payload,sideband=sb,commit=commits.get(c),capture=captures.get(c),up_credit=credits.get(c,0),events=((new&1)<<18)|(((new>>1)&1)<<2),first_pass=5)
  credit=int(e['bus_post']['up_valid'])
  if credit and e['bus_post']['up_sideband']&3==2:alarm_beats.append((c+1,e['bus_post']['up_payload']))
  if e['retired_pass'] is not None:retired.append((c,e['retired_pass']))
  assert not e['bus_post']['up_credit_err'] and not e['y']['drain']['illegal']
  if credit:beats.append((c+1,e['bus_post']['up_sideband']))
  if e['y']['commit']['set_applied'] is not None:ready.append((c,*e['y']['commit']['set_applied']))
  if e['drain_command'] is not None:
   d=e['drain_command'];drains.append((c,d['bank'],d['slot'],d['start']<<8|d['count']))
 expected_retired=[(x['cycle'],x['pass_id']) for x in prediction['prediction']['retirements'] if x['phase']==0]
 checks=dict(alarm_payload=alarm_beats==actual_alarm,gu_retirement=retired==expected_retired,beats=beats==actual,ready=ready==actual_ready,drains=drains==actual_drains,empty=not model.output.output.output.y.valid_slots)
 result=dict(final_modeled_errors=model.alarm.errors,h_y_contention_edges=contention,actual_credit_errors=0,alarm_match=alarm_beats==actual_alarm,predicted_alarm=alarm_beats,actual_alarm=actual_alarm,run=run,passed=all(checks.values()),checks=checks,predicted_beats=beats,actual_beats=actual,predicted_gu_retirement=retired,predicted_ready=ready,actual_ready=actual_ready,trace_sha256=prediction['trace_sha256'],assumptions='Actual external credits; first GU PE numeric events and pass 5 identity only; raw protocol/CTRL/credit errors and W1C/mask modeled; scheduler CMD errors still absent; upstream core/commit timing remains conditional; H/Y payloads not checked')
 results.append(result)
 print(json.dumps(dict(run=run,checks=checks,final_errors=hex(model.alarm.errors),contention=contention,beats=len(beats),ready=len(ready),drains=len(drains))),flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
