# Exact arithmetic and width preservation

## 285-bit BF16 dot and 42-bit low path

The minimum finite BF16 times E4M3 product is 2^-133 * 2^-9 = 2^-142.
All BF16 products are integer multiples of this quantum. Each finite magnitude is less than 2^128 * 2^9 = 2^137, and the absolute sum of 32 products is below 2^142.
The integer sum is therefore below 2^284 in magnitude and fits signed 285-bit two's complement.
Low precision retains the revision 2 signed 42-bit range at quantum 2^-18.
No intermediate FP32 rounding or truncation of small exponent contributions is introduced.

## Conditional complement and correction operand

For W-bit aligned magnitude A, -A modulo 2^W equals (~A)+1 modulo 2^W.
Replace each negative leaf with ~A, each positive leaf with A, and supply one additional operand equal to the number of negative leaves.
The count ranges from 0 to 32 and uses 6 bits. A balanced 32-leaf population-count tree computes it from the registered signs.
CSA takes 33 operands, including the correction, and reduces through 22,15,10,7,5,4,3,2 operands.
All nodes retain W bits. Discarding carry beyond W is modulo arithmetic, justified by the final signed-range bound.
Even a negative zero leaf contributes all ones plus one and therefore zero modulo 2^W.
Special BF16 products contribute zero numerical magnitude and independent special flags.

This removes 32 independent W-bit unary-minus carry chains per dot. It adds a correction operand and does not remove wide leaf registers. Total area is not predicted.

## Two-stage segmented CPA

Split unsigned W-bit inputs into 32-bit blocks and zero-pad only the uppermost partial block.
Stage 1 computes each block's complete sum assuming carry-in zero and one. Both candidates retain their low 32 bits.
For a zero-carry sum, G is its carry-out and P is the AND of all low sum bits.
Carry into block j is OR over prior G_i AND every P between i and j. Each term uses a reduction AND, followed by a reduction OR, avoiding a procedural ripple across blocks.
Stage 2 selects each block candidate with this carry and returns only the original W low bits.
This computes (left+right) modulo 2^W exactly; zero-padding does not change those bits.
The same unit computes absolute value as (~signed_sum)+1 for negative values and signed_sum+0 otherwise.
The unreachable most-negative signed endpoint is excluded by the dot range proof.

## 24x24 product

A=A_hi*2^12+A_lo and B=B_hi*2^12+B_lo.
P=A_lo*B_lo + (A_lo*B_hi+A_hi*B_lo)*2^12 + A_hi*B_hi*2^24.
Each subproduct is full 24-bit. All shifted operands and CSA nodes are 48-bit.
The maximum product (2^24-1)^2 is below 2^48, so the final modulo-48 sum is the complete unsigned product.
The 48-bit CPA uses 24-bit blocks. No subproduct receives floating-point rounding.

## Four-stage FP32 conversion

Leading-one detection, exponent/shift control, barrel/sticky and final RNE have separate register boundaries.
The barrel preserves 24 significant plus 3 GRS bits and ORs every discarded bit into sticky.
The minimum normal exponent floor -126 directs subnormal shifts; round-to-even can promote a subnormal to normal.
Negative zero, overflow, infinities and canonical NaN preserve revision 1 semantics.
For scale, the first conversion must finish before the second multiply/round conversion.
