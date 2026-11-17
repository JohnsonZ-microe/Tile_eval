from pathlib import Path
import sys,json,hashlib
ROOT=Path(__file__).resolve().parents[5];sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from output_contention import measure
OUT=Path(__file__).parent
results=[]
for tokens in range(1,5):
 for delay in (1,6,7,16,64):
  for capture in (160,179,240):
   row=measure(tokens=tokens,credit_delay=delay,capture_cycle=capture)
   baseline=measure(tokens=tokens,credit_delay=delay,capture_cycle=capture,include_y=False)
   row['without_y_retire']=baseline['gu_retire'];row['gu_retire_delta']=row['gu_retire']-baseline['gu_retire']
   results.append(row)
(OUT/'checks.json').write_text(json.dumps(dict(status='passed',cases=results,scope='synthetic model-only invariants and latency experiment; no RTL validation'),indent=2)+'\n')
files=list((ROOT/'NPU_eval/af').glob('*.py'))+[ROOT/'Tile_eval/rev4/rtl/pe4_bus.sv',ROOT/'Tile_eval/rev4/rtl/pe4_yacc.sv',OUT/'check.py',OUT/'checks.json']
(OUT/'sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
for r in results:
 if r['tokens']==1 and r['capture_cycle']==179:
  print(json.dumps({k:r[k] for k in ('credit_delay','gu_retire','without_y_retire','gu_retire_delta','status_cycle','counters')}))
