# Final-Y DRAIN integration — 2026-11-14

Implemented in NPU_eval/rev4/drain_leaf_timing.py and shared by native and
generic final-DRAIN entrypoints. This is EXP-Y-001 timing correction, not a
change to RTL, physical clock or the frozen tree implementation.

## Behavior and boundary

The experiment already waits for all commits before final DRAIN. Each written
slot therefore needs no same-bank commit arbitration in this phase. After the
CMD reaches a leaf, head admission starts its read: first transferable beat at
accept+7, then each successful handshake schedules the next beat at +7. A
stalled valid beat remains eligible until actual tree acceptance. A queued next
packet cannot begin reading before the previous packet finishes; earliest new
acceptance is the next edge. Two hub output buffers and all tree link credits
remain active. Source metrics expose commands, leaf handshakes and aggregate
valid-stall leaf cycles; the latter is not exclusive wall-clock latency.

Mapping tree acceptance to yb_ready is an explicit experiment boundary
assumption. The YACC FSM has component-level waveform evidence; the complete
RTL bus launcher plus tree has not been calibrated. Generic FP32, padded and
segmented source behavior remains conditional. No claim is made about
concurrent-commit operation or standalone TileCycleModel's old launcher.

## Verification

- 48 combinations of packet lengths, queued arrival times, periodic readiness
  and long backpressure windows: every handshake agrees with independent
  DrainReplay, not merely a final-duration comparison.
- Direct fixture checks first handshake and all ten beat cycles against the
  observed seven-cycle schedule; mixed H traffic is explicitly rejected.
- Native suite: 9 tests passed. Generic suite: 7 tests passed, including
  native/generic equivalence, finite buffers and segmented-byte conservation.

## Quantified impact

Same tree and synthetic final-Y workload; numbers below are modeled cycles,
not device wall-clock measurements. Hold is cycles from hub capture to output
buffer release, with the existing next-edge handoff retained.

| batch | buffer hold | before | after | change |
|---:|---:|---:|---:|---:|
| 1 | 0 | 276 | 288 | +12 |
| 4 | 0 | 852 | 864 | +12 |
| 20 | 0 | 3924 | 3936 | +12 |
| 1 | 2000 | 276 | 288 | +12 |
| 4 | 2000 | 2744 | 2768 | +24 |
| 20 | 2000 | 20952 | 21072 | +120 |

Root beats remain 192 per token. The tree limits steady aggregate throughput
in these cases, so seven-cycle leaf spacing does not imply a proportional
increase in end-to-end latency. Repeated output-buffer stalls expose the
additional source startup cost on later groups. Raw before/after records are
preserved alongside this report; the after records include per-leaf timing.

## Reproduce

From LNS_DSE:

    python -B -m unittest discover -s NPU_eval/rev4/tests -v
    python -B -m unittest discover -s NPU_eval/generic/tests -v

Use npu_cycles.drain(batch, buffer_hold) for the six cases above.
Native/generic/animation source manifests now include the shared driver;
no historical output manifest or website snapshot was rewritten.

Next work: standalone bank-aware DRAIN/launcher integration, complete same-input
Tile calibration, more RTL coverage and physical PPA. Website results must bind
to newly generated snapshots rather than silently applying these new timings
to historical traces.
