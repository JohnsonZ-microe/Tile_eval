# Received protocol waveform: output arbitration coverage

The existing protocol_v4.vcd was replayed against BusReplay. All 1892 edges passed pre/post comparison, including 431 output beats (115 H, 150 Y, 166 STATUS), 728 FIFO pops, 362 credit-stall edges and four reset edges. Waveform, model and checker SHA-256 are in checks.json.

New exercised-condition counters: 247 edges with H/Y contention; 247 with all three sources requesting; 74 with H pending behind an active Y packet; six of those with Y valid low; 71 selected-H credit stalls; 170 selected-Y credit stalls. Conditions overlap and must not be summed as a partition of latency. H blocked by Y includes credit-empty edges; it is not a measurement of the delay caused solely by packet locking.

The six locked-Y bubble edges directly exercise the mechanism highlighted by ContinuousOutputReplay. All observed ready signals and registered bus outputs agree with the model. The regression also mutates output payload, credit state, FIFO data, sync and CTRL routing, confirming mismatches are rejected. Five bus tests passed after adding coverage conservation and nonzero checks.

Boundary: this is a historical received protocol component waveform. It is not a new full-Tile run, proof of source equivalence to current RTL, complete functional/code coverage, or calibration of GU capture and Y commit/drain production in the composite model. Current source hashes are retained for reproducibility; they do not establish the waveform's build provenance. Whole-Tile producer integration remains outstanding.

Reproduce with python NPU_eval/af/vcd_bus_check.py Tile_eval/vcd/protocol_v4.vcd and python -m unittest discover -s NPU_eval/af/tests -p test_bus_replay.py -v. Historical waveforms and logs were not modified.
