# Continuous GU/Y output control composition

ContinuousOutputReplay joins the existing Y commit/drain control FSMs and ContinuousHupReplay on one persistent BusReplay. The source is the current RTL control behavior represented by those component models; sources.json binds implementation versions. No RTL changed.

Each tick samples the pre-edge drain valid/data identity, arbitrates H/Y/STATUS on the shared bus, then advances the Y producer with the resulting ready. GU captures and Y commits can progress concurrently. Credit and packet ownership persist between operations. Busy commits and drains are rejected explicitly; upstream command admission is outside this interface. Reset flushes both producers and resets the bus.

Four integrated tests passed: isolated Y event compatibility; Y packet locking against a later H and STATUS; credit exhaustion and recovery while retaining the pending Y row; simultaneous producer reset and busy command rejection.

In the directed competition case, a ten-beat Y packet transmits at edges 237,244,...,300. A GU capture at 179 makes H available at 240, but Y retains the link through its accepted last beat. H then sends at 301..305 and STATUS at 306. These are model edge predictions under the test's credit return policy, not received RTL measurements. This exposes how packet lock plus inter-beat Y latency can delay GU completion even while some link edges are idle. Changing that policy would require a protocol review and RTL verification; no policy change is made here.

With no credit returns, Y sends exactly six beats and then stalls. The pending row remains unchanged and H cannot bypass the locked Y packet. After explicit credits resume, the remaining four Y beats precede all five H beats, with no duplicate output or overflow.

Remaining scope: numerical Y/H payloads, core-generated capture/commit edges, scheduler admission, external CTRL decoding, generated STATUS responses and multi-tile links are not integrated. This composition has not yet been dynamically compared against a full RTL competition trace. The old isolated models and historical audits remain unchanged. Full AF regression output is in af-regression.log.
