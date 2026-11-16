# Received VCS results — 2026-11-16

All four successful runs below match the current local RTL compilation files,
selected testbench and runner by SHA-256 (accepting CRLF-to-LF normalization).
The snapshot renames ../rev3/rtl/X to rtl/rev3_X; check.py accounts for this.
checks.json records the source comparison and received artifact hashes.

| Run suffix | Test | Observed result |
| --- | --- | --- |
| 155345Z-71363 | promotion | PASS; 18 promotion cases, 8 counter cases, 2 command collisions, 22 quantizer guard cases, 4 routing guard cases |
| 170006Z-29200 | memory | PASS; 4 ownership handoffs, 4 release/write rejections, 2 independent writes, 4 reset probes |
| 151442Z-8320 | full tile, CMD_RETIRE_PROBE, bounded waves | PASS; 24 collisions; 108600 issued/returned/consumed; GU=24, D=24, SYNC1=48 |
| 221329Z-18837 | full tile, CMD_RETIRE_PROBE | PASS; same coverage counts |

Prefix for all rows is vcs-20261115T. Both full Tile runs have --trace and
--calibration-trace; neither simulation command contains +OVERLAP.
They report zero promotion address cases because the command/retire probe
uses a different admission timing. The separate promotion test supplies the
distinct-tail, simultaneous issue and scale-consumption coverage.

Both received full Tile calibration CSVs were replayed locally:

- H-buffer ownership replay passed 4368 post-edge comparisons: 24 takes,
  24 releases, 4320 attempted writes. No state mismatch.
- Quantizer guard replay passed 4320 input/output/write identities and timing.
  Canceled count is zero in these full runs; they do not cover cancellation.
  Cancellation evidence instead comes from the 10 same-bank release cases in
  the directed promotion run, with 10 independent-bank cases and 2 baselines.

These are observed-component-input checks, not independent whole-Tile command
prediction or Python numerical payload calibration. Existing ordinary/overlap
results predate these RTL changes; current-version ordinary and overlap runs
are still required. No PPA conclusion follows from these tests.

Two older attempts are retained and distinguished:

- 102815Z-98560 failed at 1131446000 ps: CMD_RETIRE command lost/duplicated,
  pass=5, survivors=0. It uses earlier RTL; later matching-source runs pass
  this probe with 24 collisions.
- 141906Z-41851 never entered RTL simulation: the Python source test still
  required the old bank-release trace selector. The corrected source test now
  passes and later jobs completed. Do not classify this as a new RTL failure.

Broader local regression completed: AF tests 168/168 passed (53.057 s), rev4
model/source tests 118/118 passed (468.830 s). Logs copied into this audit.
The process handle for the latter was no longer available when polled after
the user update; its completed log records the final result. No job restarted.

Next current-source regression commands, from Tile_eval:

```bash
bash scripts/run_vcs.sh --test tile --suite full --seed 817 --trace --calibration-trace
bash scripts/run_vcs.sh --test tile --suite full --seed 817 --overlap --trace --calibration-trace
```

These omit CMD_RETIRE_PROBE intentionally to exercise the ordinary and early-D
admission paths. No extra VCD is required for these checks unless a new failure
needs a bounded waveform. The user has not been asked to repeat passed directed
tests against the same source version.
