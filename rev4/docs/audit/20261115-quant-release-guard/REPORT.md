# Quantizer release cancellation candidate — 2026-11-15

Status: implemented; local semantic and Python tests passed; VCS pending.

Contract refinement: a bank release terminates permission for every H result
already admitted under that ownership. Such results must not be written into
a later owner's rows, including when the same external pass ID is reused.
This extends the release-edge H-buffer fence with in-flight cancellation.

Implementation in pe4_sched:

- Reject H routing against a bank being released on the routing edge.
- Carry bank and sticky killed flags through four registers aligned with
  pe4_quant's v0/v1/v2/out_valid pipeline. Release marks matching entries,
  including the incoming quantizer entry. Bubbles need no separate valid
  bits here because quant_ov qualifies the final decision.
- Also check release on the output-consumption edge. Suppress hbuf_wr_valid
  for killed results and raise ERR_H_ORDER. The original quantizer output,
  tag, arithmetic and numerical-error diagnostic remain intact.
- The model exposes pre-edge consumption: an input sampled at edge t can be
  consumed at t+4; any matching release from t through t+4 cancels it.

Eight sideband bits were introduced in source, with no additional numerical
pipeline stage and no finite generation counter to wrap. Actual area, timing,
energy and normal-traffic throughput effects are unmeasured pending synthesis
and dynamic regressions. Quantizer latency changes must update this alignment.

Verification:

- tb_promotion_v4 adds 22 white-box cases using the real quantizer: two banks
  times five release ages times two release targets, plus two no-release
  baselines. Checks exact tag and return edge, suppression and ERR_H_ORDER.
  It forces quantizer/release inputs, not pipeline internals. This does not
  establish external-interface reachability or numerical-payload correctness.
- Runner now requires CHECK quant_guard cases=22 canceled=10 independent=10
  baseline=2 before PASS promotion, exactly once.
- Python tests cover all ages/targets, bubbles, reused identities, reset at
  each pipeline age and 500 seeded stream cycles checked against an independent
  release-interval oracle rather than another shift-register implementation.
- Three Python tests and thirteen runner diagnostics tests passed. All nine
  tops passed pyslang 12.1.0 semantic elaboration (checks.json source hashes).
  No VCS simulation or synthesis was run locally.

After syncing all current sources, run from Tile_eval:

```bash
bash scripts/run_vcs.sh --test promotion --suite smoke --seed 817
bash scripts/run_vcs.sh --test memory --suite smoke --seed 817
bash scripts/run_vcs.sh --test tile --suite full --seed 817 --cmd-retire-probe --trace --calibration-trace
```

Ordinary and overlap full Tile regressions remain required after the directed
checks pass. Existing logs predate this candidate and are not evidence of it.

Limits: the guard model takes observed quantizer inputs and release pulses;
it is not yet integrated into independent continuous Tile command prediction.
The new H-buffer trace checker validates only writes that reach the H-buffer;
it does not independently verify suppression inside this guard. External H
data first arriving after reassignment with a reused pass ID remains a protocol
identity question; this design protects already admitted in-flight entries.
Routing-edge rejection also needs dynamic directed coverage beyond the 22
quantizer-input cases. These are outstanding requirements, not waived checks.
