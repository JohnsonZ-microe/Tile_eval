"""Measured event intervals, not inferred stall causes or application throughput."""
from pathlib import Path
from collections import defaultdict
import csv,json,hashlib
ROOT=Path(__file__).resolve().parents[5]
OUT=Path(__file__).parent
runs=['vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706']
results=[]
for run in runs:
 path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 prediction=next(x for x in json.loads((OUT.parent/'20261116-normal-overlap-retirement/checks.json').read_text()) if x['run']==run)
 assert prediction['trace_sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
 events=defaultdict(lambda:defaultdict(list)); commands=defaultdict(list); sync=[];last_output=None
 with path.open() as f:
  for r in csv.DictReader(f):
   cycle=int(r['cycle']);key=(int(r['epoch']),int(r['pass']),int(r['phase']))
   if r['event'] in ('memory_issue','memory_consume','pe_accept'):events[key][r['event']].append(cycle)
   if r['event']=='down' and int(r['transaction'])&7==0:
    commands[(int(r['epoch']),(int(r['transaction'])>>3)&255,int(r['payload'],16)&3)].append(cycle)
   if r['event']=='sync1':sync.append(cycle)
   if r['event']=='up_beat':last_output=cycle
 assert sync==[x['sync1_sampled'] for x in prediction['prediction']['cases']]
 phases=[]
 for case in prediction['prediction']['cases']:
  cfg=case['config']; key=(cfg['epoch'],cfg['pass'],cfg['phase'])
  assert len(commands[key])==1
  cmd=commands[key][0];e=events[key];issues=e['memory_issue'];pe=e['pe_accept']
  assert issues and pe and issues==sorted(set(issues))
  end=case['sync1_sampled'];first=issues[0];last=pe[-1]
  assert cmd<=first<=last<end
  phases.append(dict(epoch=key[0],pass_id=key[1],phase=key[2],fmt=cfg['fmt'],command=cmd,first_issue=first,last_pe_accept=last,sync1=end,
   command_to_issue=first-cmd,issue_to_last_pe=last-first,last_pe_to_sync=end-last,total=end-cmd,
   issue_count=len(issues),issue_window=issues[-1]-first+1,issue_utilization=len(issues)/(issues[-1]-first+1)))
 first=min(x['command'] for x in phases)
 results.append(dict(run=run,trace_sha256=prediction['trace_sha256'],phases=phases,first_command=first,last_sync=sync[-1],last_output=last_output,
  command_to_last_sync=sync[-1]-first,command_to_last_output=last_output-first))
a,b=results
assert [(x['pass_id'],x['phase'],x['fmt'],x['issue_count']) for x in a['phases']]==[(x['pass_id'],x['phase'],x['fmt'],x['issue_count']) for x in b['phases']]
deltas=[dict(pass_id=x['pass_id'],phase=x['phase'],fmt=x['fmt'],**{k:x[k]-y[k] for k in ('command_to_issue','issue_to_last_pe','last_pe_to_sync','total')}) for x,y in zip(a['phases'],b['phases'])]
result=dict(runs=results,normal_minus_overlap=deltas,scope='Measured testbench cycles; interval boundaries, not causal stall classification; not application throughput, energy or area')
(OUT/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(windows=[{k:v for k,v in x.items() if k!='phases'} for x in results],summed_phase_savings={k:sum(x[k] for x in deltas) for k in ('command_to_issue','issue_to_last_pe','last_pe_to_sync','total')},deltas=deltas),indent=2))
