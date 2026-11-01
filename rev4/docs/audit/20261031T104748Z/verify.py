"""Audit probes. Does not change RTL, benches or models."""
import datetime, hashlib, json, math, shutil, subprocess, sys
from pathlib import Path
OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "model"))
import tile_reference as tr
from tile_cycles import TileCycleModel
def hashes():
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in ("rtl", "tb", "model", "scripts", "syn")
            for p in sorted((ROOT/folder).rglob("*"))
            if p.is_file() and "__pycache__" not in p.parts}
before = hashes()
(OUT/"source_hashes.json").write_text(json.dumps(before,indent=2),encoding="utf-8")
command = [sys.executable,"-B","-m","unittest","discover","-s","model","-p","test_*.py","-v"]
start = datetime.datetime.now(datetime.timezone.utc).isoformat()
with (OUT/"python_tests.log").open("w",encoding="utf-8") as log:
    try:
        code = subprocess.run(command,cwd=str(ROOT),stdout=log,stderr=subprocess.STDOUT,timeout=900).returncode
    except subprocess.TimeoutExpired:
        code = 124
probes = {}
ref = tr.TileRef({0:int("7f"*128,16),1:int("2"*256,16)},0)
ref.run_phase(0,lambda lane,kb:int("38"*32,16),lambda lane,kb:127,15,1,1,8)
probes["golden_all_ones_dot32"] = {"expected_fp32":"42000000","actual_fp32":"%08x"%ref.rf.rf[0][0]}
value = -101.0
probes["sigmoid_negative_tail"] = {"bf16":"%04x"%(tr.fp32(value)>>16),
 "actual":"%08x"%tr.sigmoid(tr.fp32(value)>>16),
 "independent_double_fp32":"%08x"%tr.fp32(math.exp(value)/(1+math.exp(value)))}
probes["bf16_nan_cast"] = {"input":"7f800001","actual_bf16":"%04x"%tr.fp32_to_bf16(0x7f800001),"expected_class":"NaN"}
packed = ((5<<526)|(2<<523)|(1<<513)) & ((1<<533)-1)
probes["xfifo_field_roundtrip"] = {"input":{"pass":5,"lane":2,"idx":1},
 "decoded":{"pass":(packed>>525)&255,"lane":(packed>>522)&7,"idx":(packed>>513)&511}}
probes["ncols_width"] = {"expected":8,"actual_3bit":8&7}
probes["y_addresses_slot1_row0"] = {"expected":10,"commit_concat":16,"drain_concat":128}
rom = (ROOT/"rtl/pe4_sigmoid_rom.hex").read_text().splitlines()
probes["rom"] = {"entries":len(rom),"matches_reference_entries":all(int(word,16)==tr.sigmoid(index) for index,word in enumerate(rom)),
 "independence":"Shared algorithm; matching is not independent numerical validation."}
probes["cycle_examples_unvalidated"] = {name:TileCycleModel(fmt=name,n_tok=4).run_pass().summary() for name in ("fp4","bf16")}
baseline = json.loads((ROOT/"docs/baseline.json").read_text())
bindings = {}
for name,want in baseline["sha256"].items():
    path = ROOT/name if name.startswith("rtl/") else ROOT.parent/name
    bindings[name] = path.exists() and hashlib.sha256(path.read_bytes()).hexdigest()==want
latest = sorted((ROOT/"results").glob("local-*/manifest.json"))[-1]
old = json.loads(latest.read_text())
old_sources = {name.replace(chr(92),"/"):digest for name,digest in old.get("sources",{}).items()}
result = {"started_utc":start,"finished_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
 "python":sys.version,"command":command,"python_test_exit":code,"source_unchanged":before==hashes(),
 "frozen_bindings":bindings,"historical_manifest":latest.parent.name,
 "historical_hash_matches":{name:old_sources.get(name)==digest for name,digest in before.items()},
 "tools":{name:bool(shutil.which(name)) for name in ("vcs","dc_shell","verilator","iverilog")},"probes":probes}
(OUT/"checks.json").write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding="utf-8")
print(json.dumps({"python_test_exit":code,"source_unchanged":result["source_unchanged"],"probes":probes},ensure_ascii=False))

