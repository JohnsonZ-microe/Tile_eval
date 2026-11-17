from pathlib import Path
import csv,sys,json,hashlib
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'NPU_eval/af')]
from phase_replay import run_phase
from trace_config_replay import decode_inputs
from gu_operand_data import select_gu_operands
raw=[dict(event='reset',epoch=0,cycle=0)];actual=[]
path=ROOT/'Tile_eval/logs/vcs-20261116T004029Z-67940/calibration-events.csv'
with path.open() as f:
 for r in csv.DictReader(f):
  if r['event']=='down':raw.append(dict(event='down',epoch=int(r['epoch']),cycle=int(r['cycle']),sideband=int(r['transaction']),payload=r['payload']))
  if r['event']=='pe_accept' and int(r['pass'])==5 and int(r['phase'])==0:actual.append((int(r['cycle']),int(r['transaction'])))
cfg=decode_inputs(raw,assume_idle_context_writes=True)['configurations'][0]
downs=raw[1:];cmd=next(r for r in downs if r['sideband']&7==0);origin=cmd['cycle']+1
incoming=[r for r in downs if r['sideband']&7 in (1,2) and (r['sideband']>>3)&255==5]
core=run_phase(cfg['fmt'],0,mask=1,bias=cfg['bias'],ingress_arrivals=[r['cycle']-origin for r in incoming],capture_events=True)
pe=[(r['cycle']+origin,r['transaction']|(5<<19)) for r in core['events'] if r['event']=='pe_accept']
assert pe==actual, (pe[:2],actual[:2])
candidate=None
for cycle,tag in pe:
 kb=(tag>>10)&255;d=select_gu_operands(downs,pass_id=5,tokens=1,kb=kb)
 if d['ascales']==255 or any(((d['activations']>>(8*i))&127)==127 for i in range(32)):
  candidate=dict(accept=cycle,kb=kb,tag=tag,alarm_sample_if_no_earlier_error=cycle+38);break
result=dict(pe_accepts_matched=len(pe),candidate=candidate,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),scope='activation/XS candidate only; weights not reconstructed')
(Path(__file__).parent/'checks.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
