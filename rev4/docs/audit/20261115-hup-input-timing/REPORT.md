# GU output timing from external inputs — 2026-11-15

Both full Tile runs pass all 24 GU phase and output comparisons. Each run
matches 864 ACT inputs, 864 ACT outputs, 276 H_UP beats and 24 GU SYNC1 edges.
H_UP sideband (source, pass tag and last) also matches. Phase issue/consume/PE
checks remain enabled in the same script. Numerical payloads are not compared.

The model starts ACT from independently predicted final GU capture, not an
observed RTL commit or epilogue event. External credit inputs are supplied at
their original edge cycles. Registered bus output and SYNC1 are compared at
the next pre-edge trace sample; ACT inputs/outputs retain their consumed-edge
sampling. No timing offset is fitted to measured outputs.

NPU_eval/af/hup_input_replay.py composes GuEpilogue and BusReplay with explicit
initial_credit. Tests cover exact one-token cycles/sideband, credit-starved
completion, recovery at real supplied credit edges and over-return rejection.
Three tests passed. The previous full AF regression had 139 passing tests;
this new additive module was verified with its three dedicated tests.

Limits: each GU segment starts with explicitly assumed six available credits
and no competing Y/STATUS packet. This assumption has not yet been replaced
by continuous shared-bus state across the entire input stream. The model uses
zero placeholder H payload and must never be called numerical validation.
Bias data readiness is covered by the existing phase sequence in these inputs,
not a general delayed-bias epilogue test. Legal admission, settled CTX, slot
migration and bank ownership remain conditional, as in preceding reports.

The two supplied suites alternate GU/D; comparing every other SYNC1 is a
comparison selection, not an input to the model. This adapter is not suitable
for arbitrary interleaved phase order without explicit lifecycle integration.
Full Tile calibration, same-edge command-retirement repair, independent Y
output timing and PPA remain incomplete.

Reproduce from project root:

    python -B Tile_eval/rev4/docs/audit/20261115-hup-input-timing/check.py
    python -B -m unittest discover -s NPU_eval/af/tests -p test_hup_input_replay.py -v

checks.json contains complete predicted/actual GU SYNC1 lists and summary
comparisons; sources.json binds dependencies. Historical evidence is retained.

