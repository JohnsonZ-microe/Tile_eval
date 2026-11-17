# Persistent H/Y/ALARM payload handshake replay

ContinuousOutputReplay now accepts optional precomputed drain_payloads at an accepted DRAIN command. It snapshots the exact number of 128-bit rows, validates widths and partial-row zero masks, rejects nonzero data for an invalid slot, and selects data using the current DRAIN row. Row advancement remains controlled by the real bus handshake. Reset/final drain completion releases the snapshot. Missing payloads retain the explicit timing-only zero-data mode. DRAIN/CTRL/ALARM adapters forward this optional argument at the decoded command edge.

The 60 Y packets from the preceding raw-input numeric audit are assigned in external DRAIN-command order, with its registered one-edge decode delay. They are not assigned from observed output cycles. H packets remain keyed by predicted capture/pass. Both use shared-oracle numeric results, not observed RTL output data. Real external credits and persistent bus arbitration determine the emitted cycles.

checks.json records complete 877-tuple comparisons (cycle, full sideband, 128-bit payload), covering 276 H, 600 Y and one ALARM in each received run. GU retirements, Y-ready/drain identities, final errors and empty slots remain independently checked. af-regression.log records full local tests; targeted continuous tests include credit exhaustion/recovery, caller-list mutation, reset, partial rows, invalid slots, and non-final segment ownership.

## Scope

This is packet-data transport integration, not a numerical SRAM/accumulation model. Y values are frozen at DRAIN launch; same-slot writes after launch and concurrent numeric COMMIT/DRAIN behavior are not represented. The scalar control model still provides slot validity and handshake timing. ACT/D arithmetic remains precomputed via the shared scoreboard oracle and regenerated RRAM image. Upstream capture/retirement assumptions and absence of H/Y contention in the received workloads remain unchanged. The result does not establish arbitrary concurrency, independent arithmetic, realistic AF throughput or PPA.

Reproduce: python Tile_eval/rev4/docs/audit/20261117-streamed-hy-payload/check.py. No RTL or received traces were changed; previous audits are preserved.
