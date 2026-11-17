from pathlib import Path
import sys,json,hashlib
ROOT=Path(__file__).resolve().parents[5];sys.path.insert(0,str(ROOT/'NPU_eval/af'))
from vcd_sram_data_check import check
OUT=Path(__file__).parent
result=check(ROOT/'Tile_eval/vcd/yacc_v4.vcd')
(OUT/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
files=[ROOT/p for p in ('NPU_eval/af/vcd_sram_data_check.py','NPU_eval/af/sram_data_replay.py','NPU_eval/af/vcd_bus_check.py','NPU_eval/af/tests/test_vcd_sram_data_check.py','Tile_eval/rev4/rtl/pe4_sram.sv')]+[OUT/'check.py']
(OUT/'sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
print(json.dumps(result))
