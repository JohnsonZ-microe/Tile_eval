import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
LIB_DIR = '/dfs/app/tsmc_icdc/tsmc028/28HPCplus_RF_20260129/Standard_Cell_1/core_cell_library/gate_length_30nm/9-track/tcbn28hpcplusbwp30p140_190a/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp30p140_180a'
# Run products go to PRODUCTS_DIR (server default /staff/ee/eezhyzhao/Desktop/
# Products); log files go to LOGS_DIR (server default ~/tsclient/Tile_eval/
# logs); both use the same <tool>-<stamp>-<pid> run tag. Non-POSIX hosts
# without these paths fall back to in-tree results/ and logs/.
DEFAULT_PRODUCTS = '/staff/ee/eezhyzhao/Desktop/Products'
DEFAULT_LOGS = '~/tsclient/Tile_eval/logs'


def pick_base(env_name, posix_default, fallback):
    value = os.getenv(env_name)
    if value:
        return Path(os.path.expanduser(value))
    candidate = Path(os.path.expanduser(posix_default))
    if os.name == 'posix' or candidate.exists():
        return candidate
    return ROOT / fallback


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('tool',choices=['local','vcs','dc'])
    parser.add_argument('--suite',choices=['smoke','full'],default=os.getenv('SUITE','full'))
    parser.add_argument('--seed',type=int,default=int(os.getenv('SEED','817')))
    parser.add_argument('--test',choices=['all','cpa','math','dot','array'],default=os.getenv('TEST','all'))
    parser.add_argument('--top',choices=['tile_pe_v3','pe3_dot32','pe3_dot_wide','pe3_scale','pe3_add','pe3_mul','pe3_shift','pe3_round_probe','pe3_cpa2'],default=os.getenv('TOP','tile_pe_v3'))
    parser.add_argument('--out',type=Path,default=os.getenv('RESULTS'))
    parser.add_argument('--waves',action='store_true',default=os.getenv('WAVES','0')=='1')
    args=parser.parse_args()
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    tag='%s-%s-%s'%(args.tool,stamp,os.getpid())
    products_root=pick_base('PRODUCTS_DIR',DEFAULT_PRODUCTS,'results')
    logs_root=pick_base('LOGS_DIR',DEFAULT_LOGS,'logs')
    output=(args.out or products_root/tag).resolve()
    output.mkdir(parents=True,exist_ok=False)
    logdir=(logs_root/tag).resolve()
    logdir.mkdir(parents=True,exist_ok=False)
    manifest=dict(tool=args.tool,seed=args.seed,suite=args.suite,test=args.test,top=args.top,
                  started_utc=stamp,python=sys.version,commands=[],status='running',
                  products_dir=str(output),log_dir=str(logdir),
                  rtl_validation='not run',timing='not verified')
    started=time.time()
    status=1
    try:
        snapshot=output/'snapshot'
        for name in ['rtl','tb','model','scripts','syn','docs']:
            shutil.copytree(str(ROOT/name),str(snapshot/name),ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
        oracle=ROOT/'oracle' if (ROOT/'oracle').exists() else ROOT.parent/'model'
        frozen=json.loads((ROOT/'docs/baseline.json').read_text())['sha256']['model/reference.py']
        if digest(oracle/'reference.py') != frozen:
            raise RuntimeError('Numerical oracle differs from the frozen revision 1 hash')
        shutil.copytree(str(oracle),str(snapshot/'oracle'),ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
        manifest['sources']={str(path.relative_to(snapshot)):digest(path) for path in snapshot.rglob('*') if path.is_file()}
        manifest['baseline_rtl']={str(path.name):digest(path) for path in (ROOT.parent/'rtl').glob('*.sv')}
        environment=os.environ.copy()
        environment['PYTHONDONTWRITEBYTECODE']='1'
        timeout=int(os.getenv('TIMEOUT_SECONDS','345600' if args.tool=='dc' else '1800'))

        def run(command,name):
            manifest['commands'].append(command)
            print('Running: '+' '.join(map(str,command)),flush=True)
            with (logdir/name).open('w') as log:
                completed=subprocess.run(command,cwd=str(snapshot),env=environment,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
            if completed.returncode:
                raise RuntimeError('%s exited %s; see %s'%(command[0],completed.returncode,logdir/name))
            return (logdir/name).read_text(errors='replace')

        run([sys.executable,'-B','-m','unittest','discover','-s','oracle','-p','test_reference.py','-v'],'python_reference.log')
        run([sys.executable,'-B','-m','unittest','discover','-s','model','-p','test_*.py','-v'],'python_rev3.log')
        run([sys.executable,'-B','model/vectors.py','--out',str(output/'vectors'),'--suite',args.suite,'--seed',str(args.seed)],'vectors.log')
        manifest['vectors']=json.loads((output/'vectors/vectors.json').read_text())
        sources=[str(snapshot/line.strip()) for line in (snapshot/'scripts/rtl.f').read_text().splitlines() if line.strip()]
        filelist=output/'rtl.f'
        filelist.write_text('\n'.join('"'+path.replace('\\','/')+'"' for path in sources)+'\n')
        if args.tool=='vcs':
            executable=shutil.which(os.getenv('VCS','vcs'))
            if not executable:
                raise RuntimeError('VCS not found; source the server VCS environment first')
            manifest['executable']=executable
            for test in (['cpa','math','dot','array'] if args.test=='all' else [args.test]):
                top={'cpa':'tb_cpa_v3','math':'tb_math_v3','dot':'tb_dot_v3','array':'tb_tile_pe_v3'}[test]
                binary=output/('simv_'+test)
                compile_log=run([executable,'-full64','-sverilog','-timescale=1ns/1ps','-debug_access+all',
                    '-f',str(filelist),str(snapshot/'tb'/(top+'.sv')),'-top',top,'-Mdir='+str(output/('csrc_'+test)),
                    '-o',str(binary)],'compile_'+test+'.log')
                if re.search(r'^\s*Error[-:]',compile_log,re.M):
                    raise RuntimeError('VCS compile errors in '+test)
                command=[str(binary),'+VECTORS='+str(output/'vectors')]
                if args.waves and test=='array':
                    command.append('+VCD='+str(output/'tile_pe_v3.vcd'))
                log=run(command,'run_'+test+'.log')
                if 'PASS '+test not in log or re.search(r'\b(Fatal|Error)[-:]',log):
                    raise RuntimeError('Missing PASS or simulator error: '+test)
            manifest['rtl_validation']='VCS '+args.test+' '+args.suite+' passed'
        elif args.tool=='dc':
            executable=shutil.which(os.getenv('DC_SHELL','dc_shell'))
            if not executable:
                raise RuntimeError('dc_shell not found; source the supplied .cshrc in csh/tcsh first')
            target=os.getenv('TARGET_DB')
            if not target:
                raise RuntimeError('Set TARGET_DB to one explicit .db corner')
            library=Path(target)
            if not library.is_absolute():
                library=Path(os.getenv('LIB_DIR',LIB_DIR))/library
            if library.suffix!='.db' or not library.is_file():
                raise RuntimeError('TARGET_DB is not a readable .db: '+str(library))
            environment.update(TARGET_DB=str(library.resolve()),DC_RUN_DIR=str(output),TOP=args.top)
            manifest['library']=dict(path=str(library.resolve()),sha256=digest(library))
            manifest['dc_environment']={name:environment.get(name,default) for name,default in
                [('DC_CORES','16'),('FIX_HOLD','1'),('CLK_PERIOD','1.0'),('SETUP_UNCERTAINTY','0.05'),
                 ('HOLD_UNCERTAINTY','0.05'),('INPUT_DELAY','0.20'),('OUTPUT_DELAY','0.20'),
                 ('INPUT_MIN','0.0'),('OUTPUT_MIN','0.0'),('INPUT_TRANSITION','0.05'),('OUTPUT_LOAD','0.01')]}
            manifest['executable']=executable
            log=run([executable,'-f',str(snapshot/'syn/run_dc.tcl')],'dc_console.log')
            if re.search(r'^\s*Error:',log,re.M) or not (output/'SYNTHESIS_COMPLETED').exists():
                raise RuntimeError('DC did not complete successfully; inspect dc_console.log')
            manifest['mapping']='completed; inspect checks and warnings'
            manifest['timing']='not automatically accepted; review setup/hold, unconstrained paths and design checks'
        manifest['waveforms']=[str(path.name) for path in output.glob('*.vcd')]
        manifest['status']='completed'
        status=0
    except (Exception,KeyboardInterrupt) as error:
        manifest['status']='failed'
        manifest['error']=str(error)
        print(str(error),file=sys.stderr)
    finally:
        manifest['elapsed_seconds']=time.time()-started
        manifest['exit_code']=status
        (output/'manifest.json').write_text(json.dumps(manifest,indent=2))
        (output/'exit_code.txt').write_text(str(status)+'\n')
        (logdir/'exit_code.txt').write_text(str(status)+'\n')
        print('Products: %s'%(output,))
        print('Logs:      %s'%(logdir,))
        print('Exit:      %s'%(status,))
    return status


if __name__=='__main__':
    sys.exit(main())
