# Bias tail base promotion repair — 2026-11-15

## Changed invariant

When an existing successor moves from slot 1 to slot 0, its matrix base and
bias tail base must move with its descriptor and issuer. Both P_HUP completion
and P_DCOMMIT retirement previously copied phase_base but omitted tail_base.
Both paths now copy tail_base[1] to tail_base[0]. Reset also initializes both
tail bases, consistently with phase_base. No additional pipeline stage or
storage entry was added; physical timing/area/power effects are unmeasured.

Source-derived counterexample: old head tail_base=0x100, successor
 tail_base=0x800, successor bias issuer bidx=1. After promotion the old RTL's
RRAM address mux selects 0x101; the successor's required address is 0x801.
This condition matters only when a bias read remains after promotion. Existing
same-pass GU/D vectors can share a tail base or prefetch bias before retirement,
so their successful runs do not establish coverage of this defect.

## Verification added

The full Tile bench checks both retirement paths when an existing slot 1 is
valid. It samples expected phase_base and tail_base before the edge, checks
slot 0 after NBA settlement, and fails on loss. The final log prints:

    CHECK promotion addresses=<N> distinct_tail=<M>

M records whether the old head and successor had different tail bases. M=0
must not be reported as directed coverage of the counterexample. This counter
is diagnostic only; the existing runner does not require it for PASS.

All eight distinct regression tops pass local semantic compilation with
pyslang 12.1.0. checks.json contains the precise RTL/testbench hashes and
compiler version, and individual logs preserve warnings. This is NOT dynamic
simulation, synthesis, or PPA evidence. A directed different-base/incomplete-
bias VCS case is still needed before declaring the repair dynamically verified.

## Remaining retirement hazards

This patch does NOT resolve simultaneous new command admission and retirement.
The prepared CMD_RETIRE probe is still expected to expose descriptor loss.
Also still to assess dynamically: simultaneous slot-1 issue and promotion
(the later iss[0] <= old iss[1] can discard that edge's advancement), queued
slot tags and scale ownership across promotion, and simultaneous GU bank take
and D bank release through the shared ownership-bank port. These require an
atomic state-transition design, not merely copying the descriptor.

Historical ordinary and overlap VCS reports remain unchanged. They refer to
the pre-repair RTL; no current-worktree VCS PASS is claimed.
