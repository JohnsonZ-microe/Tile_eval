# Ordinary versus overlap: measured cycle intervals

Scope: seed 817 full suite, 24 scenarios / 48 phases, received 2026-11-16. This is a paired testbench timing diagnostic, not application throughput or PPA measurement.

| Interval (edge differences, cycles) | Ordinary | Overlap | Saved |
|---|---:|---:|---:|
| First legal phase CMD to final SYNC1 | 247514 | 247442 | 72 |
| First legal phase CMD to final output beat | 248691 | 248619 | 72 |

The output-completion window falls by 0.02895%. Both runs have 108600 memory issues, matching pass/phase/format identities, and identical request counts per phase. Full per-phase intervals are in checks.json. Each phase is partitioned additively into command-to-first-issue, first-issue-to-last-PE-accept, and last-PE-accept-to-SYNC1; these boundaries do not classify causal stalls. Summing phase latencies is invalid for elapsed throughput when commands overlap.

## Why this does not establish saturation throughput

In tb_tile_v4.sv, ordinary mode waits for prior completion before sending D CMD (line 582). Overlap removes that wait, but pending_gather_fence still waits for GU completion before the first H flit (lines 584-587, 621-622). Every drain waits for completion and Y readiness, and then waits for its packet (lines 591-594, 636). Thus early D admission does not provide early H readiness or a continuous workload. Longer D CMD-to-first-issue intervals in overlap largely reflect earlier command arrival and cannot be described as extra RTL control latency.

The per-phase last-PE-accept-to-SYNC1 intervals are unchanged between both runs. The 72-cycle global reduction is therefore not evidence of a faster compute epilogue. Distinct-tail promotion coverage is zero in this full-suite overlap run; separate directed coverage must remain separate.

## Next performance verification requirements

Create a separate bounded throughput workload with at least two independent passes, explicit bank ownership, legal H return timing, finite input/output credit, and delayed/draining output scenarios. Preserve the existing full-suite correctness replay. Record accepted command, first and last memory/PE activity, H-ready, retirement, Y-ready and final output per pass. Measure completion intervals after warmup and report both startup and steady-state behavior. Compare against a continuous shared-bus Python model before using results in multi-tile AF estimates. No frequency, energy, area or real-application throughput is inferred here.

## Reproduction and provenance

Run check.py in this directory with Python. It verifies trace hashes against the independently predicted retirement audit, checks all 48 sampled completion cycles, checks unique commands and ordered issue edges, and pairs phase identities/request counts before calculating differences. sources.json binds the analyzer, instrumentation and upstream prediction artifacts. Original logs are unchanged.
