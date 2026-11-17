from pathlib import Path
import sys,csv,json,hashlib
ROOT=Path(__file__).resolve().parents[5]
sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from drain_input_replay import DrainInputReplay
results=[]
for run in ('vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706'):
 path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
 predicted=[];actual=[];decoded=[]
 with path.open() as f:
  for r in csv.DictReader(f):
   if r['event']=='down':
    m=DrainInputReplay()
    m.tick(valid=True,payload=int(r['payload'],16),sideband=int(r['transaction']))
    cmd=m.tick()
    if cmd is not None:
     predicted.append((int(r['epoch']),int(r['cycle'])+1,cmd['bank'],cmd['slot'],cmd['start']<<8|cmd['count']))
     decoded.append(cmd)
   elif r['event']=='drain_accept':
    actual.append((int(r['epoch']),int(r['cycle']),int(r['bank']),int(r['transaction']),int(r['payload'],16)))
 result=dict(run=run,passed=predicted==actual,predicted=predicted,actual=actual,decoded_commands=decoded,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
 results.append(result)
 print(json.dumps(dict(run=run,passed=result['passed'],predicted=len(predicted),actual=len(actual))))
(Path(__file__).parent/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
