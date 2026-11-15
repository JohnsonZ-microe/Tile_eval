# Scheduler slot boundary audit — 2026-11-15

Reference: current pe4_sched.sv CMD latch followed by P_HUP/P_DCOMMIT retirement.
The bus supplies cmd_valid combinationally from external down inputs.

Implemented slot_replay.py models pre-edge occupancy, first-free allocation,
full-slot rejection and head retirement with old slot-1 promotion. Context
write busy is evaluated from pre-edge occupancy. Retirement remains an explicit
input; the model is a component, not an independent whole-Tile scheduler.

## Source-derived admission loss

With old slot0 occupied and slot1 empty, a legal CMD is assigned into slot1.
If the same edge completes H_UP or enters an available DCOMMIT retirement,
later nonblocking assignments set slot0 to OLD slot1 and clear slot1. Thus
the new descriptor is overwritten without the full-slot CMD_ILLEGAL check
firing. Issuer and phase_base migration use the same old-state order. This is
a source/model finding; a directed HDL reproduction is still required.

Do not fix only the descriptor: admission also initializes issuer state,
phase_base, bias/operand state and bank ownership. A complete fix must preserve
these and recheck old-head epilogue reads. No RTL change was made in this audit.

Four tests pass: two-slot admission/full rejection/promotion, exact collision
reproduction, commands one edge before/after retirement, and reset/descriptor
ownership. These tests intentionally preserve the current RTL failure as a
negative baseline; passing them does not mean the hazard is repaired.

## Existing trace coverage

Both runs accept/retire 48 phases, have no same-edge command/retire collision,
no busy CTX writes, and end with both slots empty. Ordinary peak occupancy is
one; overlap peak occupancy is two. Therefore the received VCS passes do not
close this boundary. trace-boundaries.json retains the measurements.

The diagnostic derives retirement edge from pre-edge SYNC1 cycle minus one,
consistent with the RTL registered SYNC1. This is observed-boundary coverage,
not independent retirement prediction; it must not replace the external-input
model's still-explicit idle-CTX assumption.

## Required next verification

Drive a legal second command on the old head's GU last-H_UP edge and DCOMMIT
retirement edge, plus neighboring edges; check exact-once command completion,
issue descriptor/address conservation, slot promotion and bank ownership.
Include old slot1 occupied (old-state full rejection) and credit-stalled H_UP.
Then connect independently predicted epilogue completion to the slot model.

## Directed HDL reproducer prepared

Optional `--cmd-retire-probe` on the current runner passes +CMD_RETIRE_PROBE
only to the Tile bench. Default and ordinary overlap behavior remain unchanged.
For each valid D CMD, the replay waits on falling edges until the real H_UP
valid/ready/last handshake is ready, then drives the unmodified input CMD.
No internal DUT signal is forced or written. The positive-edge monitor checks
after NBA settlement that exactly one D descriptor with the expected pass
survives and its issuer is valid. A bounded wait prevents a silent hang.
The original payload/metadata scoreboard and final checks remain active.

Runner acceptance requires one CHECK cmd_retire with a positive count equal
to half the final SYNC1 count, before clean PASS. Missing/zero/partial/late
coverage is rejected. Eleven runner tests passed, including coverage gates.
The new SystemVerilog has not been compiled locally (no HDL simulator found).

After syncing the changed runner and testbench to the VCS host, from rev4:

    bash scripts/run_vcs.sh --test tile --suite full --seed 817 --cmd-retire-probe --trace --calibration-trace

Current RTL is expected to fail at the first collision with CMD_RETIRE
command lost/duplicated. This is a predicted failure, not yet observed VCS
evidence. No new remote job was launched. Preserve its snapshot and logs.
The probe currently covers GU-last-H_UP plus D admission only. DCOMMIT plus
next-GU admission, surrounding offsets and stalled-credit cases remain required.
The RTL fix is still pending; this step establishes an executable reproducer
before changing intertwined descriptor/issuer/bank updates.
