module tb_rf8_candidate;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk = 0, rst_n = 0, in_valid = 0, in_ready;
    always #0.5 clk = ~clk;
    logic [2:0] in_wfmt = 0;
    logic [1023:0] in_weights = 0, in_activations = {128{8'h38}};
    logic [31:0] in_activation_scales = {4{8'h7f}}, in_tag = 0;
    logic [255:0] in_weight_scales = 0;
    logic [3:0] in_token_mask = 15;
    logic [6:0] in_col_base = 0;
    logic in_first = 0, in_last = 0;
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
    integer cycle = 0, accepted = 0, committed = 0, ncols = 8;
    integer accepted_at [0:47];
    integer last_accept = -100;
    tile_pe_rf8 dut(.*);

    function automatic logic [31:0] exact_integer(input integer value);
        integer leading;
        logic [31:0] normalized;
        leading = 0;
        for (integer bit_index = 0; bit_index < 31; bit_index++)
            if ((value >> bit_index) != 0) leading = bit_index;
        normalized = 32'(value) << (23-leading);
        return {1'b0,8'(127+leading),normalized[22:0]};
    endfunction

    initial begin
        #10000;
        $fatal(1,"RF8 watchdog");
    end
    always @(posedge clk) begin
        if (rst_n && in_valid && in_ready) begin
            if (in_tag >= 48 || in_tag != accepted) $fatal(1,"accept tag order");
            if (in_tag % 8 != 0 && cycle-last_accept != 8) $fatal(1,"RF8 acceptance distance");
            accepted_at[in_tag] = cycle;
            last_accept = cycle;
            accepted++;
        end
        #0.01;
        if (rst_n && out_valid) begin
            if (out_tag >= 48 || out_tag != committed || cycle-accepted_at[out_tag] != 35)
                $fatal(1,"commit order/latency");
            if (out_error !== 0 || error_sticky !== 0 || out_token_mask !== 15 || out_col_base !== 0 ||
                out_col_mask !== 8'((1<<ncols)-1) || out_done !== (out_tag%8 == 7))
                $fatal(1,"commit metadata");
            for (integer column = 0; column < 8; column++)
                for (integer lane = 0; lane < 4; lane++)
                    if (out_results[(column*4+lane)*32 +: 32] !==
                        (column<ncols ? exact_integer(32*(int'(out_tag)%8+1)) : 32'b0))
                        $fatal(1,"RF8 arithmetic tag=%0d col=%0d lane=%0d",out_tag,column,lane);
            committed++;
        end
        cycle++;
    end
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (integer fmt = 0; fmt < 6; fmt++) begin
            ncols = fmt == 0 || fmt == 4 ? 8 : fmt == 5 ? 2 : 4;
            in_wfmt = 3'(fmt);
            in_weights = 0;
            if (fmt == 0) in_weights = {256{4'h2}};
            else if (fmt == 4) in_weights = {256{4'h1}};
            else if (fmt == 5) in_weights = {64{16'h3f80}};
            else in_weights = {128{8'h38}};
            for (integer column = 0; column < 8; column++)
                in_weight_scales[32*column +: 32] = fmt <= 1 ? 32'h7f :
                    fmt == 2 ? 32'h3f800000 : 32'h3f80;
            for (integer block_id = 0; block_id < 8; block_id++) begin
                @(negedge clk);
                in_valid = 1;
                in_tag = 32'(fmt*8+block_id);
                in_first = block_id == 0;
                in_last = block_id == 7;
                do @(posedge clk); while (!in_ready);
            end
            @(negedge clk);
            in_valid = 0;
            while (busy) @(negedge clk);
            if (committed != (fmt+1)*8) $fatal(1,"missing format commits");
        end
        if (accepted != 48 || committed != 48) $fatal(1,"incomplete RF8 test");
        $display("PASS rf8 formats=6 requests=48 commits=48");
        $finish;
    end
endmodule
