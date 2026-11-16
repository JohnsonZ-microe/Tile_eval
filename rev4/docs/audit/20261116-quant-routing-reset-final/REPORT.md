# H routing-register reset candidate — 2026-11-16

Status: implemented and locally checked; dynamic RTL validation pending.

Inspection found quant_valid assigned only in the non-reset branch of the
scheduler. If it was high when reset arrived, the routing register retained it
while pe4_quant reset its own pipeline. On the first non-reset edge, the
quantizer could sample the old valid/data before the scheduler cleared valid.
This is a sequential-source counterexample, not a newly observed VCS failure.

Added quant_valid <= 0 to the synchronous reset branch. Payload/tag registers
need not be cleared when valid is zero. No new state bit, data pipeline stage,
or normal-path latency is introduced; physical reset-cell/PPA impact is not
measured. Historical passing runs predate this candidate and remain immutable.

Ten new promotion-suite cases use real routing and quantizer state, forcing
only scheduler H/owner inputs: two banks times five reset ages (routing register
and four quantizer stages). Each checks immediate validity clearing, six quiet
cycles with no stale output, then new-row identity and original recovery latency.
Runner requires CHECK quant_reset cases=10 routing=2 pipeline=8 recovery=10.
The previously validated 22 cancellation and four routing cases remain.

The HQuantRouting Python component now composes the one-edge routing register
with QuantWriteGuard. H acceptance at edge t can be consumed at t+5. Reset
flushes both parts. It takes observed owner/release inputs and checks routing
pass/index semantics, leaving lane/token validation to H-buffer. It does not
model numeric quantization, independent command admission or external stale
H traffic with a reused pass ID.

Checks: four routing-model tests, thirteen runner tests and two trace-source
tests passed. All nine tops passed pyslang semantic compilation (checks.json).
The first compilation found a current-worktree diagnostic using rq_probe_cycle
before declaration; its declaration was moved before use without removing or
changing the diagnostic. The initial failed compile is preserved in adjacent
20261116-quant-routing-reset. No VCS or synthesis was run here.

After syncing this candidate, validate with:

```bash
bash scripts/run_vcs.sh --test promotion --suite smoke --seed 817
```

Ordinary/overlap full regression should use the same final source snapshot.
The earlier six-run UI inventory is explicitly a snapshot, not current live
source matching. Completion of the broad Tile/AF/PPA objective is not claimed.
