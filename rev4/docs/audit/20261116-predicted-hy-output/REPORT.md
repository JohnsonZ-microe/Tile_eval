# Predicted H/Y outputs on one persistent bus

Two received traces (ordinary and overlap) each match all 876 H/Y output edges and complete sidebands, 24 GU retirement edges, 60 Y-ready edges, 60 decoded DRAIN edges, and empty Y valid-slot state at completion. GU capture schedules and D commits come from external-input conditional predictors; their trace hashes and artifact hashes are preserved. Observed output records are only compared after prediction.

The model uses one persistent shared H/Y bus with six credits initialized once. Credit feedback is synthetic: each predicted transmitted beat returns one credit on the next edge. It is not reset between phases. STATUS production is absent; numeric payloads are not checked. Upstream D timing still inherits idle-commit and isolated-phase assumptions. Matching the upstream predicted GU retirement confirms consistency for this workload, not a general proof of scheduler correctness.

## Coverage limitation and failed assumption probe

Both workloads have ZERO edges where modeled H and Y sources simultaneously request. Their agreement therefore cannot establish contested H/Y arbitration or saturated throughput. Earlier protocol component waveforms and directed model tests remain separate evidence.

A second probe feeds actual external credit events into the same model with STATUS absent. Both runs report the first credit overreturn at cycle 107487 (one credit returned). status-gap.json records the observed STATUS/ALARM output separately for diagnosis, never as a producer input. This discrepancy is retained and is not counted as a passing real-credit replay. The missing output consumes a credit in RTL but not in this partial model.

Next work is independent generation of the STATUS/ALARM event from control/error state, followed by actual-credit replay and a genuine competing H/Y workload. Do not seed the missing producer from observed up_beat, discard the inconsistent return, or present synthetic-feedback agreement as full external-input calibration.

Reproduction: regenerate gu-capture-inputs and d-commit-inputs audit artifacts, then run check.py. Detailed comparisons, the real-credit discrepancy and source hashes are retained here. No RTL, manifests or old audit results were changed.
