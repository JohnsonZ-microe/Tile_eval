# Bound yacc numerical replay acceptance — 2026-11-18

Added y_run_evidence.py to require completed/passed yacc status, zero exit, unique complete PASS, overlap/read-identity/illegal-interval coverage markers before PASS, and manifest coverage matching the log. It compares the local Y RTL dependencies, testbench and runner against manifest hashes, reporting exact bytes versus LF normalization explicitly. It requires the current VCD sync receipt tag, SHA256 and size to match the selected run, plus the remote manifest waveform size.

Only then does it invoke external-input numerical replay and require 3,000 accepted Y beats and 62,296 illegal-DRAIN pulses. The VCD hash from replay must still match the binding. Results, errors and Python source hashes are saved into a new output directory; existing directories are never overwritten. The remote manifest has no waveform hash, so the binding relies on the local tagged sync receipt plus remote size, not an authenticated remote hash. This workflow assumes sources are not edited during the run.

Three focused tests pass, covering successful metadata binding, line-ending normalization, changed sources, wrong-run receipts, damaged waveforms, missing/late/duplicate coverage markers, fatal log text, mismatched manifest coverage and invalid run identifiers. Test fixtures intentionally contain placeholder VCD bytes and test binding only; they are not RTL replay evidence. The full Python suite was not rerun for this isolated orchestration addition; the latest full result remains 280 tests from the preceding audit.

The actual historical run vcs-20261114T042332Z-95723 was rejected for missing the new illegal-interval marker, with failure retained under historical-rejection/checks.json. No historical success has been upgraded. Two initial local test attempts exposed source-generation escaping errors; these were corrected before the passing focused run. New full RTL numerical acceptance remains pending fresh artifacts.

After receiving a new run, from the project root:

    python NPU_eval/af/y_run_evidence.py vcs-YYYYMMDDTHHMMSSZ-PID --out Tile_eval/rev4/docs/audit/NEW-UNUSED-DIRECTORY

Replace the run identifier and output directory with the actual run and a new audit name. Missing receipt/source/coverage evidence produces a saved failed result instead of numerical success. No remote job is launched by this tool.
