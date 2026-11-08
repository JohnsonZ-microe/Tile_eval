# Rev4 probe and repair delivery — 2026-11-08

Scope: current Rev4 only. Frozen revision-1 oracle, revision-3 RTL, ROM
contents, old VCS products and old audit/website verification records are unchanged.
This is **not** a declaration that all 33 issues are closed.

## Current corrections
- quant carries encoded data, scale, tag and nonfinite bit through all valid stages.
- ACT weight alignment uses 19 delay registers: sampled input E0 is used by mul3
  at E19; final BF16 result is visible after E23. Needs RTL timing confirmation.
- CTRL accepts local tile ID or 0x7f only (data_bus 6.3/9).
- Credit stall and Y yield counters have actual event connections.
- h-buffer rejects row >=72 and lane >=4 before array indexing/writing.
- FIFO overflow no longer suppresses a legal simultaneous pop; empty pop does
  not return a credit. STATUS ring pointers are one bit for two entries.
- New GU/D only invalidates its own operand holds when the active phase differs.
  This is NOT a complete repair of scheduler overlap.
- Cycle model separately limits outstanding returns and reserved RQ space;
  Y readiness follows the final row completion. Timeout already threw an error
  in the current source; this work adds its regression rather than claiming a new fix.
- Correct storage capacities and ROM hash in current WIDTHS documentation.
- DC_CORES is validated and passed to set_host_options.

## Server commands
From Tile_eval/rev4; no remote command has been executed by this work:
```bash
bash scripts/run_vcs.sh --test cells --suite smoke --seed 817
bash scripts/run_vcs.sh --test modules --suite smoke --seed 817
bash scripts/run_vcs.sh --test protocol --suite smoke --seed 817
bash scripts/run_vcs.sh --test memory --suite smoke --seed 817
bash scripts/run_vcs.sh --test yacc --suite smoke --seed 817
bash scripts/run_vcs.sh --test control --suite smoke --seed 817
bash scripts/run_probe_matrix.sh
bash scripts/run_vcs.sh --test tile --suite smoke --seed 817 --overlap --trace
```
The overlap command is a diagnostic that may FAIL. It submits D before GU DONE,
but never broadcasts H before GU completion. Wider overlap remains unimplemented
in the test driver. Do not delete fences or suppress failures to obtain PASS.

Runner output directories and snapshots are unique. TIMEOUT_SECONDS stays 1800
unless explicitly overridden by the operator. --waves or WAVES=1 enables Tile VCD.
The full suite has 24 scenarios; legacy retains the original 12. Counts are read
from generated checks.txt and checked against checks.json, not copied from 439/24/30.

DC: set TARGET_DB and DC_CORES (e.g. 16), then use syn/run_dc.sh.
Logic-check blackboxes do not prove physical SRAM mapping, area or 1 GHz closure.

## Read-only traces and accuracy limits
--trace writes cycle,event,transaction,value CSV. RTL events are sampled before
NBA at the rising edge (consumer handshake); cycle zero is the first edge after
reset release, including RRAM loading. Unit benches compare outputs after NBA.
Storage request E0: LAT=2 returns after E1 and can be sampled downstream E2;
LAT=3 returns after E2 and can be sampled downstream E3.

model/tile_cycles.py exposes .events for RRAM issue/return/consume and PE
accept/commit. model/trace_compare.py requires identical per-channel events,
cycles, identifiers and values. It never auto-shifts timestamps or drops events.
The model is still a timing approximation, not a replay of the actual flit schedule.
A same-stimulus adapter and remaining model event channels must be completed before
claiming RTL/model cycle calibration. Directly comparing whole Tile traces today
is expected to fail; a PASS on a hand-picked subset is not full calibration.

## ROM independent audit
model/probe_reference.py uses Decimal exp, not the ROM generator or DUT functions.
The frozen arith_cells 5 contract explicitly evaluates exp/operations in double,
then rounds to FP32. Its 65536-entry comparison is bit exact. A separate
high-precision-direct-to-FP32 diagnostic finds 78 differing entries (one FP32
encoding step), near rounding boundaries. These are not permission to replace
the frozen ROM, loosen the HDL scoreboard, or change the arithmetic golden.

## Remaining work
The machine-readable 33-row matrix is probe_matrix.json. Unresolved items include
full scheduler reset/illegal sequencing, same-phase double CMD, slot/RQ/wscale
migration, commit/DRAIN overlap stress, Y yield and counter-clear verification,
same-stimulus cycle replay, all-top HDL compilation and physical macro/DC evidence.
The delivered probes cover significant missing behavior but do not close these gaps.

No VCS, DC or HDL elaborator is available locally. Python/source checks are
auxiliary evidence only. Historical PASS must not be applied to modified sources.
