# Retirement counter boundary probes — 2026-11-15

This extends tb_promotion_v4, not the production datapath. Eight white-box
cases cross two retirement paths (GU/D) and four initial counter conditions:
ordinary value 7, maximum minus one, maximum, and clear coincident with
retirement (seed 19). State is released before the edge under test.

Each case verifies: blocked retirement leaves GU/D/SYNC1 counters unchanged;
retirement increments only its phase counter; maximum saturates; clear wins
for all thirteen counters; the registered SYNC1 counts on the following edge;
and another idle edge cannot count the same completion twice.

Clear semantics are intentionally explicit: a clear at the retirement edge
zeros all counters, but the registered SYNC1 pulse is consumed on the next
edge and increments CNT_SYNC1 to one. The two phase counters remain zero.
This preserves the existing clear priority and registered-pulse accounting,
and does not assert that GU+D=SYNC1 across a mid-flight counter clear.

Required new evidence line before PASS promotion:

    CHECK counters paths=2 cases=8 blocked=8 saturation=4 clear=2 no_double=8

The runner rejects missing, incomplete, duplicate or late counter evidence.
Twelve runner tests passed, including missing counter coverage and missing
clear coverage rejection. Nine tops passed local pyslang semantic compilation.
The eight cases above are REQUIRED coverage, not observed simulation coverage.
No VCS job was launched. No new dynamic PASS is claimed.

Invocation after synchronizing the current RTL, testbench and runner:

    bash scripts/run_vcs.sh --test promotion --suite smoke --seed 817

The existing eighteen migration cases run first, followed by these eight
counter cases. PASS promotion cases=18 continues to identify the migration
case count; the separate CHECK counters identifies the eight counter cases.
The suite remains white-box and does not close external-interface reachability,
new-command/retire collision, full numerical replay, or physical PPA.
