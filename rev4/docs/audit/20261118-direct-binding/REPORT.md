# Mode-bound Y acceptance — 2026-11-18

The y_run_evidence entry point now supports manifest test=yacc or yacc_direct. It selects the matching simulation record, run log and VCD filename, and records mode and filename in the binding. Both modes require a unique matching CHECK yacc_mode marker before PASS; direct also requires direct_drain=1 in manifest coverage and the experimental wrapper's source hash. All existing source/coverage/sync-receipt/hash checks remain required.

After successful binding, the orchestrator invokes the numerical checker with the bound mode and filename. It never retries with a different model if a comparison fails. Candidate logs paired with baseline mode markers, duplicated mode markers, changed wrapper source or incorrect waveform identity are rejected.

Four focused tests passed. They cover baseline metadata and normalization plus a direct fixture with independent wrapper/file names and mutations. These are metadata-binding tests with placeholder waveform bytes, not an actual candidate RTL simulation. The last full AF suite remains the separately recorded 289-test run; this isolated orchestration update was validated by its focused suite.

Use the same command for either mode:

    python NPU_eval/af/y_run_evidence.py ACTUAL-RUN-ID --out NEW-UNUSED-AUDIT-DIRECTORY

The run ID must identify a new completed simulation with the matching source and artifacts. No candidate VCD has arrived and no remote job was launched, so actual RTL numerical acceptance and all PPA claims remain pending. This supersedes the previous report's limitation that candidate provenance had to be checked manually; that historical report remains unchanged.
