# First GU numeric classification with regenerated weights

The source hash of vectors.py is checked against the received manifest. The first FP4 GU weight/scale stream is regenerated from seed 817, base 64, using the generator's first make_stream call. Raw X/XS payloads provide activations and scales. All 1440 predicted PE acceptance cycles and tags match the ordinary trace. Classifying all accepted transactions finds the first numeric error at edge 107448, block 4; the derived ALARM sampling edge is 107486.

This establishes no earlier PE weight/scale error within the regenerated first-GU data. It is not a byte comparison against the remote rram.hex, which was not received. The hard-coded 107486 assertion is an expected-result check after prediction, not an event input; the generated schedule comes from classified transaction cycles. The dependent real-credit-output audit uses classified events, not that asserted timestamp.
