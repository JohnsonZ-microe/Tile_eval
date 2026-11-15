# Simultaneous command admission and retirement candidate repair

Date: 2026-11-15. Status: implemented, locally compiled, NOT dynamically verified.

## Scheduler transition

The command latch now follows retirement NBAs in the sequential block. An
otherwise legal command sees old-state full rejection as before. If only the
old head was occupied and it retires on this edge, the command initializes
slot 0 after the promotion/clear assignments. Descriptor, issuer, phase_base,
tail_base and fresh operand/bias state are initialized together. Epilogue
outputs still read the old pre-edge descriptor. No extra admission pipeline
stage was introduced. Command capacity and old-full rejection are unchanged.

## Ownership ports

D retirement and GU admission can request release and take simultaneously.
They previously shared one bank selector, so changing only NBA order would
apply both operations to one bank. pe4_sched, tile_ffn_v4 and pe4_hbuf now
carry a separate release-bank bit. pe4_hbuf releases the old bank then accepts
an eligible take; same-bank release/take transfers ownership and clears row
validity, while a take of an occupied bank without matching release remains
illegal. This is an internal module interface change: standalone hbuf
instantiations must connect own_release_bank. All in-tree instantiations
were updated and semantically compiled.

No physical PPA claim is made. The additional bank selector and ownership
logic, and changed assignment priority, require synthesis/timing evaluation.

## Prepared checks

- Full Tile external CMD_RETIRE probe remains intact. It is now expected to
  pass, not to reproduce the original descriptor-loss failure. That expectation
  has not yet been observed with VCS.
- Promotion white-box tests cover GU-retire/D-admit and D-retire/GU-admit,
  checking the new descriptor, issuer, address bases, completion pulse and
  separate ownership-bank targets. These do not establish external reachability.
- Memory test drives actual hbuf ports through all four old/new bank pairs,
  checking owner identity, row-validity reset and the next legal row write.
- Python SlotReplay defaults to the repaired slot allocation behavior;
  legacy=True explicitly reproduces the historic lost-command transition.
  Five tests passed, including preserved old-full rejection and exact-once
  admission/retirement on both phase directions. Retirement is still supplied
  by the caller; this is not independent full-Tile calibration.

Nine tops pass local pyslang compilation (checks.json binds source hashes).
Twelve runner tests passed, including rejection of absent collision evidence.
The 41 existing source tests passed before the final additions to the directed
bench; their log is ../20261115-cmd-retire-repair-v2/source-tests.log.
No VCS simulation, mutation simulation, synthesis or complete regression PASS
is claimed for this worktree. Historic CSVs and VCS manifests are unchanged.

## Required remote validation after syncing current RTL, benches and runner

    bash scripts/run_vcs.sh --test promotion --suite smoke --seed 817
    bash scripts/run_vcs.sh --test memory --suite smoke --seed 817
    bash scripts/run_vcs.sh --test tile --suite full --seed 817 --cmd-retire-probe --trace --calibration-trace

Then repeat ordinary and overlap full Tile regressions. The promotion runner
now requires command_collision evidence as well as counters and migration.
Surrounding command offsets, old-full collision, same-bank external handoff,
concurrent arriving H data at ownership transfer and multi-seed coverage remain
open. A dynamic failure must be investigated before claiming this repair closes
the original defect. Full lifecycle/numerical Python calibration remains open.
