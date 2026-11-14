2026-11-14: YACC commit rows corrected from 17 to 22 cycles using 152 commits
from the supplied VCS waveform. Disabled-lane scan cycles and next-edge valid
consumption are included. See audit/20261114-yacc-timing/REPORT.md for all-event
comparison, source identity, model impact and coverage limits. This validates
only the commit schedule for observed masks. The standalone DRAIN launcher still
uses an obsolete CRD-only yield approximation whereas current RTL blocks DWAIT
throughout a same-bank commit; whole-tile timing is not calibrated.
# Rev4 tile timing model (`model/tile_cycles.py`) — not RTL-calibrated

2026-11-12: standalone `_fill` now marks an X/XS group ready only after the
last active token in its generated ordered sequence has been popped. Previously
the first token prematurely made the whole group ready. RTL `exp_lane+1>=gl`
is the source of this all-token fence. Native/generic fill overrides already
count token completions separately and are unchanged by this correction.
The standalone model still assumes ordered contiguous token lanes and abstracts
the registered pop/write/issue edge sequencing; this correction alone does not
calibrate that complete path. The new diagnostic snapshot is
`reports/af-estimate/20261112-throughput-v2`; v1 remains historical.

2026-11-12: RQ consumption now requires `return_cycle < current_cycle`.
The external memory request accepted at E0 is sampled by the scheduler at E3;
the RQ full bit is registered then, permitting consumption no earlier than E4.
The three memory credits track requests until return, whereas the four RQ
reservations last until consumption. No same-edge credit/slot bypass is assumed.
Six formats times four token counts, one pass without bias and default gaps,
each increased by two cycles in a local before/after run. This is a component
timing correction, not full RTL calibration. Published historical snapshots
retain their old source hashes and cycle counts until explicitly re-evaluated.

Memory issue diagnostics now split the legacy `rram_credit` aggregate into
`rram_inflight` and `rq_full`; their sum equals the aggregate. These are exclusive
selected blockers: inflight credit takes precedence when both conditions hold.
`CNT_RRAM_STALL` retains its prior aggregate behavior. Do not sum the aggregate
with these subtotals or add issue stalls to overlapping consume-side occupancy
stalls as if they were exclusive wall-cycle categories. The split does not alter
issue decisions or latency. Reproduce the 72-case sensitivity report with:

```text
python NPU_eval/af/throughput_diagnosis.py --output reports/af-estimate/NEW_DIRECTORY
```

This sweeps six formats, 1–4 tokens and default/slow-input/slow-credit conditions,
records source hashes and does not represent measured traffic or physical PPA.

2026-11-08: credit lifetime and final-row readiness were corrected. The event
export/comparator is diagnostic infrastructure, not calibration evidence.
The numbers below are historical model estimates, not current RTL measurements;
do not reuse them as performance evidence after the model changes. See
probes-20261108/README.md for remaining same-stimulus replay and event coverage gaps.

Single-file, self-contained (Python 3.6+, standard library only). Copy
`tile_cycles.py` into your LLM code and `from tile_cycles import
TileCycleModel, profile`. Deterministic; pure timing (no datapath values).

## 1. Quick start

```python
from tile_cycles import TileCycleModel, profile

m = TileCycleModel(fmt='fp4', n_tok=4, bias_en=True,
                   up_credit_period=1,  # up-link credit return cadence
                   x_gap=1, h_gap=1)    # hub-side X/H flit arrival spacing
rep = m.run_pass()          # one expert pass (GU -> H -> D -> DRAIN)
rep = m.run_step(6)         # top-6 experts back to back (overlap emerges)
rep.phases[0].sync1         # GU DONE cycle
rep.phases[1].sync1         # D DONE cycle
rep.finish_cycle            # total step length
rep.stalls                  # {'occupancy':…, 'rram_credit':…, …}
rep.counters                # RTL CNT_* names (CNT_GU/D/RRAM_RD/X_STALL/…)

profile(fmt='fp8', n_tok=4)        # one-call summary dict
```

