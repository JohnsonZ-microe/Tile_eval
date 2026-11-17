# Command error events and conditional output replay

The prior final-error mismatch is resolved for both received November 16 traces. The model now predicts CMD_ILLEGAL from external command descriptors and context/slot state. It does not inject the expected final error bit. The expected register value is read only for the terminal comparison.

## Changes and verification

ContextReplay now gives SCAN phase 2 UNSUPPORTED priority, matching pe4_sched.sv. Malformed command fields reject independently of uninitialized context; valid commands against unknown context still fail explicitly. AdmissionHReplay exposes the old registered command error pulse for error-accumulator consumption and the newly scheduled pulse separately. Reset flushes both. Slot fullness remains the pre-edge state, including simultaneous retirement.

The admission replay predicts bit 2 at cycle 355988 for vcs-20261116T004029Z-67940 and 355916 for vcs-20261116T011416Z-108706. Both retain matching 24 bank takes, 24 releases, 4320 writes, and 4368 observed bank states. Event timing is model-derived; the internal error-register waveform is not separately compared here.

Feeding these events into the persistent actual-credit H/Y/ALARM replay produces final error status 0xe0004 for both runs, equal to each run's expected check value. All 877 output edge/sideband tuples, ALARM payload, 24 GU retirements, 60 Y-ready events, drain identities, and final empty Y slots still match. No credit overflow occurs.

Full AF unit regression: 234 tests passed in 43.715 seconds. Log: ../20261117-command-error-events/af-regression.log. Tests include descriptor boundaries, SCAN priority on full slots during retirement, one-edge error timing, first-error identity sampling, and reset cancellation.

## Reproduction and limits

Run ../20261117-command-error-events/check.py first, then check.py here. sources.json fingerprints current sources, prerequisite audit artifacts, simulation traces and expected checks. The earlier mismatch report remains a historical snapshot.

Retirement scheduling remains conditional on the earlier idle-context, isolated-core/bus and idle-Y assumptions. First-GU numeric classification and pass-5 identity remain scoped inputs; generated weights assume deterministic equivalence with remote generation. H/Y numerical payloads, complete error-register trajectories, generic concurrent workloads, coverage closure and PPA remain unverified. H/Y contention is zero in these traces. Terminal error equality is not complete Tile calibration.
