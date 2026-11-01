# Rev4 validation status (updated 2026-10-31 after audit remediation)

| Item | Status | Evidence |
|---|---|---|
| Python golden unit tests | PASS (24 tests incl. 6 audit probes) | `python -B -m unittest discover -s model` |
| pe4_fmul vs frozen Fraction oracle | PASS, 4 000+ pairs + corners | `TestFmul` |
| E4M3 encoder vs brute-force nearest | PASS | `TestE4M3` |
| Quantizer vs direct e/q formula | PASS | `TestE4M3` |
| Sigmoid ROM (stable form, no cutoffs, subnormals kept) | PASS; SHA b041becb… | `TestSigmoid`, `TestAuditProbes` |
| Vector generation (12 scenarios + ALARM + true H loop) | PASS | `vectors.log` |
| STATUS replies / ALARM / PE error aggregation | implemented | SPEC.md 5; VCS pending |
| Bias support (BIAS_EN=0/1, tail reads, ACT gb/ub, D down bias) | implemented; 6/12 tile scenarios with bias | SPEC.md 2/6; VCS pending |
| Cycle-accurate performance model | implemented; 13 tests + deadlock raises | model/tile_cycles.py; CYCLE_MODEL.md |
| Audit remediation 2026-10-31 | R4-001..012/014..021/023..025/030/033 fixed locally | see below; VCS/DC still pending |
| Local runner end-to-end | see results/local-* | manifest.json status |
| RTL compile (VCS) | NOT RUN (no local simulator) | pending server VCS |
| RTL simulation (math/tile benches) | NOT RUN | pending server VCS |
| DC synthesis / timing | NOT RUN | pending server DC; SRAM macros unmapped |
| SRAM macro mapping | NOT AVAILABLE | behavioural arrays only |

Audit items fixed on 2026-10-31 (local Python evidence only; VCS pending):
R4-001 (golden matrix accumulation restored + all-ones probe),
R4-002 (K_GU/K_D params + fp32_clamp restored in pe4_pkg),
R4-003 (ACT vpipe packed; tb_tile always out of initial),
R4-004 (ncols 4-bit in classp_t/rq_t),
R4-005 (x FIFO entry 534-bit unified + slice fix),
R4-006 (fcount/rq_cnt/cap_cnt single next-state; rq pointers 2-bit),
R4-007 (fmul data pipeline aligned with valid: S2 snapshot + flags),
R4-008 (e4m3 sign extension + sticky mask below guard),
R4-009 (sigmoid no cutoffs, subnormals kept, ROM re-frozen),
R4-010 (fp32_to_bf16 NaN preserved),
R4-011 (capture descriptor pushed on EVERY weight accept),
R4-012 (exp_* reset + per-pass init; XS compare uses group),
R4-014 (quant tag 11-bit {bank,lane,idx} aligned),
R4-015 (hbuf illegal writes gated from SRAM),
R4-016 (ACT collection in P_ACT and P_ACTW; input/output counters),
R4-017 (y row address = slot*10+row, commit and drain unified),
R4-018 (load_cen 8-bit; bias_lat/db_lat latched at trigger only),
R4-019 (dre one-cycle pulse; src captured on first beat),
R4-020 (src 7-bit; tag sampled on grant cycle),
R4-021 (CTX0 word index (addr-0x100)>>2; GU/D counters at retire),
R4-023 (rram.hex addr+word pairs; drain bank bit 6; slots 0..63),
R4-024 (math bench line-based $fgets+$sscanf),
R4-025 (H broadcast uses golden GU h for local 36 columns),
R4-027 (cycle model raises on deadlock),
R4-030 (vbit single-writer with req/clear handshake; addg_v 4-bit),
R4-033 (16-bit scales in LOW half of 32-bit slot).

Remaining open items (tracked for next iteration):
R4-013 (per-lane operand readiness), R4-022 (overlap ownership invariants),
R4-026 (cycle model credit release calibration), R4-028/029 (doc/script
cosmetics), R4-031/032 (VCS/DC execution).

