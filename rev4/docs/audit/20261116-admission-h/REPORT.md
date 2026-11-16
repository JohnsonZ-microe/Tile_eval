# CTX/CMD admission through H-bank state — 2026-11-16

AdmissionHReplay composes ContextReplay, SlotReplay and HPathReplay. Inputs are
raw external down-port values plus an explicit head-retirement indication.
Old slot occupancy controls CMD acceptance and pending CTX writes. Accepted
GU commands produce a registered bank-take pulse on the following edge; a
retired D head produces a registered bank-release pulse. A simultaneous D
retirement/new GU may therefore generate both pulses with distinct bank IDs.
Reset clears slots, pulses and the H path; CTX storage retains the existing
ContextReplay contract and unprogrammed contexts are explicitly unsupported.

Five tests passed: raw CTX programming and GU-to-H completion, old-full rejection
on a retirement edge, same/different-bank D-to-GU handoff, CTX_BUSY using old
occupancy, reset flushing, and illegal command rejection. These are model tests,
not additional dynamic HDL evidence.

Conditional calibration of both full Tile traces passed:

| Run | Predicted take | Predicted release | Writes | Post-edge bank states |
| --- | ---: | ---: | ---: | ---: |
| vcs-20261115T151442Z-8320 | 24 | 24 | 4320 | 4368 |
| vcs-20261115T221329Z-18837 | 24 | 24 | 4320 | 4368 |

Every tuple (epoch, cycle, identity/value) matched, not just counts.
The checker does not seed bank ownership, write timing or readiness from RTL
observations. Unlike the prior H-path audit, bank_take/release are outputs of
the composed admission model. checks.json retains both predicted and observed
sequences and trace hashes. Sparse execution models 13969 edges in each run;
stable intervals are skipped only with no pending registered operation.

Critical condition: retirement is supplied as observed SYNC1 cycle minus one,
consistent with the RTL's registered completion pulse. Thus this does not prove
independent GU/D execution or completion timing. Compute, H_UP/Y epilogues and
bus arbitration still need to generate retirement within the continuous model.
This dependency is explicit and must not be used for AF throughput prediction
as though retirement had been independently calculated.

Only CTX register writes are supported by this composition. The adapter counts
ignored non-CTX register writes (zero in these traces); other CTRL functions
such as DRAIN are outside this component. Both traces initialize once, so they
do not validate the latest in-flight reset RTL candidate. No numerical payload
comparison or physical PPA result is implied. No RTL files changed in this step.
