"""First D raw-H numeric replay using the existing scoreboard oracle."""
from pathlib import Path
import csv,json,hashlib,sys,random
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'NPU_eval/af'),str(ROOT/'Tile_eval/rev4/model')]
from trace_config_replay import decode_inputs
from gu_operand_data import select_gu_operands
from drain_input_replay import DrainInputReplay
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
    if sb&3==1:actual.append(dict(cycle=int(r['cycle']),sideband=sb,payload=int(r['payload'],16)))
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
 # Restrict inputs to the first scenario, before the second GU command.
 next_gu=next(r['cycle'] for r in downs if r['sideband']&7==0 and int(r['payload'],16)&3==0 and (r['sideband']>>3)&255!=5)
 scenario=[r for r in downs if r['cycle']<next_gu]
 drow=next(r for r in scenario if r['sideband']&7==0 and int(r['payload'],16)&3==1)
 dp=int(drow['payload'],16)
 assert (drow['sideband']>>3)&255==5 and (dp>>43)&7==1
 assert (dp>>22)&((1<<21)-1)==64
 cmd=dict(base=64,n_tok=1,mask=1,slots=[(dp>>(96+40*l))&63 for l in range(4)],weights=[(dp>>(102+40*l))&0xffffffff for l in range(4)])
 bank=(dp>>46)&1
 blocks={}
 for r in scenario:
  sb=r['sideband']
  if sb&7!=3:continue
  assert (sb>>3)&255==5
  key=((sb>>11)&7,(sb>>14)&1023)
  assert key not in blocks,'duplicate H block'
  blocks[key]=int(r['payload'],16)
 assert set(blocks)=={(0,k) for k in range(72)},'missing or extraneous active H blocks'
 for (lane,kb),payload in blocks.items():
  codes=[(payload>>(16*j))&65535 for j in range(32)]
  ref.store_h(lane,kb,*vectors.quantize_block(codes))
 ref.dphase(cmd,1);ref.commit_y(cmd,bank)
 commands=[];decoder=DrainInputReplay()
 for r in scenario:
  decoder.tick(valid=True,payload=int(r['payload'],16),sideband=r['sideband'])
  decoded=decoder.tick()
  if decoded is not None:commands.append(decoded)
 assert len(commands)==1
 d=commands[0]
 assert d['bank']==bank and d['slot']==cmd['slots'][0]
 predicted=ref.drain_beats(d['bank'],d['slot'],d['start'],d['count'],d['segment'],d['last_segment'],(bank<<7)|(d['slot']<<1))
 actual=[r for r in actual if r['cycle']<next_gu]
 timing=json.loads((OUT.parent/'20261117-command-error-output/checks.json').read_text())
 timed=next(r for r in timing if r['run']==run)
 assert timed['trace_sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
 beats=[(c,s) for c,s in timed['predicted_beats'] if s&3==1 and c<next_gu]
 assert len(beats)==len(predicted)==10
 full=[dict(cycle=c,sideband=s,payload=p['payload']) for (c,s),p in zip(beats,predicted)]
 checks=dict(payload=[r['payload'] for r in full]==[r['payload'] for r in actual],timed_beats=full==actual)
 result=dict(run=run,passed=all(checks.values()),checks=checks,predicted=full,actual=actual,h_blocks=len(blocks),numeric_coverage=dict(elements=80,unique_codes=sorted({(r['payload']>>(16*j))&65535 for r in full for j in range(8)})),trace_sha256=timed['trace_sha256'],scope='first D FP4 one token only; external gathered H quantized independently of observed quantizer outputs; shared scoreboard arithmetic oracle; regenerated RRAM image; conditional timing')
 results.append(result);print(json.dumps(dict(run=run,checks=checks,beats=len(full))),flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)

