# First D numeric payload replay

Both received November 16 runs pass comparison of the first D scenario's ten Y output beats: every 128-bit payload, predicted output cycle and sideband matches. The producer reads 72 raw BF16 H input blocks, quantizes them, computes D, applies bias/weight and Y commit, then decodes the external DRAIN descriptor and formats its output. All active H identities must be present exactly once; missing data is rejected before invoking the generic oracle.

This scenario is FP4, one token, pass 5, bias enabled, base 64. The 80 Y BF16 elements contain 79 distinct codes. The RRAM image is regenerated in the original RNG order; source hashes for vectors.py, tile_reference.py and reference.py match the run manifest and regenerated command weights match the received GU command. No observed numeric Y or internal quantizer value enters the producer. Timing and sideband come from the prior conditional continuous-output prediction, bound to the same CSV fingerprint. DRAIN decoding here uses explicit extra ticks only to obtain the descriptor; those ticks are not used as a timing prediction.

## Sensitivity check

negative-zero-h.py replaces the producer's H payloads with zero while retaining the received comparison outputs. Both runs then fail payload and full timed-beat comparison as required (exit 1; negative.log and negative-checks.json). The original CSV and positive checks.json are preserved. This is a sensitivity test, not additional RTL coverage.

## Limits

The arithmetic is the existing scoreboard oracle, not an independently implemented second oracle. Remote RRAM bytes remain unavailable, so deterministic image regeneration is an assumption. Only 10 of 600 Y beats per run are covered here; the earlier first-GU audit covers 5 of 276 H beats. Other formats, multi-token phases, later accumulations, arbitrary segmented drains, resets and simultaneous producer contention are not established by these checks. The input gathered H represents the environment and is not a model of other tiles. Full AF/Tile timing and PPA remain incomplete.

Run from LNS_DSE root: python Tile_eval/rev4/docs/audit/20261117-first-d-payload/check.py. Checks include complete predicted/actual beats. sources.json records SHA-256 fingerprints of code and evidence. No RTL, received logs or remote jobs were modified.
