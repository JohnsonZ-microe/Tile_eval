# First GU numeric payload replay

Both November 16 ordinary/overlap traces match the first GU's five H_UP beats in all compared fields: predicted output cycle, sideband and 128-bit payload. The first GU is FP4, one active token, pass 5, base 64, bias enabled. All 36 BF16 H elements are calculated from raw X/XS/command inputs and a regenerated RRAM image, not copied from RTL output.

The replay verifies the manifest hashes for vectors.py, tile_reference.py and the frozen reference.py oracle. It regenerates GU and D streams and the bias tail in generator RNG order, then cross-checks all four generated command weights against the received command. Every active X/XS operand is checked for missing or duplicate identities before calling the oracle (whose generic staging API otherwise defaults missing data to zero). Predicted cycle/sideband tuples come from the existing conditional continuous-output replay; its trace fingerprint must match.

## Independence and coverage limits

This uses the SAME arithmetic oracle as the testbench vector scoreboard. It provides a raw-input replay and timing/payload integration check, not an independent second implementation of arithmetic. The actual remote RRAM image is unavailable; deterministic regeneration remains an explicit assumption. No observed H output value is supplied to the producer.

The 36 elements have only four distinct BF16 values: +0, -0, 0x42d5 and 0xc2d5; no output NaNs occur. This limited output diversity does not establish general rounding/clamp coverage. Only 5 of 276 H output beats per run are covered. Remaining formats/tokens/GU phases and all Y numeric payloads remain unverified by this replay. Timing retains upstream idle/uncontended assumptions. This is not full Tile calibration or throughput/PPA validation.

Reproduce from LNS_DSE root: python Tile_eval/rev4/docs/audit/20261117-first-gu-payload/check.py. checks.json contains full expected/observed beat values and the 36 computed H codes. sources.json binds model code, input manifests, calibration traces and prerequisite timing checks. Existing simulation evidence is unchanged; no remote job was started.
