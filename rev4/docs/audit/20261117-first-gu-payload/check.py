"""First GU raw-input numeric replay using the existing scoreboard oracle."""
from pathlib import Path
import csv,json,hashlib,sys,random
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'NPU_eval/af'),str(ROOT/'Tile_eval/rev4/model')]
from trace_config_replay import decode_inputs
from gu_operand_data import select_gu_operands
import vectors
OUT=Path(__file__).parent
results=[]
for run in ('vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706'):
 path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 manifest=json.loads((path.parent/'manifest.json').read_text())
 for key,file in [('model/vectors.py','Tile_eval/rev4/model/vectors.py'),('model/tile_reference.py','Tile_eval/rev4/model/tile_reference.py'),('oracle/reference.py','Tile_eval/model/reference.py')]:
  b=(ROOT/file).read_bytes()
  assert manifest['sources'][key] in (hashlib.sha256(b).hexdigest(),hashlib.sha256(b.replace(b'\r\n',b'\n')).hexdigest()),key
 raw=[dict(event='reset',epoch=0,cycle=0)];actual=[]
 with path.open() as f:
  for r in csv.DictReader(f):
   if r['event']=='down':raw.append(dict(event='down',epoch=int(r['epoch']),cycle=int(r['cycle']),sideband=int(r['transaction']),payload=r['payload']))
   if r['event']=='up_beat':
    sb=int(r['transaction'])
    if sb&3==0 and (sb>>9)&255==5:actual.append(dict(cycle=int(r['cycle']),sideband=sb,payload=int(r['payload'],16)))
 cfg=decode_inputs(raw,assume_idle_context_writes=True)['configurations'][0]
 assert cfg['fmt']==0 and cfg['base']==64 and cfg['bias']
 downs=raw[1:];cmdrow=next(r for r in downs if r['sideband']&7==0)
 pl=int(cmdrow['payload'],16)
 assert (cmdrow['sideband']>>3)&255==5 and (pl>>43)&7==1 and pl&3==0
 cmd=dict(base=64,n_tok=1,weights=[(pl>>(102+40*l))&0xffffffff for l in range(4)])
 image={};ref=vectors.TileRef(image,0,True);rng=random.Random(manifest['seed'])
 vectors.make_stream(rng,ref,64,160,ref.ng_gu,72)
 vectors.make_stream(rng,ref,64+ref.gu_words,72,ref.ng_d,80)
 vectors.make_bias_tail(rng,image,64+ref.gu_words+ref.d_words)
 generated_weights=[0x3f800000|rng.randrange(0,1<<20) for _ in range(4)]
 assert generated_weights==cmd['weights']
 # Validate every active operand identity before using the oracle, whose
 # generic staging reader otherwise defaults missing data to zero.
 for kb in range(160):select_gu_operands(downs,pass_id=5,tokens=1,kb=kb)
 staging={'x':{},'xs':{}}
 for r in downs:
  sb=r['sideband'];kind=sb&7
  if kind in (1,2) and (sb>>3)&255==5:
   staging['x' if kind==1 else 'xs'][((sb>>11)&7,(sb>>14)&1023)]=int(r['payload'],16)
 h=ref.gu(cmd,staging);predicted=ref.hup_beats(h,1,5)
 timing=json.loads((OUT.parent/'20261117-command-error-output/checks.json').read_text())
 timed=next(r for r in timing if r['run']==run)
 assert timed['trace_sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
 beats=[(c,s) for c,s in timed['predicted_beats'] if s&3==0 and (s>>9)&255==5]
 assert len(beats)==len(predicted)==5
 full=[dict(cycle=c,sideband=s,payload=p['payload']) for (c,s),p in zip(beats,predicted)]
 checks=dict(payload=[r['payload'] for r in full]==[r['payload'] for r in actual],timed_beats=full==actual)
 result=dict(run=run,passed=all(checks.values()),checks=checks,predicted=full,actual=actual,h_bf16=h[0],numeric_coverage=dict(elements=len(h[0]),unique_codes=sorted(set(h[0])),nan_count=sum((x&0x7f80)==0x7f80 and (x&127)!=0 for x in h[0])),trace_sha256=timed['trace_sha256'],scope='first GU FP4 one token only; shared scoreboard arithmetic oracle; regenerated RRAM image; conditional timing')
 results.append(result);print(json.dumps(dict(run=run,checks=checks,beats=len(full))),flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)

