"""Revalidate saved full numeric results against externally decoded packet metadata."""
from pathlib import Path
import json,csv
OUT=Path(__file__).parent;ROOT=OUT.parents[4]
results=json.loads((OUT/'checks.json').read_text())
for result in results:
 downs=[]
 with (ROOT/'Tile_eval/logs'/result['run']/'calibration-events.csv').open() as f:
  for r in csv.DictReader(f):
   if r['event']=='down':downs.append((int(r['cycle']),int(r['transaction']),int(r['payload'],16)))
 meta=[]
 for cycle,sb,p in downs:
  if sb&7==0 and p&3==0:
   n=(p>>43)&7;tag=(sb>>3)&255;count=(36*n+7)//8
   meta.extend((16<<2)|(tag<<9)|(int(i==count-1)<<17) for i in range(count))
  if sb&7==4 and p&15==0 and (p>>4)&127 in (16,127):
   address=(p>>11)&4095;data=(p>>23)&0xffffffff
   bank=(address>>6)&1;slot=address&63;segment=(address>>7)&3;start=data&255;count=(data>>8)&255
   rows=list(range(start//8,(start+count-1)//8+1))
   meta.extend(1|(16<<2)|(((bank<<7)|(slot<<1))<<9)|(int(i==len(rows)-1)<<17)|(segment<<20) for i in range(len(rows)))
 assert len(meta)==876
 result['checks']['metadata']=meta==[s for c,s,p in result['predicted']]
 result['passed']=all(result['checks'].values())
 assert result['predicted']==result['actual']
 print(json.dumps(dict(run=result['run'],checks=result['checks'],passed=result['passed'])))
(OUT/'final-checks.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
