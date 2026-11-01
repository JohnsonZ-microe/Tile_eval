# Tile PE revision 3

Independent timing-oriented revision of RTL-TILE-PE-001. Revision 1 and 2 are unchanged.
No local HDL compiler, VCS or DC is available. This release is implemented, not HDL-verified or timing-closed.
No remote task or installation is started automatically.

## Changes

- Exact 24x24 product from four 12x12 products, registered CSA and two-stage segmented CPA.
- 285/42-bit dot final sum and absolute value use two-stage segmented adders.
- Four-stage conversion: LOD, shift-control, barrel/sticky, FP32 RNE.
- Negative dot leaves use complement plus a shared correction count, avoiding 32 per-dot wide negations.
- Dedicated RF operand-read register before the FP32 adder.
- Stop propagating activation/weight scales and format after their last use.
- Full format support, R=4 and numerical oracle unchanged. No K/token time multiplexing.

There are 36 registered stages, acceptance at E0 and commit at E35. Same-address requests can be accepted no earlier than E36. The conservative occupancy scheme intentionally trades dependent throughput for correctness. Independent destinations can still accept one request per cycle while sufficient distinct RF elements remain.

## Local checks

From rev3:

```text
python -B scripts/run.py local --suite full --seed 817
```

Keep the original Tile_eval/model directory beside rev3. The runner snapshots that frozen oracle and rejects a changed reference.py hash.

Run products (snapshots, vectors, manifests, reports) are written to `PRODUCTS_DIR/<tool>-<stamp>-<pid>/` and log files to `LOGS_DIR/<same tag>/`: server defaults are `/staff/ee/eezhyzhao/Desktop/Products` and `~/tsclient/Tile_eval/logs`. Override with `PRODUCTS_DIR`/`LOGS_DIR`; on hosts where those paths do not exist, the in-tree `results/` and `logs/` are used.

## VCS on Linux

Copy rev3 alongside the existing Tile_eval/model on the server, then source the existing VCS environment.

```bash
bash scripts/run_vcs.sh --suite smoke
bash scripts/run_vcs.sh --suite full --seed 817
bash scripts/run_vcs.sh --suite full --seed 2026
env WAVES=1 bash scripts/run_vcs.sh --test array --suite full
```

The all suite runs CPA, math, dot and array benches. Individual selection: --test cpa/math/dot/array.
CPA vectors include cross-segment carries, reset flush and bubbles. Dot checks both exact fixed sum and FP32 result.
All testbench time declarations precede imports and signals.

## DC on Linux

In csh/tcsh, source /usr/eelocal/synopsys/syn-vv2023.12-sp5/.cshrc first.
Set TARGET_DB to the same explicit TT0.8V25C .db used for revision 2.
The LIB_DIR default matches the supplied TSMC library path.

```bash
env DC_CORES=16 bash syn/run_dc.sh --top pe3_cpa2
env DC_CORES=16 bash syn/run_dc.sh --top pe3_mul
env DC_CORES=16 bash syn/run_dc.sh --top pe3_round_probe
env DC_CORES=16 bash syn/run_dc.sh --top pe3_add
env DC_CORES=16 bash syn/run_dc.sh --top pe3_scale
env DC_CORES=16 bash syn/run_dc.sh --top pe3_dot32
env DC_CORES=16 bash syn/run_dc.sh --top pe3_dot_wide
env DC_CORES=16 bash syn/run_dc.sh --top tile_pe_v3
```

Defaults: 1 ns clock, setup/hold uncertainty 0.05 ns, I/O max 0.20 ns, min 0 ns, transition 0.05 ns, output load 0.01 pF. No false/multicycle exceptions.
FIX_HOLD=1 requests DC hold repair. It is not proof of hold closure and can increase area.
Use FIX_HOLD=0 only for a labeled baseline comparison, never to claim signoff.
DC_CORES defaults to 16 and only limits the maximum used.

Each run creates a new result directory, source/oracle snapshot, hashes, logs and manifest.
An existing --out directory is rejected. SYNTHESIS_COMPLETED means mapping completed, not timing acceptance.
Review reports/constraints.rpt, timing_setup.rpt, timing_hold.rpt, timing_registers.rpt, check_design.rpt and check_timing.rpt.
Reported numeric precision is increased to expose small violations previously printed as 0.00.

## Limits

There is no guarantee of reduced total area: segmented carry-select and deeper pipelines add registers.
Wide leaf/CSA banks remain. Lossless exponent-bin storage, K/token folding, physical reset trees and layout are not implemented.
No PPA result or power claim exists until VCS/DC and physical evidence are collected.
