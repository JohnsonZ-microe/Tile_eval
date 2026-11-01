# RTL-TILE-PE-001 revision 3

- ID: RTL-TILE-PE-001
- revision: 3
- scope: standalone six-format PE array, R=4
- status: implemented, HDL compilation / VCS / DC pending
- source: approved revision 2 numerical contract, supplied revision 2 DC reports and requested third-revision optimization
- verification: local Python tests and static checks only until server logs are available

## Frozen arithmetic

The original Tile_eval/model/reference.py is unchanged and SHA-256 checked against docs/baseline.json.
FP4, FP8, FP8-F32, FP8-BF16, INT4 and BF16 weight formats retain decoding, finite subnormals, canonical NaN, signed-zero and error substitution semantics.
FP8 E4M3 activation is unchanged. Dot32 sums exact products before the sole partial FP32 rounding.
UE8M0 scaling adjusts exponent. BF16/FP32 weight scaling retains first exponent-round and then multiply-round.
RF accumulation order remains acceptance order. Original widths and full products are not truncated.

## Interfaces

Top: tile_pe_v3. Ports match tile_pe_v2, including in_ready.
Acceptance is rst_n && in_valid && in_ready at the rising edge.
A stalled producer must hold in_valid and payload. Outputs have no backpressure.
Illegal format, out-of-range destination or zero mask produces an ordered error response without reserving or changing RF.
Valid descriptors reserve all effective column/lane destinations until commit, including first-block overwrite.
No same-edge release bypass. Synchronous active-low reset clears RF, occupancy, pending valids and public error/output state.
Invalid arithmetic payload registers need not be reset, and must never be observed as valid.
busy and idle RF readback retain revision 2 semantics.

## Latency, shared in rtl/pe3_pkg.sv

| Stage group | Register count | Core edges |
|---|---:|---|
| Input / decode | 2 | E0..E1 |
| Exact dot32 | 13 | E2..E14 |
| Exponent scale | 5 | E15..E19 |
| Weight-scale multiply | 8 | E20..E27 |
| RF operand read | 1 | E28 |
| FP32 accumulation | 7 | E29..E35 |
| Total | 36 | E0 acceptance, E35 commit |

ADD_STAGES=8 includes RF_READ_STAGES=1 and FPADD_STAGES=7.
SCALE_STAGES=13 includes SHIFT_STAGES=5 and MUL_STAGES=8.
DOT_EXACT_DELAY=6 means a dot accepted at its own D0 produces exact_sum after D6 and partial_value after D12.
The top samples the rounder's combinational commit_value on the same edge that the standalone adder registers result, preventing an extra register cycle.
Metadata is zeroed for scale fields and fmt after DOT_INDEX=14, and first_block after RF_INDEX=28.

| Dot local edge | Function |
|---|---|
| D0 | 8x4 significand products, shift and sign |
| D1 | Alignment, conditional complement, negative-count correction |
| D2 | 33 to 22 to 15 carry-save operands |
| D3 | 15 to 10 to 7 operands |
| D4 | 7 to 5 to 4 to 3 to 2 operands |
| D5 | Segmented CPA candidates |
| D6 | Prefix carry select, exact signed sum |
| D7 | Absolute-value segmented candidates |
| D8 | Absolute-value select |
| D9 | Leading-one detection |
| D10 | Normalization exponent and shift control |
| D11 | Barrel shift and sticky |
| D12 | FP32 RNE |

Multiplier local edges: M0 four 12x12 partials, M1 CSA reduction, M2 24-bit segment candidates, M3 select full 48-bit product, M4..M7 round pipeline.
FP32 add local edges: A0 ordering/exponents, A1 alignment, A2 add/subtract, A3..A6 round pipeline.

## Throughput

Independent arithmetic transactions support II=1 by construction; RTL simulation must confirm this.
The same RF destination is blocked through E35 and can next accept at E36.
Ten full-token FP4 column groups cannot sustain II=1 across a 36-cycle reservation window.
The test uses 40 disjoint column-group/lane destinations to check a consecutive accepted run.
Do not equate nominal II=1 with sustained dependent FFN throughput.

## Scope exclusions and remaining timing risks

No operand staging/X_streamer, RRAM scheduling, cross-tile communication, K/token sharing or layout.
The D4 four-level CSA segment, D1 alignment, RF read mux, ready/enable fanout and normalization barrel still need DC review.
Segmented carry candidates duplicate local adders and increase register count. Retaining wide exactness does not guarantee area reduction.
High-fanout reset/control physical repair remains a backend requirement; FIX_HOLD only requests logical hold fixing.
