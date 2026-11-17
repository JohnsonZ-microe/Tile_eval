# Opt-in direct DRAIN RTL candidate — 2026-11-18

Added pe4_yacc parameter DIRECT_DRAIN, default 0. Baseline capture writes dphit and DSEND presents it on the following edge. With the parameter set, the capture edge writes yb_payload, yb_valid, yb_last, yb_segment and yb_tag together. DSEND holds the registered output until accepted and performs the existing next-row/ownership transition. SRAM request timing, whole-COMMIT fence, interrupted-read restart and invalid-slot zero behavior are unchanged. The standard Tile instantiation uses the default; no optimized Tile performance result is claimed.

The explicit tb_yacc_direct_v4 top instantiates the same parameterized yacc testbench with DIRECT_DRAIN=1. It reuses numeric payload checks, 300 packets, 3,000 read-identity checks, overlap offsets, the reset assertion and 62,296 illegal intervals. VCD dumping includes the nested probe instance. It emits a separate PASS yacc_direct plus CHECK yacc_mode direct=1. The runner requires this mode marker and all common coverage. Experimental waves use yacc_direct_v4.vcd; baseline uses yacc_v4.vcd. The VCS --test all list remains baseline-only, while semantic --test all includes the explicit candidate.

Validation: semantic elaboration passed for baseline yacc, experimental yacc_direct and normal Tile. Sixteen runner diagnostic tests and two waveform-argument tests passed. An initial generated test had a string-escaping syntax error, corrected before the passing rerun; its failed log is preserved. A test discovery attempt used a nonexistent test_run_waves.py pattern and ran no tests; the correct test_protocol_waves.py was then run successfully. No VCS simulation, synthesis, timing or power validation has been performed for this candidate.

When running an explicit comparison from updated sources:

    bash scripts/run_vcs.sh --test yacc --suite full --seed 817 --waves
    bash scripts/run_vcs.sh --test yacc_direct --suite full --seed 817 --waves

The candidate has a nested waveform hierarchy and changed output timing. Existing baseline-only numerical replay must not be used to certify it; candidate-aware replay remains to be added. Dynamic failure/latency results and synthesis evidence are required before considering default enablement. No remote job was launched here.
