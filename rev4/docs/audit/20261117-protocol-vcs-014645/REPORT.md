# Protocol VCS rerun audit — 2026-11-17

Run: `vcs-20261117T014645Z-83541`, full suite, seed 817, waves enabled.

Passed: remote exit code 0, unique contention marker before protocol PASS, 20 contention cases (4 token counts × 5 credit-return delays), packet lock and credit conservation. Protocol totals: FIFO 728, upstream 1024 (H 489, Y 350, STATUS 185), credit cases 42.

Local Python bus replay passed all 4,767 sampled edges, including 66 reset edges. Observed arbitration: 519 H/Y/STATUS contention edges, 1,386 H-blocked-by-Y-lock edges, 1,046 Y-lock bubble edges with H waiting, 623 H credit stalls and 262 Y credit stalls. The exercised overflow edge is intentional negative-test coverage. These counters cover the whole bench, not only the 20 added cases.

Waveform: 6,725,458 bytes. SHA256 matches the local sync receipt tagged with this run; size matches the remote manifest. The remote manifest does not provide a waveform SHA256. Bus RTL and protocol testbench match source hashes exactly; runner matches after CRLF-to-LF normalization. See checks.json and sources.json.

Scope: bus protocol, packet arbitration and credit behavior, using sampled source inputs for Python replay. The testbench supplies a synthetic Y stream; this does not verify actual Y SRAM contention, full Tile scheduling, independent arithmetic, physical timing or PPA. The new 20-case probe is now dynamically validated.
