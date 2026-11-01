# Tile FFN Revision 4

Single-tile V4.1 FFN datapath on the frozen rev3 PE: SRAM operand supply
(1,024 B staging), RRAM SRAM model with a 3-entry prefetch credit, the full
GU -> SwiGLU (sigmoid ROM) -> H quantize/cache -> D -> y accumulate/DRAIN
path, the frozen data_bus v0.12 protocol subset (CMD/X/XS/H/CTRL, credits,
SYNC), and cross-phase overlap. Revisions 1-3 are untouched; see
docs/SPEC.md for the accepted configuration, registered deviations and the
bit-exact numeric contract, docs/WIDTHS.md for the storage map and cycle
model, docs/VALIDATION.md for the honest status table.

## Local checks (Windows/Linux, Python 3.6+, stdlib only)

```sh
python -B scripts/run.py local --suite full          # from rev4/
```

Runs the golden unit tests (fmul vs the frozen Fraction oracle, E4M3 vs
brute force, quantizer vs the direct formula, sigmoid table), verifies the
sigmoid ROM SHA-256, regenerates all vectors (12 tile scenarios + unit
vectors), scans the RTL for banned constructs and snapshots every source
with hashes. This does NOT compile RTL.

Run products (snapshot, vectors, manifests, binaries, reports) go to
`PRODUCTS_DIR/<tool>-<stamp>-<pid>/` and log files go to
`LOGS_DIR/<same tag>/`: server defaults are both under
`/staff/ee/eezhyzhao/Desktop/Products` (products at the root, logs in
`logs/`); the tsclient share is never used for I/O.
Override with the `PRODUCTS_DIR` / `LOGS_DIR` environment variables; on
hosts where those paths do not exist or are not writable (e.g. Windows,
stale mounts), the in-tree `results/` and `logs/` directories are used
instead with a stderr warning.

## VCS on a licensed Linux server (source the VCS env first)

```sh
bash scripts/run_vcs.sh --suite smoke
bash scripts/run_vcs.sh --suite full --seed 817
env WAVES=1 bash scripts/run_vcs.sh --test tile --suite full
```

`--test all` (default) runs `tb_math_v4` (fmul/act/quant/sigmoid units) and
`tb_tile_v4` (full closed loop: RRAM image load, flit replay with the
hub-side x-FIFO credit model, up-beat comparison against the golden, SYNC
counts, injected-error checks). TIMEOUT_SECONDS default 1800 per command.

## Design Compiler (csh/tcsh; same library as rev2/rev3)

```csh
setenv TARGET_DB /absolute/path/tcbn28hpcplusbwp30p140tt0p8v25c_ccs.db
bash syn/run_dc.sh --top pe4_fmul_probe
bash syn/run_dc.sh --top pe4_act_probe
bash syn/run_dc.sh --top pe4_quant_probe
bash syn/run_dc.sh --top pe4_yacc_probe
bash syn/run_dc.sh --top tile_ffn_probe
bash syn/run_dc.sh --top tile_ffn_v4
```

1 ns clock, 0.05 ns uncertainties, 0.20 ns I/O budget, no false/multicycle
paths. SRAM macros are NOT bound: all storage is behavioural
(`PE4_SRAM_MACRO` substitution point); every area/timing number is
logic-only until macros are mapped. SYNTHESIS_COMPLETED means mapping
finished, never timing acceptance.

## Directory layout

rtl/ pe4_* modules + tile_ffn_v4 + pe4_probes; tb/ tb_math_v4, tb_tile_v4;
model/ tile_reference.py (golden), vectors.py, tests; scripts/ run.py,
run_vcs.sh, gen_sigmoid_rom.py, rtl.f, summarize_dc.py; syn/ DC scripts;
docs/ SPEC.md, WIDTHS.md, VALIDATION.md, baseline.json; rtl/pe4_sigmoid_rom.hex.
