module tb_tile_pe_v3;
    timeunit 1ns;
    timeprecision 1ps;
    import pe3_pkg::*;
    logic in_ready, expected_ready;
    logic clk = 0;
    always #0.5 clk = ~clk;
    logic rst_n = 0, in_valid = 0;
    logic [2:0] in_wfmt;
    logic [1023:0] in_weights, in_activations;
    logic [31:0] in_activation_scales, in_tag;
    logic [255:0] in_weight_scales;
    logic [3:0] in_token_mask;
    logic [6:0] in_col_base;
    logic in_first, in_last;
    logic busy, out_valid, out_done;
    logic [31:0] out_tag;
    logic [3:0] out_token_mask;
    logic [7:0] out_col_mask;
    logic [6:0] out_col_base;
    logic [1023:0] out_results;
    logic [1:0] out_error, error_sticky;
    logic [6:0] rd_col = 0;
    logic [1:0] rd_lane = 0;
    logic rd_valid;
    logic [31:0] rd_data;
    logic expected_valid, expected_done, expected_busy;
    logic [31:0] expected_tag, expected_rf;
    logic [3:0] expected_token_mask;
    logic [7:0] expected_col_mask;
    logic [6:0] expected_col_base;
    logic [1:0] expected_error, expected_sticky;
    logic [1023:0] expected_results;
    integer stream, fields, cycles, commits, rf_count;
    integer accepted_at [logic [31:0]];
    integer maximum_run, current_run;
    string directory, wave_path;
    tile_pe_v3 dut (.*);

    initial begin
        #1000000;
        $fatal(1, "Simulation watchdog timeout");
    end
    initial begin
        if (!$value$plusargs("VECTORS=%s", directory)) $fatal(1, "Missing +VECTORS");
        if ($value$plusargs("VCD=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(1, tb_tile_pe_v3);
            $dumpvars(0, tb_tile_pe_v3.dut);
        end
`ifdef ENABLE_FSDB
        if ($value$plusargs("FSDB=%s", wave_path)) begin
            $fsdbDumpfile(wave_path);
            $fsdbDumpvars(1, tb_tile_pe_v3);
            $fsdbDumpvars(0, tb_tile_pe_v3.dut);
        end
`endif
        stream = $fopen({directory, "/array.txt"}, "r");
        if (!stream) $fatal(1, "Cannot open array vectors");
        cycles = 0;
        commits = 0;
        maximum_run = 0;
        current_run = 0;
        while (!$feof(stream)) begin
            @(negedge clk);
            fields = $fscanf(stream, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                rst_n, in_valid, in_wfmt, in_weights, in_activations, in_activation_scales,
                in_weight_scales, in_token_mask, in_col_base, in_first, in_last, in_tag,
                expected_valid, expected_done, expected_tag, expected_token_mask, expected_col_mask,
                expected_col_base, expected_error, expected_sticky, expected_results, expected_busy, expected_ready);
            if (fields == -1 && $feof(stream)) break;
            if (fields != 23) $fatal(1, "Malformed array vector cycle=%0d fields=%0d", cycles, fields);
             #0.001;
            if (in_ready !== expected_ready) $fatal(1, "ready mismatch cycle=%0d actual=%b expected=%b", cycles, in_ready, expected_ready);
            if (!rst_n) accepted_at.delete();
            else if (in_valid && in_ready) accepted_at[in_tag] = cycles;
            @(posedge clk);
            #0.001;
            if (out_valid !== expected_valid || out_done !== expected_done || busy !== expected_busy || error_sticky !== expected_sticky)
                $fatal(1, "control mismatch cycle=%0d valid=%b/%b done=%b/%b busy=%b/%b sticky=%h/%h", cycles, out_valid, expected_valid, out_done, expected_done, busy, expected_busy, error_sticky, expected_sticky);
            if (out_valid) begin
                if (!accepted_at.exists(out_tag)) $fatal(1, "Unmatched/reset-flushed tag=%h", out_tag);
                if (cycles - accepted_at[out_tag] != COMMIT_DELAY) $fatal(1, "Revision 3 latency mismatch");
                accepted_at.delete(out_tag);
                if (out_tag !== expected_tag || out_token_mask !== expected_token_mask ||
                    out_col_mask !== expected_col_mask || out_col_base !== expected_col_base ||
                    out_error !== expected_error || out_results !== expected_results)
                    $fatal(1, "result mismatch cycle=%0d tag=%h expected_tag=%h error=%h/%h results=%h expected=%h", cycles, out_tag, expected_tag, out_error, expected_error, out_results, expected_results);
                commits = commits + 1;
                current_run = current_run + 1;
                if (current_run > maximum_run) maximum_run = current_run;
            end else current_run = 0;
            cycles = cycles + 1;
        end
        $fclose(stream);
        if (accepted_at.num() != 0 || busy) $fatal(1, "Undrained pipeline");
        @(negedge clk);
        in_valid = 0;
        stream = $fopen({directory, "/rf.txt"}, "r");
        if (!stream) $fatal(1, "Cannot open RF vectors");
        rf_count = 0;
        while (!$feof(stream)) begin
            fields = $fscanf(stream, "%h %h %h\n", rd_col, rd_lane, expected_rf);
            if (fields == -1 && $feof(stream)) break;
            if (fields != 3) $fatal(1, "Malformed RF vector");
            #0.001;
            if (!rd_valid || rd_data !== expected_rf) $fatal(1, "RF mismatch col=%0d lane=%0d expected=%h actual=%h", rd_col, rd_lane, expected_rf, rd_data);
            rf_count = rf_count + 1;
        end
        $fclose(stream);
        if (rf_count != 320 || commits == 0 || maximum_run < 40) $fatal(1, "Insufficient coverage");
        $display("PASS array cycles=%0d commits=%0d RF=%0d max_contiguous_commits=%0d stages=%0d edge_distance=%0d", cycles, commits, rf_count, maximum_run, PIPE_STAGES, COMMIT_DELAY);
        $finish;
    end
endmodule
