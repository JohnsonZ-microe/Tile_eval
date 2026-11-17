"""Conditional admission check: retirement predicted from external inputs.

Not independent whole-Tile prediction. Only CTX register effects are modeled.
"""
from pathlib import Path
from collections import defaultdict
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[5]
sys.path[:0]=[str(ROOT/'Tile_eval/rev4/model'),str(ROOT/'NPU_eval/af')]
from calibration_compare import read_events
from admission_h_replay import AdmissionHReplay
from context_replay import ContextReplay
from hbank_trace_replay import state_word
OUT=Path(__file__).parent
results=[]
for run in ('vcs-20261116T004029Z-67940','vcs-20261116T011416Z-108706'):
    path=ROOT/'Tile_eval/logs'/run/'calibration-events.csv'
    rows=read_events(path)
    inputs=defaultdict(dict);retire=defaultdict(set);epochs=set();ignored=0
    prediction=json.loads((OUT.parent/'20261116-normal-overlap-retirement/checks.json').read_text())
    predicted=next(x for x in prediction if x['run']==run)
    assert predicted['trace_sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
    for r in predicted['prediction']['retirements']:retire[r['epoch']].add(r['cycle'])
    actual_take=[];actual_release=[]
    actual_writes=[];actual_states=[]
    for r in rows:
        epoch,cycle=r['epoch'],r['cycle']
        if r['event']=='reset':epochs.add(epoch)
        if r['event']=='bank_take':actual_take.append((epoch,cycle,r['bank'],r['pass'],int(r['payload'],16)))
        if r['event']=='bank_release':actual_release.append((epoch,cycle,r['bank']))
        if r['event']=='bank_write':actual_writes.append((epoch,cycle,r['bank'],r['kb'],r['group']))
        if r['event']=='bank_state':actual_states.append((epoch,cycle,int(r['payload'],16)))
        if r['event']=='down':
            sb=r['transaction'];payload=int(r['payload'],16);kind=sb&7
            if kind in (0,3):inputs[epoch][cycle]=(payload,sb)
            elif kind==4 and payload&15==1:
                address=(payload>>11)&4095
                if ContextReplay.target(address):inputs[epoch][cycle]=(payload,sb)
                else:ignored+=1
    predicted_take=[];predicted_release=[];errors=[];edges=0
    predicted_writes=[];predicted_states=[]
    for epoch in sorted(epochs):
        m=AdmissionHReplay();m.tick(rst_n=False)
        cursor=0
        def step(cycle, incoming=None, retiring=False):
            global edges
            payload,sb=incoming if incoming is not None else (0,0)
            event=m.tick(valid=incoming is not None,payload=payload,sideband=sb,retire=retiring)
            if event['take'] is not None:predicted_take.append((epoch,cycle,*event['take']))
            if event['release'] is not None:predicted_release.append((epoch,cycle,event['release']))
            if event['h_path']['write'] is not None:predicted_writes.append((epoch,cycle,*event['h_path']['write']))
            if event['h_path']['observe_state']:predicted_states.append((epoch,cycle,state_word(m.h_path.bank)))
            if event['context']['errors']:errors.append(dict(epoch=epoch,cycle=cycle,errors=event['context']['errors']))
            edges+=1
        def pending():
            return m.context.pending is not None or m.take is not None or m.release is not None or m.h_path.pending
        for cycle in sorted(set(inputs[epoch])|retire[epoch]):
            if cycle<cursor:raise ValueError('overlapping or invalid retirement cycle')
            while cursor<cycle and pending():step(cursor);cursor+=1
            step(cycle,inputs[epoch].get(cycle),cycle in retire[epoch]);cursor=cycle+1
        while pending():step(cursor);cursor+=1
    checks={name:dict(passed=pred==actual,predicted=pred,actual=actual) for name,pred,actual in
            [('bank_take',predicted_take,actual_take),('bank_release',predicted_release,actual_release),
             ('bank_write',predicted_writes,actual_writes),('bank_state',predicted_states,actual_states)]}
    result=dict(run=run,passed=all(c['passed'] for c in checks.values()),checks=checks,
                trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                errors=errors,modeled_edges=edges,ignored_non_ctx_writes=ignored,
                assumption='Retirement edges predicted from external inputs with idle context, isolated bus, idle Y commit, initial credit 6; only CTX register effects modeled')
    results.append(result)
    print(json.dumps(dict(run=run,passed=result['passed'],takes=len(predicted_take),releases=len(predicted_release),
                         writes=len(predicted_writes),states=len(predicted_states),
                         modeled_edges=edges,ignored_non_ctx_writes=ignored)),flush=True)
(OUT/'checks.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
