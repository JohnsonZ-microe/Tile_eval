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
from y_output_replay import replay_y
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
    predicted_y={name:[] for name in ('y_ready_visible','drain_accept','up_beat','y_commit','sync1')}
    credits={x['cycle']:x['value'] for x in inputs if x['event']=='credit'}
    gu_done={}
    for cfg in configs:
        matching=[x for x in inputs if x['event']=='down' and x['epoch']==cfg['epoch'] and
                  x['sideband']&7==0 and (x['sideband']>>3)&255==cfg['pass'] and int(x['payload'],16)&3==cfg['phase']]
        assert len(matching)==1, 'ambiguous GU command'
        cmd=matching[0];origin=cmd['cycle']+1
        tokens=(int(cmd['payload'],16)>>43)&7
        incoming=[x for x in inputs if x['event']=='down' and x['epoch']==cfg['epoch'] and
                  x['sideband']&7 in (1,2) and (x['sideband']>>3)&255==cfg['pass']]
        actual_order=[(int(x['sideband']&7==2),(x['sideband']>>11)&7,(x['sideband']>>14)&1023,cfg['pass']) for x in incoming]
        if cfg['phase']==0:
            assert actual_order==StagingFill(tokens,cfg['pass']).sequence, 'input sequence unsupported'
        if cfg['phase']==0:
            prediction=run_phase(cfg['fmt'],0,mask=(1<<tokens)-1,bias=cfg['bias'],
                                 ingress_arrivals=[x['cycle']-origin for x in incoming],capture_events=True)
            gu_done[cfg['epoch'],cfg['pass']]=origin+max(x['cycle'] for x in prediction['events'] if x['event']=='memory_consume')
            ready=None
        else:
            origin=max(origin,gu_done[cfg['epoch'],cfg['pass']]+1)
            h=[x for x in inputs if x['event']=='down' and x['epoch']==cfg['epoch'] and
               x['sideband']&7==3 and (x['sideband']>>3)&255==cfg['pass']]
            identities=[((x['sideband']>>11)&7,(x['sideband']>>14)&1023) for x in h]
            assert len(identities)==72*tokens and set(identities)=={(l,k) for l in range(tokens) for k in range(72)}
            # H@E0 -> registered quant input E1 -> quant consumption/write E5 -> ready sampled E6.
            ready=max(x['cycle'] for x in h)+6
            prediction=run_phase(cfg['fmt'],1,mask=(1<<tokens)-1,bias=cfg['bias'],
                                 d_ready_cycle=max(0,ready-origin),capture_events=True)
        if cfg['phase']==1:
            raw=int(cmd['payload'],16)
            trigger=origin+prediction['cycles']-1+2
            commit=dict(bank=(raw>>46)&1,mask=(1<<tokens)-1,slots=tuple((raw>>(96+40*l))&63 for l in range(4)))
            next_gu=min([x['cycle'] for x in inputs if x['event']=='down' and x['cycle']>cmd['cycle'] and
                         x['sideband']&7==0 and int(x['payload'],16)&3==0]+[max(x['cycle'] for x in inputs)+1])
            commands={}
            for x in inputs:
                if x['event']!='down' or not cmd['cycle']<x['cycle']<next_gu or x['sideband']&7!=4: continue
                payload=int(x['payload'],16)
                if payload&15!=0 or (payload>>4)&127 not in (16,127):continue
                addr=(payload>>11)&4095;data=(payload>>23)&0xffffffff
                commands[x['cycle']+1]=dict(bank=(addr>>6)&1,slot=addr&63,segment=(addr>>7)&3,
                                             start=data&255,count=(data>>8)&255,last_segment=bool(data&(1<<16)))
            y=replay_y(trigger,commit,commands,credits,initial_credit=6)
            for name in ('y_ready_visible','drain_accept','up_beat'):predicted_y[name].extend(y[name])
            predicted_y['y_commit'].append((trigger,commit['bank'],commit['mask']))
            predicted_y['sync1'].append(trigger)
        checks=[]
        for name in ('memory_issue','memory_consume','pe_accept'):
            actual=groups[name,cfg['epoch'],cfg['pass'],cfg['phase']]
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
        cases.append(dict(config=cfg,tokens=tokens,origin=origin,h_ready=ready,checks=checks))
    y_checks={}
    for name in ('y_ready_visible','drain_accept','up_beat','y_commit','sync1'):
        selected=[x for x in rows if x['event']==name]
        if name=='up_beat':actual=[(x['cycle'],x['transaction']) for x in selected if x['transaction']&3==1]
        elif name=='y_commit':actual=[(x['cycle'],x['bank'],int(x['payload'],16)) for x in selected]
        elif name=='sync1':actual=[x['cycle'] for x in selected][1::2]
        else:actual=[(x['cycle'],x['bank'],x['transaction']) for x in selected]
        expected=predicted_y[name]
        bad=[dict(index=i,actual=a,predicted=b) for i,(a,b) in enumerate(zip(actual,expected)) if a!=b]
        y_checks[name]=dict(actual=len(actual),predicted=len(expected),passed=actual==expected,first_mismatches=bad[:3])
    results.append(dict(run=tag,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),cases=cases,y_checks=y_checks,
                        passed=all(x['passed'] for x in y_checks.values()) and all(c['passed'] for case in cases for c in case['checks'])))
    print(tag,'GU/D + Y cases',len(cases),'passed',results[-1]['passed'],flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
