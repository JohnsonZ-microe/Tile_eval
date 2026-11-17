# Command error event prediction

check.py replays raw CTX/CMD/H inputs with the existing conditional retirement predictions. Command errors are registered and delivered on the following edge. SCAN has UNSUPPORTED priority, including on full slots; other illegal descriptors and pre-edge full slots generate CMD_ILLEGAL.

Both runs preserve all checked bank takes/releases/writes/states. Predicted CMD_ILLEGAL accumulator-input cycles are 355988 (ordinary) and 355916 (overlap). These internal event cycles have not been independently waveform-compared. The output integration and validation limits are documented in ../20261117-command-error-output/REPORT.md.

Full local AF regression: 234 tests passed; see af-regression.log. sources.json fingerprints inputs and model/RTL sources. Retirement inputs remain conditional predictions, not a complete shared-resource scheduler.
