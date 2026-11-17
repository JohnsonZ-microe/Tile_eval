# Sparse ALARM trajectory instrumentation

The existing calibration CSV contains no error-register trajectory. Its final expected-error value cannot prove intermediate event timing. The available bounded tile waveform does not cover the final illegal-command event.

Added two optional calibration channels in tb_tile_v4.sv. The simulation stimulus and RTL are unchanged. They are emitted only when CALIBRATION_TRACE is enabled. Existing schema-2 CSV columns remain unchanged; versioned event names specify the packed payload schema below.

| Event | Sample | Payload bits |
|---|---|---|
| alarm_inputs_v1 | pre | 21:0 err_new; 43:22 err_w1c; 65:44 mask-write data (zero when disabled); 66 mask-write enable; 74:67 err_first_pass_n; 75 alarm_ready |
| alarm_state_v1 | post | 21:0 err_q; 43:22 alarm_mask_q; 44 armed; 45 pending; 50:46 first bit; 58:51 first pass; 186:59 alarm payload |

Inputs are logged at the first active edge and on errors, effective W1C, mask writes or pending ALARMs. State is logged at the first active edge and whenever any packed state changes, after the existing #1 post-NBA sample. Unused mask data is normalized to zero to avoid logging irrelevant uninitialized bits. Other unknowns are not normalized; the strict CSV reader rejects unknown payload bits.

NPU_eval/af/alarm_trace_replay.py reconstructs omitted idle edges, requires input samples while an ALARM is pending, and compares every expected sparse state transition. It requires reset, initial state/input, ALARM generation and acceptance. It is conditional on observed error pulses and first-pass selection; it does not prove those input causes. Missing historical channels fail explicitly.

Validation: tile pyslang semantic elaboration passed (checks.json); 15 ALARM-related tests passed (alarm-tests.log), including corrupted/missing state, missing pending inputs, bad schema, absent coverage and sparse gaps. The ordinary November 16 trace was rejected as expected because it predates these channels (legacy-trace-rejection.log). New monitor dynamic behavior remains unverified until VCS output is received.

Future use: sync the changed testbench before the next planned tile run with --calibration-trace; waves are not required for these channels. From the LNS_DSE root, run `python NPU_eval/af/alarm_trace_replay.py Tile_eval/logs/<run>/calibration-events.csv`. This change does not require repeating the already completed runs immediately. No remote job was started. Existing historical manifests and trace files were preserved.
