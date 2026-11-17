# Persistent GU epilogue and shared uplink composition

Specification source: current pe4_bus.sv credit/arbitration registers and pe4_sched.sv GU epilogue. Source hashes are recorded in sources.json. No RTL changed.

ContinuousHupReplay composes GuEpilogue and BusReplay across successive captures without resetting credit or packet ownership. Reset alone restores six credits. Y and STATUS sources participate in the existing H > Y > STATUS launcher priority; a started packet holds ownership through its accepted last beat, including valid bubbles. Credits returned on an empty-credit edge enable sending on a subsequent edge, matching pre-edge RTL evaluation. Illegal credit overreturns are reported and discarded by BusReplay.

Five directed tests passed: isolated-edge compatibility with replay_hup; two GU captures sharing only six initial credits; delayed recovery; locked Y bubble blocking H followed by H priority over STATUS; reset cancellation and busy capture rejection; overreturn reporting. In the two-capture case, the second GU transmits only one beat before exhausting the remaining credit. This specifically detects accidental per-phase credit replenishment.

Interface: capture=(tokens, pass_id) is an explicit upstream capture event. Call tick once per edge, including idle edges. Hold Y/STATUS input beats until the corresponding bus_pre ready signal accepts them. bus_post contains registered post-edge values; calibration CSV samples those outputs on the following edge. retired_pass marks the current retirement edge. No output event is accepted as an input to this class.

Scope remains conditional: captures and Y/STATUS producers are supplied by the caller; payload arithmetic is not modeled. This is not yet the full continuous Tile scheduler, a calibrated multi-tile throughput model, or a replacement for retirement_prediction. No new dynamic RTL test has been run for this composition. Existing protocol waveform regression checks the underlying bus where available; full AF regression output is retained in af-regression.log.

Next integration: derive capture events from the scheduler/core, generate Y/STATUS streams with their real finite buffering, retain credit across complete Tile streams, and compare outputs and retirement against received traces. Do not seed that integration from observed output beats, observed retirement, or fresh per-phase credits.
