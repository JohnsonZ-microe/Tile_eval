# Numerical Y producer on shared credit bus — 2026-11-17

NumericOutputReplay composes YNumericReplay with the existing GU epilogue and BusReplay. The Y source reads its modeled SRAM, computes real accumulated values, formats BF16 rows and holds data until the shared bus accepts it. It no longer supplies a precomputed Y packet or synthetic fixed-cadence source. H payloads and STATUS remain explicit external inputs; no claim is made that upstream PE/ACT arithmetic or scheduler admission is modeled here.

The experiment preloads D=2, uses weight=3 and BF16 bias=1, then commits one slot. Y therefore contains 5. An optional second same-bank COMMIT at edge 233 interrupts an outstanding DRAIN read; all drained values must then be 10. H payloads carry distinct identities. The 40-case matrix covers token counts 1..4, credit return delays 1/6/7/16/64 and both commit patterns. Every case checks exact H/Y/STATUS payload order, packet lock, six-credit conservation, no same-edge zero-credit bypass, write counts and final slot release. Credits are returned only for accepted beats, never from a preset output schedule. Reset coverage verifies flushed producers/ownership and retained SRAM contents.

## Timing findings (model experiment, not measured Tile throughput)

For one token and one-edge credit return, the first Y beat is edge 237 and last is 300: 10 useful beats over a 64-edge inclusive packet window (15.625%). H is ready at 240 but blocked by Y lock for 61 edges, including 52 Y-invalid bubble edges. GU retires at 305 and STATUS sends at 306. This reproduces the earlier timing-only analysis while verifying actual modeled SRAM data.

With a 64-edge credit return delay, Y ends at 323, GU retires at 381 and STATUS sends at 388. Y-lock bubble edges remain 52, while total H lock wait rises to 84 edges. Thus source bubbles and credit starvation are distinct causes; improving read overlap cannot remove downstream credit delay.

The interrupting COMMIT allows H to take the bus before Y acquires its packet lock: GU retires at 244 and STATUS at 245, but Y is delayed to edges 464..527 (or ..550 with 64-edge credit return). Faster H in this case does not mean higher overall throughput: Y completion is substantially later. Scheduler evaluation must account for both classes and full workload completion.

## Optimization target and limits

At an unchanged first-Y edge and with sufficient credits, an ideal continuous ten-beat packet would end at 246 rather than 300, a 54-edge packet-span reduction. This is an optimistic bound, not an implemented or validated optimization. Investigate overlapping row reads with queued row data while preserving same-bank COMMIT fencing, stale-read invalidation, backpressure and reset semantics. Whole-packet buffering would hold 1,280 payload bits before metadata; that capacity is a comparison point, not a proved minimum or area estimate. Additional registers/control can increase area and switching. No energy/area gain is claimed without synthesis and activity evidence.

The composed numerical Y path still awaits external-input VCS calibration. Independently validated bus and arithmetic components do not establish the full composition automatically. checks.json records all cases and accepted beats; sources.json binds the code used. Full AF regression is in af-regression.log.

Full AF regression: 276 tests passed in 46.059 seconds.
