# Command-driven Y numerical composition — 2026-11-17

YNumericReplay removes the external write-value dependency for Y numerical operation. Inputs are registered D-buffer loads, COMMIT bank/mask/slots/weights/bias, DRAIN commands, ready and reset. It composes independent integer arithmetic with the existing control FSMs, registered read mux, two behavioral SRAM banks and BF16 DRAIN formatter. Upstream PE dot products remain outside this component: D-buffer values are already weighted FP32 inputs.

Arithmetic operand sampling relative to CRD request generation: multiply inputs +1; old SRAM return capture +4; D-buffer/bias-add inputs +6; Y-add inputs +14; Y-add result +20; controller write pulse +21; physical SRAM write +22. Inputs are sampled before same-edge registered D-buffer updates. Values may be calculated at sample time in Python, but they are unavailable to memory until the modeled result/write edges. There is one serialized row job, matching current RTL. These offsets derive from source sequencing and the separately calibrated 4/7-stage arithmetic pipelines; full external-input waveform calibration of the composed path remains pending.

COMMIT weights and bias are copied at acceptance. Per-lane validity snapshots are taken at the trigger, including duplicate slots. Known old memory data/address is required only for valid snapshots. Reset flushes numerical jobs and D-buffer state while preserving SRAM contents and any physical write already registered before the reset edge.

Six focused tests cover all four lanes/two accumulating commits followed by drained BF16 packets, same-edge D-buffer write versus adder sampling, immutable accepted command inputs, each of 24 reset offsets, unknown old data rejection, same-bank COMMIT interrupting an outstanding DRAIN, and duplicate-slot snapshot behavior. The first focused run had a test expectation omitting the next row multiply at +23; the expectation now includes that event, consistent with the 22-edge row interval. No model delay was changed to hide the event.

The yacc testbench now exposes packed slots and weights aliases in VCD. They only observe external DUT inputs, enabling a future full numerical replay without reconstructing inputs from internal operands. The updated testbench passes semantic elaboration; dynamic simulation is pending, together with the preceding addb_v reset fix. The same existing yacc full-suite seed 817 waves command captures both changes. Historical VCD/manifests were not modified.

See sources.json, compile/checks.json and af-regression.log for provenance and validation. This is a Y-component integration step, not full Tile/NPU calibration, SRAM macro validation or PPA evidence.

Full AF regression: 270 tests passed in 45.626 seconds.
