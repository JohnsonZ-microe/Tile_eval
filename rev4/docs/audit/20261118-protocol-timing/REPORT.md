# Protocol RTL contention timing — 2026-11-18

Analyzed the actual VCD from vcs-20261117T014645Z-83541, SHA256 matched to the previous successful bus replay audit. Case identification uses the testbench's unique Y first payload 0x12340000 and reset boundaries. Token count is inferred from actual H beat count. Credit delay is measured by matching returned credits FIFO-wise to actual accepted outputs; every return within a case must have the same delay. A complete 4-token-count × 5-delay matrix is required. Internal arithmetic/producer models are not used to derive these timings.

Within each Y packet, every edge is assigned exactly once to accepted Y data, source-invalid bubble or source-valid zero-credit stall. All 20 cases contain 10 accepted Y beats and 54 source bubbles. Delays 1/6/7/16 have zero Y credit stalls (64-edge inclusive span); delay 64 adds 23 credit stalls (87-edge span). H becomes ready three edges after the first Y beat and therefore encounters 52 of the 54 bubbles. The remaining blocked cycles include successful Y beats and any credit stalls; these are not all source bubbles.

For one token and return delay 1, H is first accepted at relative edge 64, finishes at 68, and STATUS is accepted at 69. This directly confirms the timing-only model's packet-lock interpretation. Edge zero is each case's first accepted Y beat; the experiment's global capture/commit schedule is not part of this RTL probe.

| Tokens | Credit return delay | Y packet edges | Y credit stalls | H last edge | STATUS edge |
|---|---|---|---|---|---|
| 1 | 1 | 64 | 0 | 68 | 69 |
| 1 | 6 | 64 | 0 | 68 | 70 |
| 1 | 7 | 64 | 0 | 68 | 71 |
| 1 | 16 | 64 | 0 | 73 | 80 |
| 1 | 64 | 87 | 23 | 144 | 151 |
| 2 | 1 | 64 | 0 | 72 | 73 |
| 2 | 6 | 64 | 0 | 73 | 74 |
| 2 | 7 | 64 | 0 | 74 | 75 |
| 2 | 16 | 64 | 0 | 83 | 84 |
| 2 | 64 | 87 | 23 | 195 | 202 |
| 3 | 1 | 64 | 0 | 77 | 78 |
| 3 | 6 | 64 | 0 | 79 | 80 |
| 3 | 7 | 64 | 0 | 81 | 82 |
| 3 | 16 | 64 | 0 | 99 | 100 |
| 3 | 64 | 87 | 23 | 230 | 260 |
| 4 | 1 | 64 | 0 | 81 | 82 |
| 4 | 6 | 64 | 0 | 84 | 85 |
| 4 | 7 | 64 | 0 | 87 | 88 |
| 4 | 16 | 64 | 0 | 114 | 115 |
| 4 | 64 | 87 | 23 | 281 | 288 |

The source intentionally offers Y at seven-edge spacing after acceptance. Thus this is measured bus/arbitration behavior for a synthetic source, not a measurement of physical SRAM throughput or end-to-end Tile performance. Reducing Y source bubbles could release packet ownership earlier when credit is available; this evidence alone cannot prove the proposed producer change, energy savings, area cost, or application TPOT improvement.

The analyzer checks payload ordering, no H interleaving before Y completion, six-credit conservation, no unearned returns, complete case counts and interval accounting. Two focused tests passed, including corrupted payload/credit and truncated-matrix rejection. Full AF regression was not rerun for this standalone analysis; tests.log records the focused run. All case metrics are in checks.json and input hashes in sources.json.
