# Control identity register correction

The failed control run compared 0x00000110 against 0x00000010. The bench
incorrectly expected an ID-only register. The RTL also hardcoded ID 16,
advertised the obsolete latency 1 and omitted INIT_DONE.

The register at 0x000 now returns ID in bits 5:0, memory latency in bits
11:8, and INIT_DONE in bit 31; other bits are zero. ID follows the top-level
source parameter. Latency is 3 measured from request sampling to downstream
return sampling (E0 request, E2 registered return, E3 consumption). It does
not mean three cycles to the registered output. INIT_DONE clears on a
synchronous reset and sets on the first non-reset edge; there is no memory
clear requirement. Default readback after initialization is 0x80000310.

The bench constructs its expectation independently and retains full payload
and sideband comparisons. TEST_ID permits additional elaboration-time identity
cases. The existing automatic flush task has automatic variable lifetime;
its declaration initializer is not the static-loop bug found in the Y bench.

Local source checks are not HDL validation. Run the control test again and
then the complete regression. No historical evidence is changed. Other
control-path defects may still be exposed after this first mismatch is fixed.
