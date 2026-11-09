`timescale 1ns/1ps
module tb_cells_v4;
    import pe4_pkg::*;
    logic clk = 0, rst_n = 0, in_valid = 0, out_valid;
    always #5 clk = ~clk;
    // optional VCD (run.py --waves passes +VCD=<path>)
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_cells_v4);
        end
    end
    logic [31:0] partial_value = 0, weight_scale = 0, result;
    logic [7:0] activation_scale = 127;
    logic [2:0] fmt = 0;
    pe3_scale dut(.*);
    logic [31:0] expected[0:16383];
    integer due[0:16383];
    integer head = 0, tail = 0, cycle = 0, fd, rc;
    integer format_value, scale_value, exponent_value, enc_checked = 0;
    logic [31:0] partial_bits, weight_bits, expected_bits;
    logic [7:0] expected_code;
    string vecdir, line, extra;
    task automatic tick;
        @(posedge clk); #1; cycle++;
        if (rst_n) begin
            if (out_valid !== (tail < head && due[tail] == cycle))
                $fatal(1, "scale valid/latency");
            if (out_valid) begin
                if (result !== expected[tail])
                    $fatal(1, "scale item=%0d got=%h expected=%h",tail,result,expected[tail]);
                tail++;
            end
        end
        @(negedge clk);
    endtask
    initial begin
        if (!$value$plusargs("VECTORS=%s", vecdir)) $fatal(1, "VECTORS required");
        if (fp32_to_bf16(32'h7f800001) !== 16'h7fc0 ||
            fp32_to_bf16(32'hffc00001) !== 16'hffc0 ||
            fp32_to_bf16(32'h80000000) !== 16'h8000 ||
            fp32_to_bf16(32'h7f800000) !== 16'h7f80 ||
            fp32_to_bf16(32'h3f808000) !== 16'h3f80 ||
            fp32_to_bf16(32'h3f818000) !== 16'h3f82)
            $fatal(1, "BF16 cast boundary/special");
        fd = $fopen({vecdir,"/encode.txt"},"r");
        if (!fd) $fatal(1, "missing encode vectors");
        while ($fgets(line,fd)) begin
            rc = $sscanf(line,"%h %d %h %s",partial_bits,exponent_value,expected_code,extra);
            if (rc != 3) $fatal(1, "bad encode row");
            if (e4m3_encode(partial_bits,12'(exponent_value)) !== expected_code)
                $fatal(1, "encode mismatch input=%h exponent=%0d",partial_bits,exponent_value);
            enc_checked++;
        end
        $fclose(fd);
        fd = $fopen({vecdir,"/scale.txt"},"r");
        if (!fd) $fatal(1, "missing scale vectors");
        @(negedge clk); repeat (3) tick(); rst_n = 1;
        while ($fgets(line,fd)) begin
            rc = $sscanf(line,"%d %h %d %h %h %s",format_value,partial_bits,
                         scale_value,weight_bits,expected_bits,extra);
            if (rc != 5 || head >= 16384) $fatal(1, "bad scale row");
            fmt = 3'(format_value); partial_value = partial_bits;
            activation_scale = 8'(scale_value); weight_scale = weight_bits;
            expected[head] = expected_bits; due[head] = cycle + pe3_pkg::SCALE_STAGES;
            head++; in_valid = 1; tick(); in_valid = 0;
            if (head % 7 == 0) tick();
        end
        $fclose(fd); in_valid = 0; repeat (20) tick();
        if (head == 0 || enc_checked == 0 || tail != head) $fatal(1, "incomplete cells");
        $display("PASS cells scale=%0d encode=%0d",tail,enc_checked);
        $finish;
    end
endmodule
