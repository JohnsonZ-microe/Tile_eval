# Rev4 storage map and cycle model

## 1. Storage inventory (behavioural arrays; macro binding pending)

| Block | Size | Organisation | Notes |
|---|---:|---|---|
| x FIFO | 8,576 B | 128 x 533 b | +272 B vs frozen 516 b entry (SPEC 5) |
| X staging | 4,096 B | 8 macros 512 b x 2 | 2 banks x 4 tokens x 64 B |
| XS staging | 4,096 B | 8 macros 512 b x 2 | as above |
| h data | 18,432 B | 2 banks x 72 rows x 1024 b | 4 lanes x 32 FP8 per row |
| h scales | 576 B | flops 2 x 72 x 4 x 8 b | written with the row |
| y banks | 40,960 B | 2 banks x 640 rows x 256 b | 8 FP32/row = 64 slots x 10 rows |
| D commit buffer | 1,280 B | flops 80 x 4 FP32 | P3-11 |
| GU snapshot | 1,152 B | flops 72 x 4 FP32 | captured from PE out_results |
| H_UP slot | 288 B | flops 144 x 16 b | dedicated up slot |
| RF (in PE) | 1,280 B | 80 x 4 FP32 | frozen rev3 |
| wscale holds | 640 B | 2 x 80 x 32 b | per CMD slot |
| sigmoid ROMs | 1,024 KiB | 4 x 64Ki x 32 b | SHA dab74aaf…; must be reported separately |

SRAM macros are NOT mapped: pe4_sram/pe4_rram instantiate behavioural
arrays behind a `PE4_SRAM_MACRO` substitution point. No synthesis number may
be read as silicon SRAM area or timing.

## 2. Pipeline latencies (rev4 additions; PE unchanged at 36)

| Unit | Latency (cycles) |
|---|---:|
| pe4_sram (staging) | 2 (request E0 -> data during E2) |
| pe4_rram | 3 (request E0 -> data during E3), 3-entry credit |
| pe4_fmul | 4 |
| pe4_quant | 3 (rev4.1: amax = balanced 5-level 15-bit max2 tree, 1e-4 floor applied once after the tree; the former serial 32-stage chain was the -2.39 ns critical path at 1 ns) |
| pe4_act | 24 (1 in-reg + 6 bias add + 17 core); 1 pair/cycle |
| yacc row RMW | ~17/row (mul 4 + add 6 + add 6 + seq), one row at a time |
| PE (frozen) | 36; same-column re-accept >= E36 |

## 3. Cycle model (replaces all earlier fixed assumptions)

- Word issue rate <= 1/cycle, further limited by: RRAM credit (3), operand
  readiness at each k-block start (CNT_X_STALL), PE in_ready (CNT tracked
  implicitly through run time), and the PE occupancy rule: a column group
  re-accepts no earlier than E36 after its previous word. With ngroups >= 9
  interleaved groups the steady rate approaches ngroups/37 words/cycle
  (fp4 GU ~0.24 w/c, bf16 GU with 36 groups ~0.97 w/c).
- GU phase (fp4): 160 scale words + 1,440 weight words = 1,600 RRAM words;
  D phase (fp4): 72 + 720 = 792 words (rev4 per-k-block scale groups).
- D admission waits for a full h bank; the next phase's prefetch overlaps
  the current phase's drain; commit RMW and DRAIN overlap everything.
- All measured quantities are in the 13 counters (frozen names/offsets).

## 4. Ownership and fences

- h banks: owned by the GU CMD (take at CMD accept); D waits for
  owner==pass and all 72 rows x n_tok lanes written; released at D DONE.
- y banks: V[2][64] bits; set at commit, cleared after the last DRAIN
  segment; V=0 DRAIN outputs zeros and raises V0_DRAIN.
- GU snapshot and H_UP slot: single-occupancy; the next GU's ACT waits for
  the H_UP packet to leave.
- Commit buffer: next D DONE waits for commit_busy == 0.
- Return queue: a fresh phase's first word waits for rq empty (protects the
  weight-scale holds of the previous phase's in-flight words).
