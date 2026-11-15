"""Compare GU phase edge predictions from external CMD and X/XS timings.

No measured issue/consume cycle is used to seed or shift the replay.
Admission origin is CMD edge + 1, derived from registered RTL slot state.
"""
from pathlib import Path
from collections import Counter, defaultdict
import hashlib, json, sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from calibration_stimulus import extract
from trace_config_replay import decode_inputs
from phase_replay import run_phase
from staging_fill_replay import StagingFill
from hup_input_replay import replay_hup
OUT=Path(__file__).parent
results=[]
for tag in ['vcs-20261115T095649Z-37967']:
    path=ROOT/'Tile_eval/logs'/tag/'calibration-events.csv'
    rows=read_events(path)
    inputs=extract(rows)
    configs=decode_inputs(inputs,assume_idle_context_writes=True)['configurations']
    groups=defaultdict(list)
    for row in rows:
        groups[row['event'],row['epoch'],row['pass'],row['phase']].append(row)
    cases=[]
    hup_predictions={name:[] for name in ('act_accept','act_consume','up_beat','sync1')}
    credit_edges={x['cycle']:x['value'] for x in inputs if x['event']=='credit'}
    assert {x['epoch'] for x in inputs}=={0}
    for cfg in configs:
        if cfg['phase'] != 0: continue
        matching=[x for x in inputs if x['event']=='down' and x['epoch']==cfg['epoch'] and
                  x['sideband']&7==0 and (x['sideband']>>3)&255==cfg['pass'] and int(x['payload'],16)&3==0]
        assert len(matching)==1, 'ambiguous GU command'
        cmd=matching[0];origin=cmd['cycle']+1
        tokens=(int(cmd['payload'],16)>>43)&7
        incoming=[x for x in inputs if x['event']=='down' and x['epoch']==cfg['epoch'] and
                  x['sideband']&7 in (1,2) and (x['sideband']>>3)&255==cfg['pass']]
        actual_order=[(int(x['sideband']&7==2),(x['sideband']>>11)&7,(x['sideband']>>14)&1023,cfg['pass']) for x in incoming]
        assert actual_order==StagingFill(tokens,cfg['pass']).sequence, 'input sequence unsupported'
        prediction=run_phase(cfg['fmt'],0,mask=(1<<tokens)-1,bias=cfg['bias'],
                             ingress_arrivals=[x['cycle']-origin for x in incoming],capture_events=True)
        capture=origin+prediction['cycles']-1
        hup=replay_hup(capture,tokens,cfg['pass'],credit_edges,initial_credit=6)
        for name in hup_predictions:hup_predictions[name].extend(hup[name])
        checks=[]
        for name in ('memory_issue','memory_consume','pe_accept'):
            actual=groups[name,cfg['epoch'],cfg['pass'],0]
            expected=[x for x in prediction['events'] if x['event']==name]
            mismatch=[];deltas=Counter()
            for i,(a,b) in enumerate(zip(actual,expected)):
                deltas[a['cycle']-(b['cycle']+origin)]+=1
                good=a['sample']==b['sample'] and a['cycle']==b['cycle']+origin
                if name=='memory_issue':
                    good=good and int(a['payload'],16)==cfg['base']+b['address'] and a['kb']==b['kb'] and a['group']==b['group']
                elif name=='memory_consume':
                    good=good and a['kb']==b['kb'] and a['group']==b['group']
                else:
                    good=good and int(a['payload'],16)==(b['base']<<4)|b['mask'] and a['transaction']==(cfg['pass']<<19)|b['transaction']
                if not good and len(mismatch)<3:mismatch.append(dict(index=i,actual=a,expected=b,origin=origin))
            checks.append(dict(event=name,actual=len(actual),predicted=len(expected),delta_cycles=dict(deltas),
                               passed=len(actual)==len(expected) and not mismatch,first_mismatches=mismatch))
        cases.append(dict(config=cfg,tokens=tokens,origin=origin,checks=checks))
    output_checks={}
    for name in ('act_accept','act_consume','up_beat'):
        actual=[(x['cycle'],x['transaction']) for x in rows if x['event']==name and
                (name!='up_beat' or x['transaction']&3==0)]
        predicted=hup_predictions[name]
        bad=[dict(index=i,actual=a,predicted=b) for i,(a,b) in enumerate(zip(actual,predicted)) if a!=b]
        output_checks[name]=dict(actual=len(actual),predicted=len(predicted),passed=actual==predicted,first_mismatches=bad[:3])
    gu_sync=[x['cycle'] for x in rows if x['event']=='sync1'][::2]
    output_checks['sync1']=dict(actual=gu_sync,predicted=hup_predictions['sync1'],passed=gu_sync==hup_predictions['sync1'])
    results.append(dict(run=tag,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),cases=cases,output_checks=output_checks,
                        passed=all(x['passed'] for x in output_checks.values()) and all(c['passed'] for case in cases for c in case['checks'])))
    print(tag,'GU + H_UP cases',len(cases),'passed',results[-1]['passed'],flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
