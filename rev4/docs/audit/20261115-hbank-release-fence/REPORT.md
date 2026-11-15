# H-bank release/write fence candidate — 2026-11-15

Status: implemented, local semantic checks passed, dynamic RTL validation pending.

Source: current pe4_hbuf ownership and full-row fence contract. Release ends
the old owner's write permission on that edge. A simultaneous new take must
start with no rows valid. This local refinement does not change command admission.

Before this change a write to an owned, unwritten row could pass validation
against pre-edge state while release and take reassigned that bank. The later
lane_seen assignment then marked an old write as belonging to the new owner.
The Python edge model reproduced that module-port counterexample; this is not
proof that the sequence is reachable from legal full-Tile traffic.

pe4_hbuf now includes same-bank release in wr_bad. This existing gate inhibits
SRAM, scale and validity writes together and pulses wr_err. Release/take still
updates ownership. Writes to the other bank retain their existing behavior.
There is no additional pipeline stage. Area, energy and critical-path impact
have not been synthesized or measured.

Verification added:

- Python: both banks, release with/without retake, error pulse, fresh-owner
  retry and unaffected writes while the other bank is released/reassigned.
- Memory RTL testbench: four release/write rejection cases, two independent
  bank write cases. An earlier ownership generation seeds SRAM and scale;
  the tested generation has a clear row-valid bit, avoiding rejection merely
  due to a duplicate. Readback checks data/scale preservation; a hierarchical
  row-valid observation checks the fence. All stimulus uses module ports.
- Runner requires unique complete handoff and release/write CHECK lines before
  PASS memory. Missing, partial, duplicate and reordered evidence is rejected.

Local results: 7 HBankOwnership tests passed; 13 runner diagnostics tests
passed. checks.json binds 9 successful pyslang 12.1.0 top-level semantic
compilations to source hashes. These are not dynamic RTL simulation results.

After syncing current sources, run from Tile_eval:

```bash
bash scripts/run_vcs.sh --test memory --suite smoke --seed 817
```

Required new marker: `CHECK hbank_release_write rejected=4 independent=2`.
Scheduler promotion and CMD-retire candidate regressions remain separately
required, followed by ordinary and overlap Tile regression. The received
vcs-20261115T095649Z-37967 artifacts predate this change and cannot validate it.

Open: quantizer tags carry bank/lane/row, not ownership generation. This fence
only handles writes on the release edge; stale writes arriving after a new
take need reachability analysis or generation tracking. The Python ownership
model accepts caller-supplied pulses and does not independently predict
scheduler admission, payload, SRAM timing or full continuous Tile execution.
