# Validation boundary

No local HDL compiler, VCS or DC was found. No software was installed and no remote job was started.
Python tests validate algorithms and stimulus scheduling, not the synthesized or simulated HDL.
SystemVerilog compile/elaboration, VCS bitwise regressions and DC timing/area are pending.

## Local test layers

- Eight unchanged original reference numerical groups.
- Four inherited compact FP32/normalization/CSA/scheduler groups.
- Four added groups: segmented carry with boundary carries, 12x12 partial reconstruction, signed correction and absolute value, latency/source and reset accounting.
- Two report-parser groups reject rounded-zero slack with nonzero violation counts and treat missing counts as unknown.
- The normalized numerical oracle is unchanged. Only protocol timing and new structural cases extend the vector generator.

## Server VCS acceptance

Run cpa/math/dot/array smoke, then full seed 817 and 2026.
CPA bench checks exact 42/48/285-bit addition, two-stage validity, bubbles and reset flush.
Math checks decode, add, multiply, exponent scaling and two-round scale using shared stage constants.
Dot checks exact finite sum at D6 and FP32 output at D12, including large cancellation and 0..32 negative terms.
Array checks E35 commit, readiness, masked RF writes, ordered tags, reset flushing at every in-flight position, error isolation and final 320 RF words.
Keep long K=5120/2304 tests and the 40 disjoint consecutive acceptance case.
Malformed vectors, bit mismatches, latency errors, missing PASS and watchdog/command timeout are failures.

## DC acceptance

Use the same library, 1 ns clock and I/O budgets as revision 2. Setup/hold uncertainty remain 0.05 ns.
Report exact source/library hashes and FIX_HOLD/DC_CORES settings.
Require no setup/hold violations, no unexpected latch/unmapped/unconstrained logic, and reviewed design warnings.
The five-decimal report precision prevents rounded 0.00 from hiding small violations.
Mapping completion does not mean timing closure. Carry-select and additional registers can increase area.
No power or physical timing claim is supported by this local delivery.

## Recorded local run

Full seed 817 model/vector generation completed with 58,687 scheduled cycles, 1,786 accepts, 1,743 commits, 56,070 stall cycles and a longest consecutive acceptance run of 40.
The 43 canceled requests are accounted for by reset, not numerical result loss.
The dataset contains 89,825 arithmetic vectors, 2,000 dot vectors, 2,000 CPA cycle vectors and 320 final RF words.
These are reference-model statistics, not RTL simulation measurements.
See each results/local-*/manifest.json for the exact source snapshot and executed tests.
