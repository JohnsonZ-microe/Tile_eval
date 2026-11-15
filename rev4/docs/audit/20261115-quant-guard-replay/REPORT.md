# Quantizer guard trace replay and routing cases — 2026-11-15

Status: implementation and local tests passed; new VCS evidence pending.

The prior guard audit left routing-edge coverage and trace-level suppression
checking open. This change adds both test mechanisms without claiming dynamic
closure. Existing reports and historical artifacts remain unchanged.

Calibration trace additions:

- quant_guard_config at each reset, pre sample, payload=4 identifies the
  four-cycle input-to-consumption contract. Legacy traces lack this marker.
- quant_discard on each stale quantizer output, pre sample; transaction is
  the full bank/lane/row tag, bank is the selected bank, payload is observed
  ERR_H_ORDER. quant_consume continues to record every numerical output.
- Existing bank_write records only actual attempted H-buffer writes after
  suppression. It does not assert that the H-buffer accepted the write.

NPU_eval/af/quant_guard_trace_replay.py predicts output timing, identity,
cancellation and write gating from quant_accept plus bank_release. It compares
quant_consume, quant_discard, error and bank_write; these observations never
drive the model. Sparse gaps are advanced through all pending pipeline stages,
and remaining idle cycles can then be skipped. Reset flushes pending inputs.
Missing configuration, wrong stage, duplicates, missing/shifted output and
truncated pending transactions fail validation. Zero cancellations are reported
as zero, not interpreted as release-hazard coverage.

The promotion testbench adds four routing cases using forced scheduler inputs
and real routing logic: two same-bank releases must reject H, while two
other-bank releases preserve routing and correct selection. The runner gates
CHECK route_guard cases=4 rejected=2 independent=2 before PASS promotion.
The previously added 22 quantizer guard cases remain required.

Local checks:

- 6 quantizer trace checker tests passed, including deliberate mutations.
- 13 runner diagnostics, 2 Tile trace source tests, 13 calibration tests passed.
- 9 tops passed pyslang semantic elaboration; checks.json binds RTL/TB hashes.
- The actual vcs-20261115T095649Z-37967 CSV was rejected for missing guard
  evidence. This expected failure does not overturn its earlier scoped checks.
- The old source test asserting the take-bank selector was updated to require
  the independent release selector in both traces and its DUT connections.

No dynamic RTL simulation or physical implementation was performed here.
After synchronizing the current sources, promotion smoke collects the new
routing cases. A full Tile run with --calibration-trace collects replay data.
From LNS_DSE, check the new CSV with:

```bash
python NPU_eval/af/quant_guard_trace_replay.py Tile_eval/logs/<new-run>/calibration-events.csv
python NPU_eval/af/hbank_trace_replay.py Tile_eval/logs/<new-run>/calibration-events.csv
```

Remaining scope: real trace validation, numeric H payload comparison, independent
H admission and continuous whole-Tile lifecycle prediction, external stale data
arriving after pass-ID reuse, ordinary/overlap regression and measured PPA.
These component checkers do not independently predict command scheduling or
prove full Tile correctness.
