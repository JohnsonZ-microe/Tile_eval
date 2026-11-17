# Raw-protocol ALARM delivery probes

Current control bench previously masked NUMERIC and later all errors, so the received historical control waveform has no generated or accepted ALARM. Added two bounded probes after the existing context-busy reset: unmasked reserved down type 6 generates ERR_PROTO_TYPE, and a masked occurrence remains silent until unmask. Existing output scoreboard checks full payload=1 and STATUS sideband (tag F3, source TEST_ID, last=1). No alarm signal is forced. W1C rearm is asserted between cases; the existing 1000-cycle flush bound and 10000-cycle watchdog remain active.

The new marker is CHECK alarm_delivery cases=2 raw_protocol=1 mask_unmask=1 before PASS control. Existing numeric, context and reply checks remain. Reset clears driver credit debt and stall count before continuing. Replies count includes two extra ALARMs.

pyslang semantic compilation of control passed. Dynamic VCS behavior remains unverified. Run the control suite with waves to obtain a waveform exercising generation and acceptance, then replay it through vcd_alarm_check. The checker remains conditional on observed upstream error pulses and selected pass metadata; it verifies register state rather than error causes or slot selection.

Command from the remote Rev4 directory after syncing the changed testbench: bash scripts/run_vcs.sh --test control --suite full --seed 817 --waves. Require the marker and clean PASS/exit 0. No remote task was started in this session. RTL implementation is unchanged; only the testbench was extended.
