# Raw protocol error output replay audit

Both November 16 runs pass the existing output-scope checks: 877 upstream edge/sideband tuples, ALARM payload, 24 GU retirements, 60 Y-ready events, drain identities, and empty final Y slots. Actual external credit returns are used throughout; no per-phase bus reset or credit overflow occurs.

The updated producer models raw reserved flits, PGM errors, targeted CTRL operation errors, registered credit errors, and W1C/mask handling. Scheduler errors and first-error pass identity remain explicit inputs. This workload has no W1C/mask writes; those paths are covered by local unit tests, not these two traces.

## Unresolved error-state mismatch

For each run, the supplied RTL check expectation is 0xe0004, while the model ends at 0xe0000. Missing bit 2 is CMD_ILLEGAL; there are no unexpected modeled bits. coverage-assessment.json records this separately from checks.json, whose passed flag applies ONLY to its enumerated output checks. Neither result proves complete error-register equivalence or complete Tile calibration.

RTL pe4_sched.sv generates CMD_ILLEGAL from command fields, context legality, or both command slots being occupied. Independent prediction must respect registered ingress timing and old-state slot fullness; copying the final expected bit into the producer would not validate this behavior.

Other limitations: first-GU PE errors and pass-5 identity only; regenerated weights depend on deterministic generator equivalence; upstream core/commit timing retains idle/uncontended assumptions; H/Y numerical payloads are not checked; neither workload has simultaneous H/Y requests. These results do not establish saturated throughput, general numerical correctness, coverage closure, or PPA.

## Evidence

check.py and checks.json contain the replay and results. sources.json fingerprints the current model code, input audits, manifests, expected checks, and calibration traces at this audit snapshot. coverage-assessment.json explicitly records the remaining mismatch. af-regression.log records the subsequent full local AF regression; inspect its terminal summary for status. Historical simulation manifests and prior audits were preserved.
