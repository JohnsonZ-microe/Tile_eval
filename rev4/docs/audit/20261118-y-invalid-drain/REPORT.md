# Illegal DRAIN and zero-slot indication — 2026-11-18

Extended the numerical Y software coverage to all 62,296 illegal start/count combinations on the two eight-bit ports. The remaining 3,240 combinations are legal and were covered by the prior interval sweep. Each illegal command is issued while DRAIN is idle, followed by an idle edge. Assertions require an error on the command edge only, no output, no read request, no memory write and unchanged slot ownership/memory. Bank alternates with start parity; this is not a Cartesian sweep of bank, slot, segment, ready and all start/count values. Busy-command behavior is not covered by this sweep.

The external-input waveform checker now checks the post-edge v0_drain pulse independently from drain_illegal, and reports both counts. The expected zero-slot indication is derived from the pre-edge modeled validity bitmap and accepted legal command, never from observed internal state. This distinguishes an illegal interval (no packet) from a legal request for an invalid slot (zero packet).

The hand-derived fixture now includes an illegal zero-count command and a subsequent one-beat zero-slot packet. Mutation tests reject missing, extra or shifted v0_drain/error pulses in addition to existing data/address/timing corruptions. No new RTL or remote simulation was executed. Full external-input RTL calibration still requires a new yacc waveform exposing packed command inputs.

See af-regression.log and sources.json for regression evidence and analyzed source hashes.

Full AF regression: 280 tests passed in 61.561 seconds.
