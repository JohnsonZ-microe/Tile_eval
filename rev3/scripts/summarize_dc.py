import argparse
import json
from pathlib import Path
import re


def summarize(folder):
    source=(folder/'qor.rpt').read_text(errors='replace')
    result={}
    for key,label in [('cell_area','Cell Area'),('sequential_cells','Sequential Cell Count'),
                      ('combinational_area','Combinational Area'),('sequential_area','Noncombinational Area'),
                      ('setup_tns_ns','Total Negative Slack'),('hold_tns_ns','Total Hold Violation'),
                      ('leaf_cells','Leaf Cell Count'),('setup_slack_ns','Critical Path Slack'),
                      ('period_ns','Critical Path Clk Period'),('hold_slack_ns','Worst Hold Violation'),
                      ('setup_violations','No. of Violating Paths'),('hold_violations','No. of Hold Violations')]:
        match=re.search(re.escape(label)+r':\s+(-?[\d.]+)',source)
        result[key]=float(match.group(1)) if match else None
    if any(result[key] is None for key in ['setup_slack_ns','hold_slack_ns','setup_violations','hold_violations']):
        result['slack_status']='unknown'
    else:
        result['slack_status']='no_reported_violations' if (
            min(result['setup_slack_ns'],result['hold_slack_ns'])>=0 and
            result['setup_violations']==0 and result['hold_violations']==0) else 'FAIL'
    timing=(folder/'timing_setup.rpt').read_text(errors='replace')
    result['worst_path']={key:re.findall(key+r':\s+(\S+)',timing)[:1] for key in ['Startpoint','Endpoint']}
    result['acceptance']='Manual design checks, constraints, library corner and equivalence review still required'
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('reports',type=Path)
    parser.add_argument('--baseline',type=Path)
    args=parser.parse_args()
    result=summarize(args.reports)
    if args.baseline:
        baseline=summarize(args.baseline)
        result['baseline']=baseline
        if baseline['cell_area'] and result['cell_area'] is not None:
            result['area_ratio_to_baseline']=result['cell_area']/baseline['cell_area']
    print(json.dumps(result,indent=2))
