# Control ALARM coverage acceptance gate

The runner now accepts new control simulations only when exactly one CHECK alarm_delivery cases=2 raw_protocol=1 mask_unmask=1 marker occurs before exactly one PASS control line. Existing clean-log and zero-exit checks remain. Accepted coverage is recorded in the simulation manifest as alarm_delivery_cases=2, raw_protocol=1 and mask_unmask=1.

All 14 run-diagnostic tests passed, including an eight-case new gate test: success plus missing marker, incomplete total, missing unmask case, duplicate marker, marker after PASS, duplicate PASS and Fatal rejection. This validates result handling, not dynamic RTL behavior.

Remote synchronization must include both scripts/run.py and tb/tb_control_v4.sv. Existing historical PASS logs are unchanged and remain historical evidence; the stricter gate governs new runs. The current local log directories still end at the November 16 ordinary/overlap runs, with no new control result received. The previously supplied control/full/seed817/waves command remains applicable. No remote execution was started.
