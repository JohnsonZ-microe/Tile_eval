"""Audit supplied Tile trace; component checks do not establish full replay."""
from pathlib import Path
from collections import Counter
import hashlib, json, sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from calibration_stimulus import extract
from memory_replay import check_memory_trace
RUN=ROOT/'Tile_eval/logs/vcs-20261114T103159Z-70119'
OUT=Path(__file__).parent
trace=RUN/'calibration-events.csv'
rows=read_events(trace)
inputs=extract(rows)
counts=Counter(row['event'] for row in rows)
manifest=json.loads((RUN/'manifest.json').read_text())
checks=json.loads((RUN/'checks.json').read_text())
assert manifest['test']=='tile' and manifest['rtl_validation']=='passed'
assert counts['down']==checks['flits'] and counts['up_beat']==checks['beats']
assert counts['sync1']==checks['sync1_gu']+checks['sync1_d']
assert counts['y_ready_visible']==counts['drain_accept']==checks['y_packets']
assert counts['memory_issue']==counts['memory_return']==counts['memory_consume']==108600
memory=check_memory_trace(rows)
channels={name:[row for row in rows if row['event']==name] for name in counts}
latencies=[]
for incoming,outgoing,latency in [('memory_issue','memory_return',3),('pe_accept','pe_commit_visible',35),('act_accept','act_consume',24),('quant_accept','quant_consume',4)]:
    left,right=channels[incoming],channels[outgoing]
    assert len(left)==len(right)>0
    mismatch=[]
    for index,(a,b) in enumerate(zip(left,right)):
        if a['epoch']!=b['epoch'] or b['cycle']-a['cycle']!=latency or a['transaction']!=b['transaction']:
            mismatch.append(dict(index=index,input=a,output=b))
    latencies.append(dict(input=incoming,output=outgoing,latency=latency,transactions=len(left),mismatches=mismatch[:3],mismatch_count=len(mismatch)))
result=dict(status='passed' if not any(x['mismatch_count'] for x in latencies) else 'failed',
 trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest(),trace_bytes=trace.stat().st_size,
 events=len(rows),counts=counts,input_events=len(inputs),memory_replay=memory,component_latency=latencies,
 scope='component timing/identity with observed component inputs; not independent full-Tile replay or numerical calibration',
 checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
(OUT/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
(OUT/'stimulus.json').write_text(json.dumps(dict(schema=1,inputs=inputs,source_sha256=result['trace_sha256'],scope='external down/credit/reset only'),indent=2)+'\n')
print(json.dumps(result,indent=2))
