"""Audit the received YACC run without modifying historical evidence."""
from pathlib import Path
import hashlib, json, re
ROOT = Path(__file__).resolve().parents[5]
RUN = ROOT / 'Tile_eval/logs/vcs-20261114T042332Z-95723'
REV = ROOT / 'Tile_eval/rev4'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def local(name):
    if name.startswith('oracle/'): return ROOT / 'Tile_eval/model' / name[7:]
    if name.startswith('rtl/rev3_'): return ROOT / 'Tile_eval/rev3/rtl' / name[9:]
    return REV/name
m=json.loads((RUN/'manifest.json').read_text())
log=(RUN/'run_yacc.log').read_text()
assert m['test']=='yacc' and m['suite']=='full' and m['seed']==817
assert m['status']=='completed' and m['rtl_validation']=='passed'
assert (RUN/'exit_code.txt').read_text().strip()=='0'
assert all(s['returncode']==0 for s in m['steps'].values())
probes=[tuple(map(int,x)) for x in re.findall(r'^PROBE yacc_overlap bank=(\d+) commit_lead=(-?\d+)$',log,re.M)]
assert sorted(probes)==[(b,k) for b in range(2) for k in range(-21,22)]
assert 'CHECK yacc_overlap banks=2 offsets=86 packets=172 yields=18784' in log
assert 'CHECK yacc_read_identity rows=3000' in log
assert 'PASS yacc packets=300 cycles=98113' in log
coverage=dict(packets=300,overlap_banks=2,overlap_offsets=86,overlap_packets=172,overlap_yields=18784,read_identity_rows=3000)
assert m['simulations']['yacc']['coverage']==coverage
sources=[]
for name, expected in m['sources'].items():
    p=local(name)
    actual=sha(p) if p.is_file() else None
    sources.append(dict(path=name,expected=expected,actual=actual,matches=actual==expected))
compiled=[x for x in sources if x['path'].startswith('rtl/') or x['path']=='tb/tb_yacc_v4.sv']
assert compiled and all(x['matches'] for x in compiled), 'RTL/testbench snapshot mismatch'
wave=ROOT/'Tile_eval/vcd/yacc_v4.vcd'
expected_size=next(x['bytes'] for x in m['waveforms'] if x['file']==wave.name)
result=dict(run=RUN.name,status='log-and-source-verified',coverage=coverage,cycles=98113,
 compiled_sources_checked=len(compiled),sources=sources,
 evidence_hashes={n:sha(RUN/n) for n in ['manifest.json','run_yacc.log','compile_yacc.log','exit_code.txt']},
 waveform=dict(path=str(wave.relative_to(ROOT)),expected_bytes=expected_size,actual_bytes=wave.stat().st_size,sha256=sha(wave),size_matches=wave.stat().st_size==expected_size,cycle_replay_verified=False),
 scope='YACC component numerical, metadata and read-identity scoreboard; not whole Tile, code coverage, PPA or complete AF calibration')
timing=json.loads(Path(__file__).with_name('commit-timing.json').read_text())
drain=json.loads(Path(__file__).with_name('drain-replay.json').read_text())
assert timing['commit_comparison']['status']=='passed'
assert timing['source']['sha256']==sha(wave)
assert drain['sha256']==sha(wave) and drain['packets']==300 and drain['identity_checks']==3000
assert result['waveform']['size_matches']
result['waveform']['cycle_replay_verified']=True
result['status']='log-source-and-component-waveform-verified'
Path(__file__).with_name('checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='sources'},indent=2))
