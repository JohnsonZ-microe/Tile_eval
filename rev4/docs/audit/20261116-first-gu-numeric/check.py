from pathlib import Path
import csv,sys,json,hashlib,random
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'NPU_eval/af')]
from phase_replay import run_phase
from trace_config_replay import decode_inputs
from gu_operand_data import select_gu_operands
from pe_error_prediction import classify
sys.path.insert(0,str(ROOT/'Tile_eval/rev4/model'))
import vectors
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
manifest=json.loads((path.parent/'manifest.json').read_text())
source='model/vectors.py'
blob=(ROOT/'Tile_eval/rev4'/source).read_bytes()
assert manifest['sources'][source] in (hashlib.sha256(blob).hexdigest(),hashlib.sha256(blob.replace(b'\r\n',b'\n')).hexdigest())
assert cfg['fmt']==0 and cfg['base']==64 and manifest['seed']==817
image={};ref=vectors.TileRef(image,0,True)
vectors.make_stream(random.Random(817),ref,64,160,ref.ng_gu,72)
classified=[]
for cycle,tag in pe:
 kb=(tag>>10)&255;group=(tag>>4)&63
 data=select_gu_operands(downs,pass_id=5,tokens=1,kb=kb)
 scale=image[64+kb*10]
 ws=sum(((scale>>(8*(group*8+c)))&255)<<(32*c) for c in range(8))
 error=classify(fmt=0,col_base=group*8,token_mask=1,weights=image[64+kb*10+1+group],wscales=ws,**data)
 classified.append(dict(cycle=cycle,tag=tag,kb=kb,error=error))
first=next(x for x in classified if x['error'])
candidate=dict(accept=first['cycle'],kb=first['kb'],alarm_sample=first['cycle']+38)
assert candidate['alarm_sample']==107486
result=dict(pe_accepts_matched=len(pe),candidate=candidate,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),classified=classified,scope='first GU only; weights regenerated from matching seed/generator, remote rram.hex unavailable')
(Path(__file__).parent/'checks.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
