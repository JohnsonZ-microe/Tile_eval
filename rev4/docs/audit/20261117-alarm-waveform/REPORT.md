# Historical control waveform ALARM coverage audit

Conditional register comparison traversed 352 edges including three reset edges, two nonzero W1C writes and one mask write. No register mismatch occurred, but generated=0 and accepted=0. The checker deliberately rejects this as ALARM calibration evidence (checks.json status not_validated).

The VCD parser now optionally selects explicit additional hierarchy scopes while preserving its previous defaults. Two checker tests pass: the no-ALARM waveform is rejected, and a corrupted sticky register is caught before the coverage gate. The five existing bus waveform/model tests also pass after the parser extension. Current control testbench probes are tracked in sibling alarm-delivery-compile; new dynamic results are still required.
