# 2026-11-16 normal and overlap verification

Runs: `vcs-20261116T004029Z-67940` (normal), `vcs-20261116T011416Z-108706` (actual +OVERLAP).

Both have exit code 0, rtl_validation passed, PASS tile, 24 GU + 24 D completions, 108600 issued/returned/consumed requests, 9818 flits and 877 beats. All audited RTL, testbench, runner and file-list source hashes match current files (raw or LF-normalized). Overlap checked 24 promotion addresses; distinct_tail=0, so this run does not establish distinct-tail coverage.

Each trace passed H-buffer replay (4368 state edges, 24 takes, 24 releases, 4320 writes) and quantizer guard replay (4320 accepted/consumed transactions, zero mismatches, zero cancellation cases).

External-input retirement prediction matched all 48 registered SYNC1 cycles in each run. The prediction assumes idle context writes, isolated bus, idle Y commit and initial credit 6; it is not an unrestricted continuous shared-bus or numerical full-Tile model.

The sibling retirement and admission audit directories contain reproducible scripts and detailed comparisons. Admission uses predicted retirement times, never observed SYNC1 to drive the model. Check its checks.json for the final comparison result. Historical logs and manifests were not modified.
