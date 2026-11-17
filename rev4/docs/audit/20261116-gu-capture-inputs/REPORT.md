# GU capture prediction from external inputs

The new predict_gu_captures interface derives GU configuration, ingress identities and arrival cycles solely from external reset/down/credit records. It runs the core model and emits capture edges suitable for ContinuousOutputReplay. It does not reset or simulate bus credits and consumes no observed completion or ACT outputs.

The interface requires explicit idle-CTX and uncontended-core assumptions. It rejects unsupported ingress identities, reused GU pass IDs, multiple epochs and overlapping GU core intervals. It does not model D/GU core contention or scheduler admission; the uncontended assumption cannot be removed yet.

Validation: three tests passed, covering connection to the persistent output model, delayed-X causality and rejection of output observations/missing assumptions. The received ordinary and overlap traces are checked separately in checks.json: predicted capture+1 is compared with the first ACT acceptance (transaction 0). This indirect capture observation validates the first downstream ACT edge; the RTL does not expose a dedicated capture event in these CSVs.

This advances core-to-output composition but is not a complete continuous Tile prediction. Next integration must supply independently generated D commit/drain/STATUS behavior and share scheduler resources. Existing isolated retirement prediction and historical evidence were not changed.
