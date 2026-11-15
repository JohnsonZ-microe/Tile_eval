# External CMD/CTX to issue sequence — 2026-11-15

The new NPU_eval/af/trace_config_replay.py feeds only extracted external inputs
into ContextReplay and the native command decoder. Registered CTRL writes are
applied on their next edge, including sparse-input gaps. Same-edge CMD versus
pending selected-context writes are rejected rather than silently reordered.
DUT observation channels are rejected as inputs; illegal commands are reported
separately and do not create expected issue streams.

Both supplied full Tile runs independently decode 48 phases. IssueStream then
predicts every address, pass, phase, kb and group in the 108600-request sequence.
All agree with each corresponding RTL trace. The final CMD_ILLEGAL input is
rejected at cycle 355987 (ordinary) and 355915 (overlap). No RTL memory_issue
fields were used to construct the phase configuration or expected addresses.

Explicit assumption: CTX writes occur while no slots are active. The adapter
requires callers to opt into this assumption, because slot occupancy has not
yet been integrated. Therefore these are conditional address-order results,
not independent predictions of admission, arbitration or issue cycles. The
existing check_issue_trace scope string describes that lower-level checker;
the outer decoded record supplies the external-input derivation.

Evidence: external-config-issue-check.json and external-config-sources.json.
Regression: four tests passed for raw configuration decoding, explicit
assumption enforcement, observation-channel rejection, pending-write collision,
and illegal-command exclusion. Tests use synthetic inputs, independently of
the two measured CSVs. Existing historical manifests remain unchanged.

Next integration: derive occupancy and eligibility from the scheduler model,
connect real X/XS/H arrival schedules, and compare exact issue cycles without
using observed scheduler events as model inputs. Numerical memory images and
whole-Tile output predictions are still required for full calibration.
