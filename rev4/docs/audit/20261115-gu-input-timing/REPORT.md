# GU external-input timing validation — 2026-11-15

Both supplied ordinary and overlap full Tile traces pass all 24 GU cases:
six formats by one through four tokens. The independently composed finite
FIFO/staging, issue, memory/RQ, operand-hold, PE and capture model predicts
memory_issue, memory_consume and pe_accept cycles exactly, with no fitted or
trace-derived timing shift. Every compared cycle difference is zero.

The simulation origin is the external CMD edge plus one, derived from the
registered slot admission rule. Format/bias/base come from external CMD/CTX
input decoding. X/XS arrival cycles come only from external down inputs;
kind/lane/index/pass sequence must match the supported native ordering before
replay. Payload numerics are not part of this timing model.

Compared fields: every event count, sampling stage and cycle; issue address,
kb and group; consumption kb and group; PE base/mask and full tag including
pass. No observed memory request/return/consume or PE acceptance event is
used to drive the model. Those events are comparison targets only.

Scope and remaining assumptions:
- GU phases are replayed in isolation with initially empty memory/core/FIFO.
- CMD is assumed admitted and CTX writes assumed idle; full slot lifecycle
  and same-edge admission/retirement are not yet independently predicted.
- Captured inputs reflect the testbench's credit-aware producer; this does
  not independently predict a remote hub's delivery schedule.
- D phases, GU H_UP/credit epilogue, numerical payloads, full command stream
  execution and physical timing/PPA remain outside this comparison.

Thus this is exact observed-workload GU core timing agreement, not complete
Tile or AF throughput calibration. The current same-edge CMD/retire hazard
remains unresolved and is covered by the separately prepared HDL probe.

Reproduce from project root:

    python -B Tile_eval/rev4/docs/audit/20261115-gu-input-timing/check.py

checks.json stores per-case results and trace hashes; sources.json records
model/checker dependencies. No historical manifest was updated.
