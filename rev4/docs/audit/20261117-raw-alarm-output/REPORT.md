# Raw protocol/CTRL to continuous ALARM output

AlarmControlOutputReplay connects raw reserved down types 6/7 to ERR_PROTO_TYPE, decodes targeted/broadcast CTRL writes with the top-level one-edge register delay, and supplies W1C/mask updates to AlarmReplay. ALARM, queued STATUS, H and Y share the continuous output bus. Reads of error status (0x008) and mask (0x00c) use pre-edge modeled state; other register reads require an explicit caller reader. Pending writes and all output/alarm state reset together.

Three integrated tests passed: two ALARM packets from raw reserved input and subsequent mask/unmask, wrong-target filtering and pre-edge read/clear behavior, reset cancellation and rejection of unknown read data. The read/clear collision test intentionally seeds a pending registered write to isolate same-edge semantics; it is not claimed to arise from two simultaneous external flits. Dynamic RTL verification of the new control testbench remains pending.

Other scheduler error sources and first-error pass identity remain explicit upstream inputs. This component does not silently replace numerical error generation, slot admission or register counters. It does not establish complete Tile coverage or sustained throughput. Full AF regression output is retained in af-regression.log.
