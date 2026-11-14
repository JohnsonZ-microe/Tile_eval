# YACC VCS repair acceptance — 2026-11-14

Run: vcs-20261114T042332Z-95723, full suite, seed 817, YACC component.

## Verified

The received compile and simulation steps returned zero. The raw run log and manifest agree on 300 packets, 3,000 read-identity checks, 172 overlap packets, and 18,784 yield cycles. All 86 distinct bank/offset cases are present: both banks, commit_lead -21 through +21 inclusive. Simulation completed at 98,113 testbench cycles.

All 22 snapshotted RTL/ROM and YACC testbench source hashes match the current local files. The run script snapshots rev3 sources under rtl/rev3_* and the frozen oracle under oracle/; check.py resolves those names back to their actual local locations. Full source comparisons, including documentation and auxiliary-test differences, are recorded in checks.json rather than claiming the entire project snapshot is identical.

This closes the previously pending VCS compile/numerical scoreboard gate for the interrupted DRAIN restart repair. The bench checks each payload element and packet metadata, bounds waits, validates slot release, and checks capture address identity independently of the DUT's internal address pipeline. It does not establish all-mask, multi-seed, reset-in-flight or whole-Tile coverage. The offset cases use lane masks 0001/0010; the initial slot sweep uses 1010/0101.

Local regression: test_drain_interruption.py, 3 tests passed, including 860 bank/mask/offset model combinations and a negative test retaining the old wrong-address failure.

## Waveform gate passed

The newly supplied VCD matches the recorded 58,107,988 bytes and has SHA-256
2baa34fd8477684040ef4462a322f193892b21faa91c9ad13660cb83d9a214e9.
Association also uses user-supplied provenance and agreement with all run counts;
the remote manifest records size but no waveform hash.

Independent commit timing analysis matches all 236 commits: every one of the
2,700 adjacent active-row intervals is 22 cycles. DRAIN replay matches 98,114
clock edges, 300 packets, 3,000 beats/identity checks, 3,024 read requests,
300 bitmap clears, 18,784 yield cycles and 7,490 valid-backpressure cycles.
The 24 extra reads are consistent with restart after interrupted requests.
The check uses observed commit-set/busy boundary inputs; it is component
calibration, not an independent full Tile numerical replay.

The website waveform index now binds this SHA and includes a same-bank
interruption window at 434,535,000 ps. Old historical reports remain unchanged.

## Reproduce source/log acceptance

From the project root:

    python -B Tile_eval/rev4/docs/audit/20261114-yacc-vcs-042332/check.py

To reproduce the waveform checks, write new output files for the commit timing and DRAIN replay checkers:

    python -B Tile_eval/rev4/model/yacc_wave_timing.py Tile_eval/vcd/yacc_v4.vcd --out NEW-COMMIT.json --check-commit
    python -B NPU_eval/af/vcd_drain_check.py Tile_eval/vcd/yacc_v4.vcd

## Next integration gate

The YACC pass permits proceeding to the full Tile numerical and trace run. From Tile_eval/rev4 on the VCS host:

    bash scripts/run_vcs.sh --test tile --suite full --seed 817 --waves --trace --calibration-trace

Then collect a separate overlap run:

    bash scripts/run_vcs.sh --test tile --suite full --seed 817 --overlap --trace --calibration-trace

Retain manifests, snapshot sources, logs and calibration-events.csv. These runs were not launched by this audit. Independent whole-Tile replay of matching inputs/credits remains necessary before cycle-accurate calibration can be claimed. Physical PPA and complete AF throughput are still open. Historical manifests and reports were not rewritten.

## Web validation

All four local-wave resource tests passed, including real transition anchors and all signal names. The live backend was reloaded after confirming no active jobs; its YACC API reports matchesIndex=true with all four views enabled. Console regression: 263 tests, 258 passed, 4 pre-existing failures, 1 skipped. The former YACC waveform hash failure is resolved. Remaining failures concern audited snapshots, compute manifest binding, local development snapshots and protocol inventory boundaries. No browser visual inspection was performed in this update.
