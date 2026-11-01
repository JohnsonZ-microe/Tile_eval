module tb_dot_v3;
    timeunit 1ns;
    timeprecision 1ps;
    import pe3_pkg::*;
    logic clk=0;
    always #0.5 clk=~clk;
    logic rst_n=0, in_valid=0, wide;
    logic [511:0] weights;
    logic [255:0] activations;
    logic [31:0] expected;
    logic finite_check;
    logic [284:0] expected_sum;
    wire narrow_valid,wide_valid,narrow_exact_valid,wide_exact_valid;
    wire [31:0] narrow_result,wide_result;
    wire signed [41:0] narrow_sum;
    wire signed [284:0] wide_sum;
    integer stream,fields,count;
    string directory;
    pe3_dot32 narrow_dot(clk,rst_n,in_valid && !wide,weights,activations,narrow_valid,narrow_result,narrow_sum,narrow_exact_valid);
    pe3_dot32 #(.WIDE(1)) wide_dot(clk,rst_n,in_valid && wide,weights,activations,wide_valid,wide_result,wide_sum,wide_exact_valid);
    initial begin
        #10000000;
        $fatal(1,"Dot watchdog timeout");
    end
    initial begin
        if (!$value$plusargs("VECTORS=%s",directory)) $fatal(1,"Missing vectors");
        stream=$fopen({directory,"/dot.txt"},"r");
        if (!stream) $fatal(1,"Cannot open dot vectors");
        count=0;
        repeat(2) @(negedge clk);
        rst_n=1;
        while (!$feof(stream)) begin
            fields=$fscanf(stream,"%h %h %h %h %h %h\n",wide,weights,activations,expected,finite_check,expected_sum);
            if (fields==-1 && $feof(stream)) break;
            if (fields!=6) $fatal(1,"Malformed dot vector");
            in_valid=1;
            @(posedge clk);
            @(negedge clk);
            in_valid=0;
            repeat(DOT_EXACT_DELAY) @(posedge clk);
            #0.001;
            if (!(wide ? wide_exact_valid : narrow_exact_valid)) $fatal(1,"Exact sum latency mismatch");
            if (finite_check && (wide ? wide_sum !== expected_sum : narrow_sum !== expected_sum[41:0]))
                $fatal(1,"Exact sum mismatch vector=%0d",count);
            repeat(DOT_STAGES-1-DOT_EXACT_DELAY) @(posedge clk);
            #0.001;
            if (!(wide ? wide_valid : narrow_valid) || (wide ? wide_result : narrow_result) !== expected)
                $fatal(1,"Dot result mismatch vector=%0d expected=%h narrow=%h wide=%h",count,expected,narrow_result,wide_result);
            count=count+1;
            @(negedge clk);
        end
        if (!count) $fatal(1,"Empty dot test");
        $fclose(stream);
        $display("PASS dot vectors=%0d",count);
        $finish;
    end
endmodule
