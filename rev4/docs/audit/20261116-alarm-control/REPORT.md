# Sticky error and ALARM register model

AlarmReplay implements pe4_sched.sv error/ALARM registers: sticky set dominates W1C, lowest asserted error bit wins first identity when old status is zero, mask eligibility uses the pre-edge mask, output payload freezes while pending, and old pending/ready clearing wins same-edge regeneration. Register writes are predecoded registered inputs. The model does not generate upstream errors or select the active slot pass.

Four directed tests passed for first-error priority and payload stability, simultaneous clear/set and old-status identity semantics, registered mask/unmask behavior, and same-edge acceptance/regeneration plus reset. Source hashes are retained. This is model testing, not dynamic RTL comparison of this new component.

The missing received ALARM payload 0x51200040000 encodes pass 5, first error bit 18, sticky status 0x40000. pe4_pkg defines bit 18 as ERR_NUMERIC; tile_ffn_v4 ORs PE numeric sticky-edge detection into that error while the scheduler also reports quantizer numeric errors. These observations diagnose the gap, but are not used to schedule a synthetic error. Independent numeric-event generation and active-slot identity must be integrated before using actual credits in full output replay. The earlier real-credit mismatch remains unresolved.