## 2. Modeled mechanisms (rev4 RTL correspondence)

| Mechanism | RTL | Model |
|---|---|---|
| RRAM port LAT 3, 3-entry credit, 4-entry queue | pe4_rram, pe4_sched rq | issue when in-flight<3; consume at return, in order, 1/cycle |
| Bias tail words first (GU 0-1, D rereads 1-2) | iss_step bias stage | stream generator |
| PE occupancy: same column group re-accept >= 36 | tile_pe_v3 occupied bitmap | release[col]=accept+36 |
| PE 36-stage commit | out_valid E35 | commit = accept+35 |
| X/XS staging fill with writability rules | pe4_sched fill engine | same rules, x_gap arrivals |
| h-bank full fence before D matrix | bank_ready | h_ready = last arrival + QUANT |
| ACT 36 pairs, 1/cycle, LAT 24; H_UP ceil(36*n_tok/8) beats | pe4_act, launcher | act_start=last_commit+1 |
| Up launcher: 6 credits, H>Y, 1 beat/cycle | pe4_bus | per-cycle credit returns |
| yacc RMW n_tok*10 rows, ~17 cycles/row, overlaps next phase | pe4_yacc | yacc_free; drain yields on CRD cycles |
| 2 CMD slots, prefetch overlap; phase-boundary rq-empty guard | iss started/rq_cnt==0 | first word of a phase waits rq empty |

## 3. Reference numbers (n_tok=4, bias alternating, 1 GHz cycle = 1 ns)

| fmt | matrix rate (w/cycle) | GU sync1 | D sync1 | pass finish |
|---|---|---|---|---|
| fp4 | 0.251 | 5858 | 8758 | 9478 |
| fp8 | 0.501 | 5870 | 8783 | 9503 |
| fp8-f32 | 0.500 | 5872 | 8788 | 9508 |
| fp8-bf16 | 0.501 | 5871 | 8786 | 9506 |
| int4 | 0.251 | 5859 | 8760 | 9480 |
| bf16 | 0.750 | 7800 | 11969 | 12689 |

- Steady rate = `min(1, ngroups/36, 3/(3+1))`: occupancy caps fp4 at 9/36,
  fp8-family at 18/36; **the 3-entry RRAM credit budget caps every format
  at 0.75** (each word holds a credit issue->consume = LAT+1 = 4 cycles).
  bf16 hits that 0.75 ceiling — raising RRAM_CREDITS to 4 would uncap it.
- 6-pass fp4 step: 53163 cycles vs 6x9478 = 56868 serial (7% overlap gain;
  single PE serialises GU/D per pass by design, so the gain is bounded).

## 4. Approximations (documented deltas vs RTL)

1. `pe3_add` inside yacc/ACT is handshake-timed in RTL; the model uses its
   fixed depth (6). Error bound: +-1 cycle per add chain, amortised.
2. Launcher packet switch consumes no gap cycle (RTL can also chain
   back-to-back); +-1 cycle per packet.
3. DRAIN yield is modeled as +1 cycle per same-bank CRD collision; RTL
   re-arbitrates exactly, same bound.
4. X writability uses the next-to-issue kb (RTL uses the registered iss
   state) — same decision one cycle earlier, no throughput effect.
5. H broadcast start = GU sync1 + HUB_TURN (2 cycles); pass a custom
   `h_start` by setting `p.h_start` before `run` in advanced use.
6. Multi-pass: per-phase X flags (RTL clears x_popped only on slot-0 GU
   latch; the model gives each GU phase fresh flags — the intended
   semantics of the single-GU-at-a-time scheduler).

## 5. RTL cross-check (after VCS)

`tb_tile_v4` exposes the same CNT_* counters; compare with
`report.counters`. Any mismatch beyond the bounds above is a model or RTL
bug to file against this list.
