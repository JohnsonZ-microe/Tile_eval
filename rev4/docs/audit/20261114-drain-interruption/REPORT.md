# DRAIN interrupted-read repair — 2026-11-14

Status: RTL/testbench change implemented; Python/control-port verification
passed. New VCS compile/simulation still required. Historical 216-packet VCD
belongs to the pre-repair RTL and is not evidence for this RTL revision.

## Trigger and failure mechanism

The earlier same-bank fence freezes DWAIT whenever commit is busy. If DRAIN
already issued a read before commit begins, the shared SRAM output can be
replaced by commit data during that pause. Resuming dwait_cnt at its previous
value can capture commit's last row instead of the requested DRAIN row.

Independent CommitReplay + DrainReplay + YReadPort reproduction, with DRAIN
slot 0 and commit slot 1: a commit starting 1..4 cycles after DRAIN causes
capture of row address 19 where address 0 is required. Delays 8..11 can affect
the next DRAIN row as well. This is modeled evidence of a concrete registered
port race, not a claim that a new VCS failure has been observed.

## Repair

In pe4_yacc DWAIT, a yield resets dwait_cnt to zero. After the whole-commit
fence ends, DRAIN reissues its original row request and waits through the full
registered mux/SRAM/build latency. DSEND, different-bank access, valid-ready
holding, numerical arithmetic and final-segment clearing are unchanged.

DrainReplay uses restart-on-yield by default. Historical read-port race probes
explicitly select restart_on_yield=False so their old failure evidence is not
silently erased. The VCD checker similarly preserves legacy-read policy only
when explicitly selected.

## Expanded RTL coverage and result gate

The bench now sweeps commit_lead -21..21 on each bank: negative values launch
commit after DRAIN. Every overlap packet retains numerical/metadata checking.
The address monitor checks every capture without the old interleaving skip.
Expected new run evidence:

    CHECK yacc_overlap banks=2 offsets=86 packets=172 yields=<positive>
    CHECK yacc_read_identity rows=3000
    PASS yacc packets=300 cycles=<positive>

The original 128 slot-coverage packets plus 172 overlap packets total 300.
The runner requires the new complete evidence; an old 216-packet PASS cannot
validate this bench. Existing logs/manifests were not rewritten.

## Local verification and limits

860 modeled combinations (2 drain banks x 2 commit banks x 5 masks x 43 offsets)
complete ten captures and ten beats each without any wrong address. The
readiness pattern includes stalls. A negative regression retains the old
wrong-address failure. Reset keeps the explicitly chosen replay policy.

Targeted suites: DRAIN/interruption, Y composition/port/source coverage,
runner diagnostics, supplied historical VCD, and final-Y source timing.
All are auxiliary Python evidence; source assertions do not substitute for HDL
compilation, numerical scoreboard execution or RTL functional coverage.

From current Tile_eval/rev4 on the VCS host, run:

    bash scripts/run_vcs.sh --test yacc --suite full --seed 817 --waves

After this new YACC run passes, continue the full Tile run with trace and
calibration-trace. New behavior requires a new source snapshot. No VCS/DC job
was started locally, and full Tile/physical PPA remain incomplete.
