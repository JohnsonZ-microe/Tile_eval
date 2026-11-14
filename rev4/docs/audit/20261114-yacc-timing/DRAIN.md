# DRAIN arbitration replay — 2026-11-14

Current RTL scope: pe4_yacc drain_yield blocks DWAIT whenever cstate is not
CIDLE on the same bank. The arithmetic wait and CDONE edges count as busy.
YControlReplay previously supplied only CRD as the blocking interval. It now
samples the old commit state and supplies every non-idle state to DrainReplay.
Other-bank accesses remain independent; DSEND is not stalled by this fence.
The internal DrainReplay argument commit_read_bank denotes the externally
supplied blocking bank; no public argument was renamed.

The existing VCD checker now defaults to whole-commit arbitration. Historical
read-active arbitration is available only through explicit --arbitration
legacy-read. It fails on the current overlap waveform rather than silently
accepting old behavior. Read identity checks remain strict on every capture;
no interleaved-read exemption was added.

## Evidence

VCD SHA-256: 27cf59be941dd90b13cd91bf32ed46934d7a7d4fe23f2ea35913ef56e434c89e
Input: Tile_eval/vcd/yacc_v4.vcd, supplied 20261114 YACC run.

The checker passed 71276 clock edges, 216 commands/packets, 2160 output beats,
2160 read requests, 2160 read-identity checks, 216 bitmap clears,
9394 same-bank yield cycles, and 6020 output-valid backpressure cycles.
It checks DRAIN metadata, read requests/addresses, output valid timing,
clear requests and arbitration; numerical payload checking remains the RTL
bench scoreboard's responsibility. Commit state and set events are observed
boundary inputs, so this is component verification rather than independent
whole-tile input replay.

From the earlier raw timing records: 44 concurrent DRAIN packets waited
203..224 yield cycles, each duration occurring twice (two banks). All 396
intra-packet handshake intervals in those always-ready cases equal 7 cycles.
For all 44, first_handshake - drain_accept - yield_cycles = 7.
Thus the six-cycle DRAIN interval in the old analytical/tree model is not
validated by this RTL. Bank ownership, first-read latency, backpressure and
launcher arbitration must be integrated together in the performance model.

## Regression

From the LNS_DSE root:

    python -B NPU_eval/af/vcd_drain_check.py Tile_eval/vcd/yacc_v4.vcd
    python -B -m unittest discover -s NPU_eval/af/tests -p test_y_control_replay.py -v
    python -B -m unittest discover -s NPU_eval/af/tests -p test_vcd_drain_check.py -v
    python -B -m unittest discover -s NPU_eval/af/tests -p test_drain_replay.py -v

5 composition tests, 3 waveform tests and 4 DRAIN tests passed. Negative tests
reject wrong metadata, wrong request/port addresses, truncated traffic and
legacy arbitration. The old artificial set/clear collision sequence now
correctly waits through the commit and clears after it; clear-after-set bitmap
implementation is retained. Wait/CDONE fencing and opposite-bank freedom are
explicitly checked.

No RTL change or new VCS job was made. Existing legacy read-port diagnostic
scans retain their historical policy and known race reproduction; they are not
claimed as current-arbitration calibration. Physical area/energy, full Tile
coverage, analytical launcher integration and web presentation remain open.
