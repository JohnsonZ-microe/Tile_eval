# External-input GU/D timing validation — 2026-11-15

Both ordinary and overlap full Tile runs match all 48 GU/D phase predictions.
Each run has 108600 memory issue/consume events and 103680 PE accepts; D alone
accounts for 36096 issues/consumes and 34560 PE accepts. All compared cycle
differences are zero, with matching addresses and relevant descriptors/tags.

D uses the external CMD edge plus one and independently predicted GU final
memory consumption plus one as its earliest issue origin (empty RQ/start
rule). It does not use observed GU completion or RTL issue times. Bias words
may issue before H is ready. Matrix/scale issue is fenced until H completion.

H readiness is derived from external H edges: H at E0 registers quant input;
quant accepts at E1, its v0/v1/v2/out pipeline is sampled by hbuf at E5, and
scheduler reads the resulting ready state at E6. The adapter requires exactly
72 unique rows per active lane, rejecting missing/duplicate/wrong-lane data.
Thus ready is last H input + 6, with no timing fit to the measured outputs.
Payload values are not evaluated by this timing replay.

phase_replay.run_phase now accepts explicit d_ready_cycle only for phase D.
The existing default ideal-operand mode is preserved for older experiments.
Three regression tests verify bias-only prefetch during the fence, readiness
at zero equivalence, and invalid parameter rejection.

Scope: per-phase timing, given legal admitted CMDs, settled CTX, native ordered
inputs, initially empty isolated core/RQ and legal H ownership. Full slot
lifecycle and overlapping ownership are still not independently reproduced;
H_UP, Y commit/DRAIN, complete numerical outputs and cross-Tile traffic remain
outside this comparison. Exact agreement on these traces is not complete Tile
calibration. The same-edge admission/retirement hazard remains open.

Reproduce from project root:

    python -B Tile_eval/rev4/docs/audit/20261115-d-input-timing/check.py
    python -B -m unittest discover -s NPU_eval/af/tests -v

checks.json retains each case, explicit origin/H-ready edges, and source trace
hash. sources.json binds model dependencies. Prior reports were not rewritten.

Final AF regression: 139 tests passed in 53.415 seconds. The obsolete 216-packet YACC fixture assertion was replaced with the independently verified 300-packet VCD hash, 3024 reads and 3000 identity checks; negative metadata/address/truncation and legacy-arbitration checks remain active. See af-tests-final.log. The first run's fixture failure is retained in af-tests.log.

