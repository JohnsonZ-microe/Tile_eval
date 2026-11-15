# GU/D retirement counter correction — 2026-11-15

Spec context: rev4/docs/SPEC.md exposes thirteen frozen counters at
0x020–0x050. The existing labels CNT_GU and CNT_D count completed phases;
CNT_SYNC1 counts the registered completion pulse. Saturation and CNT_CLEAR
priority are preserved.

## Defect and waveform evidence

The original GU/D predicates combined registered sync1 with pre-edge FSM
states P_HUP or P_DCOMMIT. The retiring edge sets sync1=1 and pstate=P_RUN.
The following edge sees sync1=1 but no longer sees the retiring state.
Normal completions therefore fail to increment their phase counter.

The received overlap VCD (vcs-20261115T095649Z-37967, SHA-256
8fff4eb47d83cb3afd390e8af3508285cdba3a199e33e24ce458e13428fb19cb)
shows sync1=1 with pstate=001 (P_RUN) at 1131445000 ps. Three timestamp
samples during that same pulse are retained in wave-evidence.json; these
are NOT three completion events. The array counters themselves are not
asserted to have been observed in the VCD. The failure conclusion combines
this waveform timing with the old source predicate.

## Change

CNT_GU/CNT_D now count head_retire in their respective pre-edge state.
CNT_SYNC1 retains its existing one-edge-later registered-pulse timing.
Reset, saturating increment and clear-over-increment priority are unchanged.
No compute datapath or memory request behavior is intentionally changed.

The full Tile bench checks final CNT_GU=expected_sync/2,
CNT_D=expected_sync/2 and CNT_SYNC1=expected_sync after final drain. This
assumes the existing paired GU/D vector suites. It prints CHECK phase_counters
only on an otherwise successful run. The promotion white-box bench checks
zero GU/D increments while blocked and exactly one correctly classified
increment at retirement for each of its 18 cases.

## Validation and open work

Nine tops pass pyslang 12.1.0 semantic compilation, with hashes in checks.json.
All 41 existing source tests pass (source-tests.log). Neither result proves
sequential simulation behavior. The newly added counter checks have not run
in VCS. The prior overlap PASS predates this correction and is not relabelled.

Run the current promotion suite and the full ordinary/overlap Tile suites
with the updated RTL and testbenches. A separate counter saturation and
clear/retirement coincidence test remains desirable; this patch does not
claim dynamic coverage for those boundary cases. Same-edge new-command loss
and complete independent Tile replay remain separate open work.
