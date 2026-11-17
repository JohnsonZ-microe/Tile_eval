# RTL output contention probe

Extended tb_protocol_v4 with 20 bounded source-level contention cases: token counts 1..4 (H packet lengths 5/9/14/18) crossed with credit return delays 1/6/7/16/64 edges. Y starts first with ten beats and seven-edge spacing from each accepted row; H and STATUS become ready three edges later. Sources hold their identities while stalled. Payloads use distinct patterns per source and row.

The existing tick scoreboard checks all accepted payloads/sidebands and arbitration readiness. Each probe returns credits only for accepted beats, checks credit+outstanding=6, prohibits credit errors, requires exact H/Y/STATUS counts and an unlocked final bus, and has a 900-edge limit. The due queue has 1024 entries; the latest possible scheduled return is 899+64, within bounds. The one-token, one-edge return case requires H retirement at edge 68 and STATUS at edge 69, corresponding to the prior Python scenario shifted by -237 edges.

The probe exercises pe4_bus with an externally paced Y producer. It does not exercise actual Y SRAM/COMMIT contention or validate a future prefetch implementation. Testbench reset between cases is intentional; there is no reset between producers within a case. Original FIFO, arbitration and 42 credit-boundary cases remain.

## Acceptance gate

The runner requires exactly one marker before exactly one PASS protocol:

CHECK output_contention cases=20 tokens=4 delays=5 packet_lock=1 credit_conservation=1

Zero exit and no FAIL/FATAL remain necessary. Missing, duplicate, reordered and incomplete markers are rejected; successful manifests record the five coverage fields. Existing historical logs retain their original results and are not retroactively modified.

## Validation and next execution

pyslang semantic compilation passed (checks.json and protocol.log). Fifteen runner diagnostic tests passed, including ten invalid contention evidence cases (runner-tests.log). Dynamic VCS behavior is NOT validated locally. No remote run was started.

After syncing tb/tb_protocol_v4.sv and scripts/run.py, the next protocol regression can use:

bash scripts/run_vcs.sh --test protocol --suite full --seed 817 --waves

The bounded test is appropriate for waveform replay through the existing bus checker. Require the new CHECK marker, clean PASS, exit 0 and matching source manifest. This is a new protocol acceptance case; the completed ordinary/overlap tile runs need not be repeated for it.
