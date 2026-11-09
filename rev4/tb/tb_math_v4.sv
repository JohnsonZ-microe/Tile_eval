`timescale 1ns/1ps
module tb_math_v4;
    localparam integer LIMIT = 16384;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    // optional VCD (run.py --waves passes +VCD=<path>)
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_math_v4);
        end
    end
    integer fd, rc, fields, cycle = 0, checked = 0, rows = 0;
    integer bubble_mask = 0, reset_after = 0, prefix_rows = 0;
    integer fm_head = 0, fm_tail = 0, ac_head = 0, ac_tail = 0;
    integer qu_head = 0, qu_tail = 0, cancelled = 0;
    bit reset_done = 0;
    string vecdir, filename = "math.txt", line, kind, extra, result_name = "math";
    string token0, token1, token2, token3, token4, token5;
    logic [1023:0] a1, a2, a3, a4;
    logic fm_v = 0, fm_ov;
    logic [31:0] fm_a = 0, fm_b = 0, fm_r;
    pe4_fmul fmul_dut(.clk(clk), .rst_n(rst_n), .in_valid(fm_v),
        .a(fm_a), .b(fm_b), .out_valid(fm_ov), .result(fm_r));
    logic ac_v = 0, ac_ov;
    logic [31:0] ac_g[0:3], ac_u[0:3], ac_w[0:3];
    logic [15:0] ac_h[0:3];
    pe4_act act_dut(.clk(clk), .rst_n(rst_n), .in_valid(ac_v),
        .g(ac_g), .u(ac_u), .w(ac_w), .gb(16'd0), .ub(16'd0),
        .out_valid(ac_ov), .h(ac_h));
    logic qu_v = 0, qu_ov, qu_err;
    logic [511:0] qu_h = 0;
    logic [255:0] qu_q;
    logic [7:0] qu_se;
    logic [10:0] qu_tag = 0, qu_otag;
    pe4_quant quant_dut(.clk(clk), .rst_n(rst_n), .in_valid(qu_v),
        .in_h(qu_h), .in_tag(qu_tag), .out_valid(qu_ov), .out_q(qu_q),
        .out_se(qu_se), .out_tag(qu_otag), .err_nonfinite(qu_err));
    logic sg_v = 0;
    logic [15:0] sg_code = 0;
    logic [31:0] sg_val, sg_expected;
    pe4_sigmoid_rom sig_rom(.clk(clk), .code(sg_code), .value(sg_val));
    logic [31:0] exp_fm[0:LIMIT-1];
    logic [15:0] exp_ac[0:LIMIT-1][0:3];
    logic [255:0] exp_qu[0:LIMIT-1];
    logic [7:0] exp_se[0:LIMIT-1];
    logic [10:0] exp_tag[0:LIMIT-1];
    logic exp_nf[0:LIMIT-1];
    integer due_fm[0:LIMIT-1], due_ac[0:LIMIT-1], due_qu[0:LIMIT-1];

    task automatic clear_inputs;
        fm_v = 0; ac_v = 0; qu_v = 0; sg_v = 0;
    endtask
    task automatic tick;
        @(posedge clk);
        #1;
        cycle++;
        if (cycle > 200000) $fatal(1, "math watchdog");
        if (rst_n) begin
            if (fm_ov !== (fm_tail < fm_head && due_fm[fm_tail] == cycle))
                $fatal(1, "FM valid/latency cycle=%0d", cycle);
            if (ac_ov !== (ac_tail < ac_head && due_ac[ac_tail] == cycle))
                $fatal(1, "AC valid/latency cycle=%0d", cycle);
            if (qu_ov !== (qu_tail < qu_head && due_qu[qu_tail] == cycle))
                $fatal(1, "QU valid/latency cycle=%0d", cycle);
            if (fm_ov) begin
                if (fm_r !== exp_fm[fm_tail])
                    $fatal(1, "FM mismatch item=%0d got=%h expected=%h",
                           fm_tail, fm_r, exp_fm[fm_tail]);
                fm_tail++; checked++;
            end
            if (ac_ov) begin
                for (integer lane = 0; lane < 4; lane++)
                    if (ac_h[lane] !== exp_ac[ac_tail][lane])
                        $fatal(1, "AC mismatch item=%0d lane=%0d got=%h expected=%h",
                               ac_tail, lane, ac_h[lane], exp_ac[ac_tail][lane]);
                ac_tail++; checked++;
            end
            if (qu_ov) begin
                if (qu_q !== exp_qu[qu_tail] || qu_se !== exp_se[qu_tail] ||
                    qu_otag !== exp_tag[qu_tail] || qu_err !== exp_nf[qu_tail])
                    $fatal(1, "QU data/scale/tag/error mismatch item=%0d", qu_tail);
                qu_tail++; checked++;
            end
            if (sg_v) begin
                if (sg_val !== sg_expected)
                    $fatal(1, "SG mismatch code=%h got=%h expected=%h",
                           sg_code, sg_val, sg_expected);
                checked++;
            end
        end else if ({fm_ov, ac_ov, qu_ov} !== 3'b0)
            $fatal(1, "reset did not flush valid");
        @(negedge clk);
    endtask
    task automatic reset_pipeline;
        clear_inputs();
        rst_n = 0;
        cancelled += fm_head-fm_tail + ac_head-ac_tail + qu_head-qu_tail;
        fm_head = 0; fm_tail = 0; ac_head = 0; ac_tail = 0;
        qu_head = 0; qu_tail = 0; checked = 0; rows = 0;
        repeat (3) tick();
        rst_n = 1;
    endtask

    initial begin
        void'($value$plusargs("VECTORS=%s", vecdir));
        void'($value$plusargs("MATH_FILE=%s", filename));
        void'($value$plusargs("RESULT_NAME=%s", result_name));
        void'($value$plusargs("BUBBLE_MASK=%d", bubble_mask));
        void'($value$plusargs("RESET_AFTER=%d", reset_after));
        if (bubble_mask < 0 || reset_after < 0) $fatal(1, "invalid probe arguments");
        fd = $fopen({vecdir, "/", filename}, "r");
        if (!fd) $fatal(1, "missing math vectors");
        @(negedge clk);
        reset_pipeline();
        while ($fgets(line, fd)) begin
            clear_inputs();
            a1 = 0; a2 = 0; a3 = 0; a4 = 0; kind = ""; extra = "";
            rc = $sscanf(line, "%s %h %h %h %h %s", kind, a1, a2, a3, a4, extra);
            fields = $sscanf(line, "%s %s %s %s %s %s",
                             token0, token1, token2, token3, token4, token5);
            if (fields != rc || $isunknown({a1, a2, a3, a4}))
                $fatal(1, "invalid token row=%0d", rows);
            case (kind)
                "FM": begin
                    if (rc != 4 || fm_head >= LIMIT ||
                        |a1[1023:32] || |a2[1023:32] || |a3[1023:32])
                        $fatal(1, "malformed FM row=%0d", rows);
                    fm_v = 1; fm_a = a1[31:0]; fm_b = a2[31:0];
                    exp_fm[fm_head] = a3[31:0];
                    due_fm[fm_head] = cycle + 4;
                    fm_head++;
                end
                "AC": begin
                    if (rc != 5 || ac_head >= LIMIT || |a1[1023:128] ||
                        |a2[1023:128] || |a3[1023:128] || |a4[1023:64])
                        $fatal(1, "malformed AC row=%0d", rows);
                    ac_v = 1;
                    for (integer lane = 0; lane < 4; lane++) begin
                        ac_g[lane] = a1[32*lane +: 32];
                        ac_u[lane] = a2[32*lane +: 32];
                        ac_w[lane] = a3[32*lane +: 32];
                        exp_ac[ac_head][lane] = a4[16*lane +: 16];
                    end
                    due_ac[ac_head] = cycle + 24;
                    ac_head++;
                end
                "QU": begin
                    if (rc != 4 || qu_head >= LIMIT || |a1[1023:512] ||
                        |a2[1023:256] || |a3[1023:8])
                        $fatal(1, "malformed QU row=%0d", rows);
                    qu_v = 1; qu_h = a1[511:0];
                    qu_tag = (qu_head % 2) ? 11'h7ff : 11'(qu_head*73);
                    exp_qu[qu_head] = a2[255:0]; exp_se[qu_head] = a3[7:0];
                    exp_tag[qu_head] = qu_tag;
                    exp_nf[qu_head] = 0;
                    for (integer element = 0; element < 32; element++)
                        if (qu_h[16*element+7 +: 8] == 8'hff)
                            exp_nf[qu_head] = 1;
                    due_qu[qu_head] = cycle + 4;
                    qu_head++;
                end
                "SG": begin
                    if (rc != 3 || |a1[1023:16] || |a2[1023:32])
                        $fatal(1, "malformed SG row=%0d", rows);
                    sg_v = 1; sg_code = a1[15:0]; sg_expected = a2[31:0];
                end
                default: $fatal(1, "unknown/malformed vector row=%0d", rows);
            endcase
            rows++; prefix_rows++;
            tick();
            clear_inputs();
            if (!reset_done && reset_after > 0 && prefix_rows == reset_after) begin
                reset_pipeline();
                $rewind(fd);
                reset_done = 1;
            end else if ((rows & bubble_mask) != 0) tick();
        end
        $fclose(fd);
        clear_inputs();
        repeat (32) tick();
        if (rows == 0 || checked != rows || fm_head != fm_tail ||
            ac_head != ac_tail || qu_head != qu_tail)
            $fatal(1, "incomplete math rows=%0d checked=%0d", rows, checked);
        if (reset_after > 0 && (!reset_done || cancelled == 0))
            $fatal(1, "reset test did not cancel in-flight work");
        $display("PASS %s checked=%0d cancelled=%0d", result_name, checked, cancelled);
        $finish;
    end
endmodule
