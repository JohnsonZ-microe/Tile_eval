# Y control and SRAM integration — 2026-11-17

YMemoryReplay combines COMMIT and DRAIN control, the registered shared read mux, and both LAT=2 behavioral SRAM banks. Read requests and SRAM writes cross their registered boundaries; DRAIN captures pre-edge SRAM output. Controller reset retains SRAM contents and applies an already pending physical write.

The arithmetic write value is explicitly supplied by a callback. This is not an independent implementation of Y accumulation or BF16 packet formatting. Existing yacc waveforms do not expose COMMIT slots arrays, so complete external-input waveform calibration remains pending. Earlier conditional mux and SRAM waveform audits are separate evidence.

Tests cover command-driven read/write addresses, same-slot COMMIT interruption returning newly written data, and reset with a pending write. The interruption regression now uses the integrated SRAM model rather than the removed YReadPort abstraction: 860 combinations of both bank selections, five lane masks, and 43 relative command offsets, with periodic output backpressure. Initialized data encodes bank/address, allowing checks of validity, known bits, address and data on every DRAIN capture. Restoring the old pause-without-restart behavior reproduces the wrong-address failure (expected 0, observed 19).

The original full regression log is retained as af-regression.log: it failed importing the removed class. The corrected full regression result is recorded separately in af-regression-fixed.log. Source hashes are in sources.json.

The second regression (af-regression-fixed.log) exposed a stale fixed total of 431 upstream beats in the imported-waveform test after the new 1,024-beat protocol VCD arrived. The test now binds the VCD hash to its sync receipt and compares FIFO/H/Y/STATUS counts with the unique PASS line in the corresponding run log. All five corruption checks remain enabled. The final regression is in af-regression-final.log.

Final validation: all 255 AF tests passed in 41.761 seconds, including integrated interruption sweeps and waveform corruption rejection.
