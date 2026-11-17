# Y SRAM waveform data replay

Both behavioral Y banks in the received yacc_v4.vcd match the LAT=2 SRAM model. Per bank: 98,112 checked edges, 1,500 writes, 3,012 read requests and 2,372 fully known valid data returns. Each bank also has 640 valid returns whose stored bytes are not initialized; these are counted but NOT numerically compared. No partial-byte writes occur in this waveform. All modeled rvalid values after idle priming match, including the unknown-data returns.

The checker observes only SRAM input ports (we/wbe/waddr/wdata/re/raddr) to advance memory/pipeline state. It compares observed registered rvalid and known rdata. No observed output is used to initialize stored data. Memory persists across controller reset, as the RTL wrapper has no reset. A known idle edge is required before activity to prime valid-state tracking.

Waveform SHA-256: 2baa34fd8477684040ef4462a322f193892b21faa91c9ad13660cb83d9a214e9. This matches the previously audited November 14 yacc waveform (../20261114-yacc-vcs-042332/checks.json). The current pe4_sram.sv hash matches the source recorded by vcs-20261114T042332Z-95723. New conclusions apply to this waveform, not automatically to later RTL versions or a physical macro.

Six focused SRAM/checker tests pass (tests.log). Negative fixtures corrupt bank data, valid timing, inputs and coverage; they are rejected. Partial byte masks and request-edge versus sample-edge writes are unit-tested but not claimed as waveform coverage here. The VCD parser collapses any mixed X/Z vector to unknown, so partially known output bits are not compared individually.

This validates the behavioral SRAM data component conditional on observed ports. It does not independently predict COMMIT/DRAIN address generation, arithmetic, shared-port arbitration or complete Tile execution. Next integration must drive these ports from model state and compare the full Y engine.

Reproduce from LNS_DSE root: python Tile_eval/rev4/docs/audit/20261117-y-sram-waveform/check.py. Original VCD and historical reports remain unchanged. No remote simulation was launched.
