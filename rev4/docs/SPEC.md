# RTL-TILE-FFN-004 — Tile FFN Revision 4 Specification

Date: 2026-10-31. Rev4 implements the single-tile V4.1 FFN datapath on the
frozen rev3 PE (`tile_pe_v3`, 36 stages, conservative RF occupancy) with SRAM
operand supply, the complete GU→SwiGLU→H and H→D→y paths, and the frozen
data_bus v0.12 protocol subset. Revisions 1–3 are untouched; their hashes are
pinned in `baseline.json`.

## 1. Frozen sources and contract parents

| Source | Version | Binding |
|---|---|---|
| `architecture.md` / `data_bus.md` | v0.12 | flit/sideband/CMD layouts, credits, tile storage |
| `arith_cells.md` | v0.2 | dec/dot32/sclap/act/quant cell contracts, P5-x |
| rev3 `rtl/*.sv` | baseline.json SHA-256 | PE reused unmodified |
| rev1 `model/reference.py` | f1785c3e… | FP32/dot32/scale oracle (imported by `model/tile_reference.py`) |
| `rtl/pe4_sigmoid_rom.hex` | dab74aaf… (SHA-256) | offline-generated sigmoid table |

## 2. Fixed configuration (only this is accepted)

V4.1 activation preset: alpha=1, gate upper clamp +10, up clamp [-10,+10],
u_off=0, beta_g=beta_u=0 (softclip disabled), BIAS_EN = 0 or 1 (per class;
when 1 the expert record carries a bias tail, data_bus 4.6: gate 36, up 36,
down 80 BF16 values; the GU phase reads tail words 0..1 into its context
before its matrix stream and the D phase rereads words 1..2 likewise; the
boundary word is read twice by design), WPLACE=h,
VACC_FP32=0, EP_PARTIAL=0, PARTIAL_Y_FMT=0 (BF16 Y), VSPLIT=1 (no virtual
experts), H=5120, H_KB=160, H_COLS=36, I_V=2304. All six weight formats
(fp4/fp8/fp8-f32/fp8-bf16/int4/bf16) with matched SFMT/SBLK_128 are legal;
CTX records failing validation reject their CMD (`CMD_ILLEGAL`).
Activation is always FP8 E4M3 + UE8M0 per 32 k.

## 3. Storage and precise timing (rev4 contract)

| Storage | Request | Return valid | Earliest downstream sampling |
|---|---|---|---|
| Operand staging SRAM (`pe4_sram`, LAT=2) | E0 | during E2 | E2 edge |
| RRAM SRAM model (`pe4_rram`, LAT=3) | E0 | during E3 | E3 edge |

Both accept one read per cycle, fixed latency, never stall. Return buffer
space is reserved before requesting (staging: scheduler hold banks; RRAM:
3-entry credit budget counting in-flight + unconsumed returns).
SRAM data is not reset; only valid/ownership/queue state resets. A load
during compute sets `UNSUPPORTED` via `load_err`. Same-address
read-during-write is prevented by controllers. All arrays are behavioural;
no SRAM macro is bound (`PE4_SRAM_MACRO` placeholder) — no area claim.

### Staging (1,024 B budget, now SRAM)
- X: 2 banks x 4 token macros x 64 B; X flit idx covers k-blocks 2*idx,
  2*idx+1 with bank idx%2. XS: same shape; XS flit idx covers k-blocks
  64*idx.. with bank idx%2. One read returns all four tokens' operands.
- Arrival order per pass (X_ORDER contract): for grp 0..2: XS(lane,grp) for
  lanes 0..n_tok-1, then X(lane, 32*grp+i) for i < 32/16, lanes inner.
- Overwrite safety: X idx writable iff idx <= 1 or iss.kb >= 2*idx-2; XS grp
  writable iff grp <= 1 or iss.kb >= 64*(grp-1). The <= 3-entry RRAM queue
  plus ngroups >= 9 keeps an overwritten block >= 9 words downstream of the
  consumer, so holds are never corrupted.

### RRAM and weight stream (rev4 layout decision)
- Word = 1024 b; address = CMD expert_base_word + (phase==D ? gu_words : 0)
  + stream offset; capacity parameterised (tests allocate only used words).
- Stream per phase, k-block-major: for kb: [scale group when kb%period==0:
  `sw` words] then one weight word per column group. `sw` words hold `cols`
  scale entries column-fastest (GU cols=72, D cols=80); period=4 with
  per-column 32-b hold-register retention for fp8-f32/fp8-bf16 (128-k scales
  reused across their four k-blocks), period=1 otherwise, no scale words for
  bf16. Registered as the rev4 image layout; the frozen spec's 16/32/64-word
  scale periods belong to its own image compiler.
- Weight-scale holds: 2 x 80 x 32 b (one set per CMD slot; a fresh phase's
  first word waits for an empty return queue so holds are never corrupted).

## 4. Tile registers (CTRL op1/op2 at the frozen offsets)

0x000 TILE_ID (RO), 0x004 TILE_STATUS, 0x008 ERR_STATUS (W1C; bits 0-18
frozen, rev4 additions 19 UNSUPPORTED / 20 ORDER / 21 SNAPSHOT), 0x00C
ALARM_MASK, 0x010 ERR_FIRST, 0x020-0x050 the 13 frozen counters,
0x100-0x140 / 0x180-0x1C0 CTX0/CTX1 (16 class words + mode; writes refused
while any slot is active -> CTX_BUSY), REMAP 0x200+ writes rejected
(REG_ADDR). Error additions are new bits only; no frozen field is
reinterpreted.

