# Received overlap artifacts and replay — 2026-11-15

Run: vcs-20261115T095649Z-37967. This follow-up supersedes the artifact-pending
observation in checks.json without rewriting that earlier observation.

The received VCD is 23,077,277 bytes. SHA-256 matches the sync record:
8fff4eb47d83cb3afd390e8af3508285cdba3a199e33e24ce458e13428fb19cb.
Timescale is 1 ps. First timestamp 1128005000 ps, last 1133005000 ps,
with $dumpoff at the last timestamp: exactly 500 clock periods at 10 ns.
The file includes the boundary snapshot; this is not a full-run waveform.

Both CSVs match the previous overlap run byte for byte:
- calibration-events.csv: 102,757,498 bytes, SHA-256
  b80eb7092b96b56eae33610a82bdd7e2672e5e9c61a5382cfb9817994d5b6815
- tile-events.csv: 14,423,787 bytes, SHA-256
  aabde3da803df37e207d154b26eff9c6a739569e396b2d9c4f6bd762ebfd438b

The received files were nevertheless replayed anew under this run ID in new
adjacent audit directories. Component identity/latency checks passed;
48 GU/D phase timing cases plus Y checks passed; 24 GU plus H_UP cases passed.
replay-results.json binds the result files. Per-run check.py copies preserve
the previous algorithms and assumptions and change only the selected run ID.

Evidence limits remain: legal admission and idle CTX assumptions, segmented
outputs with six initial credits and idle bus, no Python numerical payload
comparison, and no independently predicted continuous whole-Tile lifecycle.
CSV identity proves unchanged recorded events for this stimulus, not internal
state equivalence or complete retirement hazard coverage. The log reports
24 promotion address checks but zero distinct-tail cases. It does not enable
CMD_RETIRE_PROBE. The directed promotion and command/retire hazards therefore
remain unclosed despite the ordinary overlap regression and replay passing.
