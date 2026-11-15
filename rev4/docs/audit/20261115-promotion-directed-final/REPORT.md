# Directed promotion boundary test — 2026-11-15

The earlier full rev4 Python regression completed: 116 tests passed in
357.936 seconds. Its original log remains in ../20261115-tail-base-promotion/.
After adding the new runner gate, the focused runner regression passed all
12 tests; its log remains in ../20261115-promotion-directed-v2/runner-tests.log.

## Prepared dynamic checks

`tb_promotion_v4.sv` is an explicitly WHITE-BOX scheduler transition test.
It seeds state with force/release on whole variables, releases scheduler state
before the tested edge, and lets the real always_ff perform the transition.
It does not establish external input reachability, numerical correctness or
end-to-end timing. Control-port overrides isolate the boundary and block RRAM
issue until after promotion; they intentionally exclude simultaneous issue.

Six cases cover the Cartesian product:
- GU last-H_UP and DCOMMIT retirement;
- bias index 0, 1 and 2;
- all six use unequal old/new bias bases 0x100 and 0x800.

Each case first blocks retirement for one cycle and checks no movement/SYNC1,
then allows retirement and checks the entire successor descriptor, phase_base,
tail_base, old slot clearing, SYNC1, and the first combinational RRAM request
address (0x800 + bias index). Reset precedes memory sampling; this bench does
not check RRAM returned data. A 10 us watchdog bounds failures.

The test was semantically compiled, NOT simulated in this session. Therefore
six is the REQUIRED case count, not measured dynamic coverage. The earlier
component-select force version failed local compilation and is retained as
an unsuccessful audit; final code uses legal whole-variable force/release.

## Invocation after syncing current files to the VCS checkout

    bash scripts/run_vcs.sh --test promotion --suite smoke --seed 817

Expected successful evidence:

    CHECK promotion paths=2 distinct_tail=6 stalled=6 bias_addresses=6
    PASS promotion cases=6

The runner requires exactly one complete CHECK before exactly one full PASS,
rejects incomplete/duplicate/late coverage, and labels manifest coverage as
`white-box seeded scheduler transition`. Existing generic FAIL/error/exit-code
checks still apply. --test all now includes promotion; --waves is supported.

Nine distinct tops pass final local pyslang 12.1.0 compilation. checks.json
binds RTL, testbenches and compiler tool script. verification-sources.json
also binds the runner and its new coverage gate tests.

## Open work

VCS execution and a negative run with both tail_base migration assignments
removed are still needed to demonstrate this checker detects the original
fault dynamically. The same-edge new CMD loss, simultaneous successor issue,
queue tag/scale ownership, and shared bank take/release port remain open.
Historical full Tile passes must not be assigned to the modified scheduler.
