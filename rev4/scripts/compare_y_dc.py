"""Compare matched Y synthesis products; never infers power or silicon SRAM area."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from summarize_dc import summarize

REQUIRED=('period','setup_uncertainty','hold_uncertainty','input_delay','output_delay',
          'input_min','output_min','transition','load','fix_hold','DC_CORES')


def read_run(path,top):
    path=Path(path);m=json.loads((path/'manifest.json').read_text())
    if m.get('tool')!='dc' or m.get('status')!='completed' or m.get('top')!=top:
        raise ValueError('wrong/unfinished synthesis run: '+str(path))
    if (path/'exit_code.txt').read_text().strip()!='0':raise ValueError('nonzero synthesis exit')
    marker=(path/'SYNTHESIS_COMPLETED').read_text().strip()
    match=re.fullmatch(r'top='+re.escape(top)+r' full_mem=([01])',marker)
    if not match:raise ValueError('missing/malformed synthesis completion marker')
    settings={}
    for line in (path/'settings.txt').read_text().splitlines():
        if '=' in line:
            key,value=line.split('=',1)
            if key in settings:raise ValueError('duplicate setting '+key)
            settings[key]=value
    if settings.get('TOP')!=top or any(k not in settings for k in REQUIRED):raise ValueError('incomplete settings')
    library=m.get('library',{}).get('sha256','')
    if not re.fullmatch('[0-9a-f]{64}',library):raise ValueError('missing library hash')
    sources=m.get('sources',{})
    for name in ('rtl/pe4_yacc.sv','rtl/pe4_yacc_variants.sv','syn/run_dc.tcl','syn/constraints.tcl'):
        if name not in sources:raise ValueError('missing source '+name)
    # Require the exact frozen inputs used by each run, not today's worktree.
    for name,sha in sources.items():
        source=path/'snapshot'/name
        if hashlib.sha256(source.read_bytes()).hexdigest()!=sha:raise ValueError('snapshot source mismatch '+name)
    reports=path/'reports'
    qor=(reports/'qor.rpt').read_text()
    version=re.findall(r'^\s*Version:\s*(\S+)\s*$',qor,re.M)
    if len(version)!=1:raise ValueError('missing unique DC report version')
    # Units must be comparable even if headers contain different run dates.
    units=[line.strip() for line in (reports/'units.rpt').read_text().splitlines()
           if re.search(r'\b(?:Time|Capacitive Load|Resistance|Voltage|Current|Power)\s+Units?\s*:',line,re.I)]
    if not units:raise ValueError('unrecognized report units')
    required_reports=('area.rpt','timing_setup.rpt','timing_hold.rpt','check_design.rpt',
                      'check_timing.rpt','constraints.rpt','unmapped_macros.rpt')
    for name in required_reports:
        if not (reports/name).read_text().strip():raise ValueError('empty report '+name)
    if not (path/'netlist.v').read_text().strip():raise ValueError('empty netlist')
    values=summarize(reports)
    if values['cell_area'] is None or values['cell_area']<=0 or values['slack_status']=='unknown':
        raise ValueError('incomplete area/slack metrics')
    fingerprint={str(p.relative_to(path)):hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in [path/'manifest.json',path/'settings.txt',path/'SYNTHESIS_COMPLETED',path/'netlist.v']+list(reports.glob('*.rpt'))}
    return dict(path=str(path),settings={k:settings[k] for k in REQUIRED},library=library,
                sources=sources,memory_mode=int(match[1]),version=version[0],units=sorted(units),metrics=values,hashes=fingerprint)


def compare(baseline,candidate):
    a=read_run(baseline,'pe4_yacc_baseline');b=read_run(candidate,'pe4_yacc_direct')
    for field in ('settings','library','sources','memory_mode','version','units'):
        if a[field]!=b[field]:raise ValueError('runs not comparable: '+field)
    return dict(status='comparable_reports',baseline=a,candidate=b,
                cell_area_delta=b['metrics']['cell_area']-a['metrics']['cell_area'],
                cell_area_ratio=b['metrics']['cell_area']/a['metrics']['cell_area'],
                setup_slack_delta=b['metrics']['setup_slack_ns']-a['metrics']['setup_slack_ns'],
                hold_slack_delta=b['metrics']['hold_slack_ns']-a['metrics']['hold_slack_ns'],
                acceptance='pending manual check_design/check_timing/constraints and equivalence review',
                power=None,energy=None,scope='mapped logic comparison; blackboxed or behavioral SRAM is not physical macro area')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
    args=p.parse_args()
    try:result=compare(args.baseline,args.candidate)
    except (ValueError,OSError,KeyError) as error:result=dict(status='rejected',error=str(error))
    print(json.dumps(result,indent=2))
    raise SystemExit(0 if result['status']=='comparable_reports' else 1)
