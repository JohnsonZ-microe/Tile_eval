# Independent Y arithmetic and reset audit — 2026-11-17

Added integer dyadic FP32 addition and multiplication, with exact significand operations and a single round-to-nearest-even result. Implementation imports neither the Tile reference nor Fraction and uses no host float. Tests compare 20,100 operand pairs (special-value cross product plus 20,000 deterministic random pairs) against the existing Fraction oracle for both operations. Agreement is differential evidence, not proof of all FP32 inputs.

Added commit_word for the actual RTL operation: D + weight*bias, BF16 rounding, then FP32 addition to old Y or +0 according to the commit snapshot. D is already weighted upstream. Even with bias disabled the hardware multiplies weight by +0, so infinite weights still produce NaN. Directed tests cover these semantics. This value function has not yet replaced the write callback in YMemoryReplay; complete numeric pipeline composition remains outstanding.

The historical yacc VCD replay checks all 24 arithmetic cells at observed cell-input boundaries: eight FP32 multipliers (4 stages), eight bias adders and eight Y adders (7 stages). It compares output-valid on every edge and result on each known valid output. All 72,000 known operations match. The replay is conditional on observed operands and valid inputs, not independently generated COMMIT scheduling.

The old waveform exposes an uninitialized addb_v pulse after reset: one unknown input and one propagated unknown output per bias adder, eight each. The checker preserves these unknown valid bits rather than counting them as successful numeric outputs or coercing them to zero. This led to a one-line RTL fix resetting addb_v alongside mul_v/add_v. A falling-edge testbench assertion now verifies that all three launch masks are zero after synchronous reset.

The modified yacc RTL and testbench pass SystemVerilog parsing/semantic elaboration (reset-compile). Dynamic VCS validation of this new reset assignment is pending; the old VCD predates it and must not be used to claim the fix dynamically passed. Use the existing yacc full-suite seed 817 waves command when collecting the next Y run; no remote job was started here.

Checker tests reject output data/valid corruption, missing operands and an unfinished pipeline. They also verify explicit unknown-valid propagation. Full AF regression is recorded in af-regression.log; sources.json binds the analyzed files. waveform.json contains per-cell counts and the historical VCD hash.

Full AF regression: 264 tests passed in 45.566 seconds.
