# Full-suite raw-input numeric replay

This audit expands the first-GU and first-D experiments to all 24 full-suite scenarios: six formats by one through four tokens. It reconstructs both weight streams and bias tails in the original seeded RNG order. Every X/XS operand and gathered H block must exist exactly once; the generated values, command weights and local H loopback are checked against raw inputs. Both runs must have identical ordered down-sideband/payload inputs before sharing numeric computation; their timing predictions and output comparisons remain separate.

Arithmetic uses the existing vector scoreboard oracle. The remote RRAM image is unavailable; seeded image reconstruction is an assumption. Identical input reconstruction and matching source fingerprints strengthen reproducibility but are not a second arithmetic implementation or a physical-memory check. Timing still comes from the earlier conditional model. Neither trace establishes sustained H/Y contention, arbitrary accumulation/segmentation, complete coverage, PPA or full AF timing.

## Evidence interpretation

check.py performs numeric generation and output comparison. progress.json is only a progress checkpoint, never proof of completion. A terminal checks.json is required. The initial in-flight invocation had incorrect bit offsets in its final metadata-only assertion (last bit 8 and segment bits 17 instead of last bit 17 and segment bits 20); the corrected source is retained. Numeric production and expected cycle/payload comparisons were unaffected. recheck_metadata.py independently derives packet sidebands from received GU and DRAIN commands, verifies the saved numeric results, and writes final-checks.json. Consult final-checks.json for the complete result; do not infer pass from this report or progress alone.

The sideband recheck preserves any initial failed checks.json instead of rewriting it. H/Y numerical payloads are recomputed without consuming observed up payloads. Final comparisons cover output cycle, full sideband and 128-bit payload; ALARM remains covered by the separate existing error/output audit.

## Completed result

All 24 scenarios completed. final-checks.json reports payload=true, timed_beats=true and metadata=true for BOTH runs: 276 H beats plus 600 Y beats per run (876 complete cycle/sideband/payload tuples). Coverage includes formats 0 through 5, token counts 1 through 4, and alternating enabled/disabled bias. The original invocation terminated with exit 1 solely because of its metadata bit-offset bug; its checks.json is preserved, including true payload/timed-beat checks. The independent metadata recheck terminated with exit 0. initial-run-source.py.txt reconstructs the exact initial source before that known correction; current check.py contains the corrected check for future reproduction.

This closes the H/Y numeric-payload gap for these two received workloads under the stated shared-oracle, image-regeneration and conditional-timing assumptions. It does not close full Tile independence, arbitrary concurrent scheduling, multi-seed/functional/code coverage or PPA. Full output agreement does not turn the sequential testbench workload into evidence of real saturated multi-tile throughput.
