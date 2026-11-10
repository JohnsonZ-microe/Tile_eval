// 04 Compute Core: checkpoint-level verification of the multi-precision
// matrix computation pipeline (frozen rev3 PE, tile_pe_v3).
// Drives the PE directly with FP4 stimulus; probes pipeline boundaries;
// compares against a Python golden trace; reports per-checkpoint PASS/FAIL
// and coverage ratio.  +VECTORS=<dir> reads compute_trace.txt.
`timescale 1ns/1ps
module tb_compute_v4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile); $dumpvars(0, tb_compute_v4);
        end
    end
    // ---- PE stimulus ----
    logic pe_in_valid = 0, pe_in_ready, pe_out_valid, pe_busy;
    logic [2:0] pe_wfmt = 0;
    logic [1023:0] pe_weights = 0, pe_acts = 0, pe_out_results;
    logic [31:0] pe_ascales = 0, pe_tag = 0;
    logic [255:0] pe_wscales = 0;
    logic [3:0] pe_mask = 4'b0001;
    logic [6:0] pe_col_base = 0, pe_out_col_base;
    logic pe_first = 0, pe_last = 0;
    tile_pe_v3 dut (
        .clk(clk), .rst_n(rst_n), .in_valid(pe_in_valid),
        .in_ready(pe_in_ready), .in_wfmt(pe_wfmt),
        .in_weights(pe_weights), .in_activations(pe_acts),
        .in_activation_scales(pe_ascales), .in_weight_scales(pe_wscales),
        .in_token_mask(pe_mask), .in_col_base(pe_col_base),
        .in_first(pe_first), .in_last(pe_last), .in_tag(pe_tag),
        .busy(pe_busy), .out_valid(pe_out_valid), .out_done(),
        .out_tag(), .out_token_mask(), .out_col_mask(),
        .out_col_base(pe_out_col_base), .out_results(pe_out_results),
        .out_error(), .error_sticky(),
        .rd_col(7'd0), .rd_lane(2'd0), .rd_valid(), .rd_data());
    // ---- golden trace ----
    localparam int MAX_KB = 3, MAX_COL = 8;
    logic [31:0] exp_fp32  [0:MAX_KB-1][0:MAX_COL-1];
    logic [31:0] exp_scale [0:MAX_KB-1][0:MAX_COL-1];
    logic [31:0] exp_rf    [0:MAX_KB-1][0:MAX_COL-1];
    logic [3:0]  w_codes   [0:MAX_KB-1][0:MAX_COL-1][0:31];
    logic [7:0]  a_codes   [0:31];
    logic [7:0]  ascale_val = 127, wscale_val = 127;
    // ---- counters ----
    integer total_checks = 0, pass_checks = 0;
    integer cp_pass [0:5], cp_total [0:5];
    string cp_names [0:5];

    task automatic check(input integer cp_id, input string desc,
                         input logic [31:0] expect_val, input logic [31:0] actual_val);
        begin
            total_checks++; cp_total[cp_id]++;
            if (expect_val === actual_val) begin
                pass_checks++; cp_pass[cp_id]++;
                $display("  %s %s  exp=%08h act=%08h  [PASS]",
                         cp_names[cp_id], desc, expect_val, actual_val);
            end else
                $display("  %s %s  exp=%08h act=%08h  [FAIL]",
                         cp_names[cp_id], desc, expect_val, actual_val);
        end
    endtask
    // ---- file parsing ----
    integer fd, rc;
    string vecdir, path, line_str;
    logic [1023:0] tmp_hex;
    integer tmp_kb, tmp_col, tmp_j;

    task automatic load_trace;
        begin
            path = {vecdir, "/compute_trace.txt"};
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FATAL cannot open %s", path); $finish;
            end
            forever begin
                rc = $fgets(line_str, fd);
                if (rc == 0) break;
                if (line_str.len() > 4) begin
                    if (line_str.substr(0, 6) == "CP_FP32") begin
                        void'($sscanf(line_str, "CP_FP32 %d %d value=%h",
                                      tmp_kb, tmp_col, tmp_hex));
                        if (tmp_kb < MAX_KB && tmp_col < MAX_COL)
                            exp_fp32[tmp_kb][tmp_col] = tmp_hex[31:0];
                    end else if (line_str.substr(0, 7) == "CP_SCALE") begin
                        void'($sscanf(line_str, "CP_SCALE %d %d value=%h",
                                      tmp_kb, tmp_col, tmp_hex));
                        if (tmp_kb < MAX_KB && tmp_col < MAX_COL)
                            exp_scale[tmp_kb][tmp_col] = tmp_hex[31:0];
                    end else if (line_str.substr(0, 4) == "CP_RF") begin
                        void'($sscanf(line_str, "CP_RF %d %d value=%h",
                                      tmp_kb, tmp_col, tmp_hex));
                        if (tmp_kb < MAX_KB && tmp_col < MAX_COL)
                            exp_rf[tmp_kb][tmp_col] = tmp_hex[31:0];
                    end else if (line_str.substr(0, 6) == "WEIGHT ") begin
                        void'($sscanf(line_str, "WEIGHT %d %d %d %h",
                                      tmp_kb, tmp_col, tmp_j, tmp_hex));
                        if (tmp_kb < MAX_KB && tmp_col < MAX_COL && tmp_j < 32)
                            w_codes[tmp_kb][tmp_col][tmp_j] = tmp_hex[3:0];
                    end else if (line_str.substr(0, 3) == "ACT ") begin
                        void'($sscanf(line_str, "ACT %d %h", tmp_j, tmp_hex));
                        if (tmp_j < 32) a_codes[tmp_j] = tmp_hex[7:0];
                    end
                end
            end
            $fclose(fd);
            $display("Loaded golden trace from %s", path);
        end
    endtask

    function automatic logic [1023:0] build_weights(input integer kb);
        logic [1023:0] w = 0;
        for (int c = 0; c < 8; c++)
            for (int j = 0; j < 32; j++)
                w[c*128 + j*4 +: 4] = w_codes[kb][c][j];
        return w;
    endfunction

    function automatic logic [1023:0] build_activations();
        logic [1023:0] a = 0;
        for (int j = 0; j < 32; j++) a[j*8 +: 8] = a_codes[j];
        return a;
    endfunction

    // ---- pipeline monitors ----
    integer dot_seq = 0, scale_seq = 0, commit_seq = 0;
    integer kb_idx, col_idx;
    // Module-level flat arrays in tile_pe_v3 (no generate-block indexing):
    //   dot_valid[c][0] == columns[c].lanes[0].dot.out_valid
    //   scale_valid[c][0] == the pe3_scale out_valid
    always @(posedge clk) begin
        if (rst_n) begin
            for (int c = 0; c < 8; c++) begin
                if (dut.dot_valid[c][0] && dot_seq < MAX_KB*8) begin
                    kb_idx = dot_seq / 8; col_idx = dot_seq % 8;
                    check(1, $sformatf("kb=%0d col=%0d fp32", kb_idx, col_idx),
                          exp_fp32[kb_idx][col_idx], dut.partials[c][0]);
                    dot_seq++;
                end
                if (dut.scale_valid[c][0] && scale_seq < MAX_KB*8) begin
                    kb_idx = scale_seq / 8; col_idx = scale_seq % 8;
                    check(2, $sformatf("kb=%0d col=%0d scale", kb_idx, col_idx),
                          exp_scale[kb_idx][col_idx], dut.scaled[c][0]);
                    scale_seq++;
                end
            end
            if (pe_out_valid && commit_seq < MAX_KB*8) begin
                for (int c = 0; c < 8; c++) begin
                    kb_idx = commit_seq; col_idx = c;
                    check(4, $sformatf("kb=%0d col=%0d commit", kb_idx, col_idx),
                          exp_rf[kb_idx][col_idx],
                          pe_out_results[(c*4+0)*32 +: 32]);
                end
                commit_seq++;
            end
        end
    end

    // ---- main ----
    integer drain;
    initial begin
        cp_names = '{"CP_DOT32 ", "CP_FP32   ", "CP_SCALE  ",
                    "CP_RF     ", "CP_COMMIT ", "CP_RDBK   "};
        for (int i = 0; i < 6; i++) begin cp_pass[i] = 0; cp_total[i] = 0; end
        if (!$value$plusargs("VECTORS=%s", vecdir)) vecdir = "vectors";
        load_trace();
        repeat (3) @(negedge clk); rst_n = 1; @(negedge clk);
        for (integer kb = 0; kb < MAX_KB; kb++) begin
            $display("=== k_block %0d ===", kb);
            pe_wfmt = 3'd0; pe_weights = build_weights(kb);
            pe_acts = build_activations();
            pe_ascales = {24'b0, ascale_val};
            pe_wscales = {224'b0, wscale_val};
            pe_mask = 4'b0001; pe_col_base = 7'd0;
            pe_first = (kb == 0); pe_last = (kb == MAX_KB-1);
            @(negedge clk);
            while (!pe_in_ready) @(negedge clk);
            pe_in_valid = 1; @(negedge clk); pe_in_valid = 0;
            repeat (60) @(negedge clk);
        end
        drain = 0;
        while (!pe_out_valid && drain < 300) begin
            @(negedge clk); drain++;
        end
        repeat (100) @(negedge clk);
        for (integer col = 0; col < MAX_COL; col++)
            check(5, $sformatf("rf[%0d][0]", col),
                  exp_rf[MAX_KB-1][col], dut.rf[col][0]);
        $display(""); $display("==============================================");
        $display("  Compute Core Checkpoint Summary");
        $display("==============================================");
        for (int i = 0; i < 6; i++)
            if (cp_total[i] > 0)
                $display("  %s  %0d/%0d  %0d%%", cp_names[i],
                         cp_pass[i], cp_total[i],
                         cp_total[i] > 0 ? cp_pass[i]*100/cp_total[i] : 0);
        $display("----------------------------------------------");
        $display("  TOTAL       %0d/%0d  coverage=%0d%%",
                 pass_checks, total_checks,
                 total_checks > 0 ? pass_checks*100/total_checks : 0);
        $display("==============================================");
        if (pass_checks == total_checks && total_checks > 0)
            $display("PASS compute checkpoints=%0d coverage=100%%", total_checks);
        else
            $display("FAIL compute pass=%0d total=%0d coverage=%0d%%",
                     pass_checks, total_checks,
                     total_checks > 0 ? pass_checks*100/total_checks : 0);
        $finish;
    end
endmodule
