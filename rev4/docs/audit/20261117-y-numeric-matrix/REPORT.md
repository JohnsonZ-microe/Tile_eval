# Y numerical composition coverage expansion — 2026-11-17

Added deterministic command-level differential tests using seed 817. Expected FP32 additions and multiplications come from the existing Fraction reference; expected BF16 values use an independent Fraction quantizer on the BF16 exponent/significand grid, rather than the implementation formatter. The model under test uses integer dyadic arithmetic. Agreement remains differential software evidence, not exhaustive proof of FP32 arithmetic or RTL composition.

The COMMIT matrix covers both banks × all 16 lane masks × bias disabled/enabled = 64 configurations. Each performs two accumulating commits after partially enabled, overlapping D-buffer loads, including bases 77 and 127 to exercise the 80-column boundary. Slots are 0, 1, 62 and 63. Inputs mix deterministic random bit patterns with signed zero, subnormals, rounding boundaries, finite maximum, infinity and NaN examples. Assertions compare the entire D buffer, ordered physical writes, exact SRAM data/known masks and absence of writes in the other bank. Each slot then drains three intervals (0..2, 3..67 and 68..79) with randomized ready stalls; complete payloads, tags, segments, last bits and ownership are checked, including inactive lanes returning zero.

A separate sweep enumerates all 3,240 legal (start,count) intervals within 80 columns, each for valid and invalid slot state: 6,480 cases. The selected bank alternates with start+count; this is not a Cartesian sweep of both banks for every interval. Slot 63 tests the upper SRAM address boundary. Data identifies each column. Periodic ready stalls exercise holding. Assertions cover all output bytes and metadata, exact read count (zero for invalid slots), no writes, bounded completion, and ownership retained/released according to last_segment. last_segment alternates by count parity, rather than covering both settings for every interval.

These tests broaden the Y component's software coverage substantially. New RTL external-input waveform calibration remains pending; no remote run was started, and no new RTL, PPA or application throughput claim follows from these local tests.

Source hashes are in sources.json; focused.log retains the initial 64-configuration focused run, and af-regression.log records the full suite including the interval sweep.

Full AF regression: 278 tests passed in 51.057 seconds.
