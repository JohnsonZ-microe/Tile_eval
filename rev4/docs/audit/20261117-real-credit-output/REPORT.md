# Actual-credit persistent H/Y/ALARM replay

Both received November 16 ordinary and overlap workloads match 877 upstream edge/sideband tuples (276 H, 600 Y, one ALARM), the ALARM payload, 24 GU retirements, 60 Y-ready events and 60 DRAIN identities. No credit overflow occurs using the actual external credit records. Persistent bus state is initialized once, not reset per phase. All Y slots are drained at the end.

The missing ALARM is generated from first-GU accepted input error classifications. The first GU weight image is regenerated with seed 817 and the matching vectors.py source, activation/XS bits come from raw down records, and accepted PE cycles come from the core model. Classified errors update sticky at accept+35; the following edge supplies scheduler events. AlarmReplay and bus arbitration generate the output. Observed ALARM timing/payload never drive the producer. The first-GU input schedules are checked equal between the two runs before reusing classifications.

The prior synthetic-credit replay is preserved separately. Its failure under actual credits is resolved for these two workloads by supplying the missing modeled producer, rather than dropping a credit or seeding an observed output.

Limitations: the remote rram.hex is unavailable, so regenerated weights are conditional on deterministic generator/environment equivalence. Only first-GU PE errors and pass-5 first-error identity are modeled here; later error sources and register-state handling are not generalized. control-scope.json records writes to W1C/mask registers for review. Core and D commit schedules retain the earlier idle-context/uncontended-core/idle-commit assumptions. H/Y numerical payloads are not predicted. H/Y simultaneous-request count is zero in both runs. Full output agreement here does not establish saturated throughput, generic error handling, all numeric behavior, or PPA.

Reproduction requires the first-GU numeric, GU capture and D commit audit artifacts, followed by check.py. sources.json binds the artifacts and model code. Historical logs and audits are unchanged.