## 5. Protocol subset and explicit exclusions

Implemented: CMD (GU/D; SCAN -> UNSUPPORTED), X/XS (shared 128-entry FIFO
with the hub credit model: 128 seeded, one per sync[0] pop, overflow =
X_FIFO_OVF), H, CTRL (DRAIN op0 with segment/range; register write/read 1/2;
counter clear 3; ops 4-8 -> RPGM; 9-15 -> PROTO_CTRL), up H_UP/Y_UP/STATUS
beats with the frozen LSB-first sidebands (UP_SB/UP_SB_Y: type@1:0,
src@8:2, tag@16:9, last@17, nphit@19:18, segment@21:20) and tile->L1
credits (reset 6, 0-2 returned per cycle, cap 6; over-return ->
UP_CREDIT), SYNC[0] x-pop pulse, SYNC[1] phase-done pulse, sticky err line
(driven while ERR_STATUS & ~ALARM_MASK is non-zero, P3-6).
- STATUS register replies (op 2): single phit, tag = request tag (the CTRL
  sideband pass_id), payload STATUS_REG {data@0, addr@32, err@44}; err=1
  with data=0 for unaligned/unmapped offsets; 2-deep reply FIFO (deeper
  bursts drop; reads are rare firmware polls).
- ALARM = STATUS subtype tag 0xF3, payload {err_status@0, first_bit@32,
  first_pass_id@40}: exactly one packet when ERR_STATUS & ~ALARM_MASK
  leaves zero, rearmed only after W1C clears the unmasked bits (P3-6).
- PE error aggregation (#8, wire-level): rev3 PE errors[0] (weight 127 /
  scale 255 / reserved activation code) -> ERR_STATUS.NUMERIC; errors[1]
  (malformed PE transaction, defensive) -> CMD_ILLEGAL; edge-detected on
  the PE sticky outputs.
Launcher priority H_UP (dedicated slot) > Y_UP > STATUS, with ALARM
outranking register replies inside the STATUS class; a started packet
holds the link through its last beat; credits only delay, never reorder.
Not implemented (explicit error, never silent degradation): PGM flits (->
RPGM + UNSUPPORTED), SCAN CMD and its SCAN_CRC reply, rpgm ops and
PGM_CREDIT/PGM_EVENT statuses, REMAP, EP partials, VSPLIT > 1.
The x FIFO entry is 533 b (payload + pass/lane/idx/kind) instead of 516 b so
X_ORDER can actually verify arrival metadata; registered as a +272 B/tile
rev4 deviation (docs/WIDTHS.md).

## 6. Numeric contract (bit-exact against model/tile_reference.py)

- PE path unchanged from rev3 (exact dot32 + single RNE; UE8M0 exponent
  scaling; BF16/FP32 weight scale two roundings; FP32 RF accumulate).
- pe4_fmul: one RNE rounding of the exact product, subnormals in/out,
  canonical NaN, inf*0 -> NaN; verified bit-equal to the frozen Fraction
  oracle over 4 000+ random and corner pairs by the unit test.
- ACT (V4.1, with GU bias): g0 = fp32(g + gb), u0 = fp32(u + ub) (the
  adds always execute; gb/ub = +0.0 when bias is disabled, and the add
  itself normalises -0); g1/u1 BF16 boundary casts; clamps; sigmoid from
  the BF16-indexed FP32 ROM (stable reference form, one rounding: the ROM
  *is* the reference); v = fp32(fp32(g2*s)*u2); h = bf16(fp32(w*v)).
  4 lanes, 1 column-pair/cycle, latency 24.
- Quantizer: amax floor 1e-4; e = E-8 if f <= 0.75 (inclusive, boundary
  mantissa 0x600000) else E-7; se in [105,247]; E4M3 RNE tie->even code,
  +-448 clamp, -0 -> 0x80; non-finite block: se=247, +-inf -> +-448,
  NaN -> 0, NUMERIC raised.
- y commit (WPLACE=h, VACC=0, arith_cells 7b; adds always execute):
  wb = fp32(w * b) with b = the phase D-bias value (bf16) or +0.0 when
  bias is disabled or CMD first = 0; v = fp32(d + wb); t = bf16(v);
  y = V ? fp32(y_old + t) : fp32(+0.0 + t). First write normalises -0.

## 7. Overlap model and cycle accounting

One phase owns the PE at a time; the next phase latches into slot 1 and its
RRAM prefetch starts when slot 0 finished issuing (its first word also waits
for an empty return queue). H quantisation, D commit RMW (10 rows x n_tok,
one row at a time, ~6+ cycles/row) and DRAIN all overlap PE compute; a
DRAIN read on a bank yields one cycle to a same-bank commit read
(CNT_Y_YIELD); the next D phase's DONE waits for an empty commit buffer.
The conservative PE occupancy (same-column re-accept >= E36) sets the
steady-state word rate to ~ ngroups/37 per cycle (fp4 GU ~ 9/37); the CNT_*
cycle counters replace every earlier fixed-latency assumption.

## 8. Validation entry points

- Local (no simulator): `python -B scripts/run.py local --suite full`.
- VCS: `bash scripts/run_vcs.sh --suite full --seed 817` (math + tile).
- DC: `env TARGET_DB=... bash syn/run_dc.sh --top tile_ffn_v4` (also
  pe4_fmul_probe / pe4_act_probe / pe4_quant_probe / pe4_yacc_probe /
  tile_ffn_probe). 1 ns clock, 0.05 ns uncertainties, 0.20 ns I/O, no false
  paths; SRAM macros unmapped, so DC reports are logic-only.

