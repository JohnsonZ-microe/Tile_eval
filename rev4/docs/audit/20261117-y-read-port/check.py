from pathlib import Path
import sys,json,hashlib
ROOT=Path(__file__).resolve().parents[5];sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from y_read_port_replay import YReadPortReplay
from sram_data_replay import Lat2SramData
from vcd_bus_check import edges
OUT=Path(__file__).parent;path=ROOT/'Tile_eval/vcd/yacc_v4.vcd'
m=YReadPortReplay();mem=[Lat2SramData(),Lat2SramData()];initialized=False
counts=dict(edges=0,commit_requests=0,drain_requests=0,same_bank_collision=0,different_bank_parallel=0,known_returns=0,unknown_returns=0)
for t,pre,post in edges(path,'tb_yacc_v4',extra_scopes=(('dut','ybank0'),('dut','ybank1'))):
 def read(name):
  value=pre.get(name)
  if value is None:raise ValueError('unknown '+name+' at '+str(t))
  return value
 if not initialized:
  if pre.get('rst_n')==0 and all(pre.get('dut.ybank%d.we'%b)==0 and pre.get('dut.ybank%d.re'%b)==0 for b in (0,1)):
   initialized=True;m.tick(rst_n=False)
  continue
 reset=not read('rst_n')
 args={} if reset else dict(commit_enable=read('dut.cre'),commit_bank=read('dut.cbank'),commit_address=read('dut.craddr'),drain_enable=read('dut.dre'),drain_bank=read('dut.dbank'),drain_address=read('dut.draddr'))
 e=m.tick(rst_n=not reset,**args)
 for b in (0,1):
  prefix='dut.ybank%d.'%b
  we=read(prefix+'we');write=(read(prefix+'waddr'),read(prefix+'wdata'),read(prefix+'wbe')) if we else None
  result=mem[b].tick(read=e['pre']['address'][b] if e['pre']['enable'][b] else None,write=write)['post']
  assert post.get('dut.re%d'%b)==int(e['post']['enable'][b]),('read enable',t,b)
  assert post.get('dut.raddr%d'%b)==e['post']['address'][b],('read address',t,b)
  assert post.get(prefix+'rvalid')==int(result['valid']),('valid',t,b)
  if result['valid']:
   if result['known_mask']==(1<<256)-1:
    assert post.get(prefix+'rdata')==result['data'],('data',t,b)
    counts['known_returns']+=1
   else:counts['unknown_returns']+=1
 assert post.get('dut.dbank_q')==e['post']['drain_bank_q'],('bank register',t)
 counts['edges']+=1
 if not reset:
  counts['commit_requests']+=args['commit_enable'];counts['drain_requests']+=args['drain_enable']
  if args['commit_enable'] and args['drain_enable']:
   key='same_bank_collision' if args['commit_bank']==e['pre']['drain_bank_q'] else 'different_bank_parallel';counts[key]+=1
assert initialized and counts['commit_requests'] and counts['drain_requests'] and counts['known_returns']
result=dict(status='passed',counts=counts,trace_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),scope='observed FSM request pulses and write data; predicted mux and SRAM read timing/data; not independent Y engine')
(OUT/'checks.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
