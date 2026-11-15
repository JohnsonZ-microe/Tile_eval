# External-input Y output timing — 2026-11-15

Both supplied ordinary and overlap full Tile traces match every predicted Y
output event: 24 commit triggers, 60 slot-valid publications, 60 DRAIN accepts,
600 Y bus beats and 24 D SYNC1 edges per run. Publication bank/slot, DRAIN
bank/slot and bus sideband/tag/segment/last match as well. GU/D issue, consume
and PE timing checks remain active in this combined audit.

Commit timing comes from the independent D phase prediction: final scheduler
capture at E0 selects P_DCOMMIT; E1 registers trigger/SYNC1; YACC and the
pre-edge monitor sample those at E2. The commit model receives external CMD
bank/mask/slots. DRAIN fields are decoded from raw addressed CTRL flits;
registered top-level dispatch supplies the YACC command one edge later.
No observed y_ready, y_commit, drain_accept or output edge drives the model.

CommitReplay, DrainReplay, YControlReplay and BusReplay compose through
pre-edge valid/ready and registered clear/set semantics. Output payload is an
explicit zero placeholder: this is timing/metadata validation, not numerical
Y prediction. The VCS numerical scoreboard is separate evidence.

replay_y requires explicit initial_credit. Three tests pass for complete
packet edges/metadata, rejecting commands while busy and bounded failure
under credit starvation. A full AF regression was not repeated for this
additive module; the prior full regression passed 139 tests.

Remaining assumptions and missing scope:
- Per-D segment starts with six credits, an idle bus and empty Y bitmap;
  no competing H/STATUS packet or previous retained Y slot is modeled.
- Input suites drain each segment before the next GU; this does not model
  arbitrary retained accumulation, overlapping experts or continuous slots.
- Legal admission, CTX write idleness and bank ownership remain conditional.
- The real traces contain one STATUS beat generated from an error state;
  its observed timing is NOT fed back to make the bus replay appear complete.
- Same-edge CMD/retirement remains an unresolved RTL risk with a prepared
  directed probe. Physical PPA and complete AF throughput remain unverified.

Reproduce from project root:

    python -B Tile_eval/rev4/docs/audit/20261115-y-input-timing/check.py
    python -B -m unittest discover -s NPU_eval/af/tests -p test_y_output_replay.py -v

checks.json contains per-phase and Y-event comparisons and trace hashes;
sources.json binds model dependencies. Historical artifacts are unchanged.
