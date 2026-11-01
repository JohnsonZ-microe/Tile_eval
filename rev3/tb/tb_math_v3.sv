module tb_math_v3;
    timeunit 1ns;
    timeprecision 1ps;
    import pe3_pkg::*;
    logic clk = 0;
    always #0.5 clk = ~clk;
    logic rst_n = 0;
    logic [31:0] operation, left_value, right_value, auxiliary, expected;
    logic [4:1] request;
    wire [4:1] valid_result;
    wire [31:0] result [1:4];
    logic [31:0] expected_pipe [1:4][0:SCALE_STAGES-1];
    logic valid_pipe [1:4][0:SCALE_STAGES-1];
    integer stream, fields, count, drain, depth;
    string directory;
    pe3_add add_unit(.clk(clk),.rst_n(rst_n),.in_valid(request[1]),.bypass(1'b0),
        .left_value(left_value),.right_value(right_value),.out_valid(valid_result[1]),.result(result[1]),.commit_value());
    pe3_mul mul_unit(clk,rst_n,request[2],1'b0,left_value,right_value,valid_result[2],result[2]);
    pe3_shift shift_unit(clk,rst_n,request[3],left_value,$signed(right_value[10:0]),valid_result[3],result[3]);
    pe3_scale scale_unit(clk,rst_n,request[4],left_value,auxiliary[10:8],auxiliary[7:0],right_value,valid_result[4],result[4]);
    initial begin
        #10000000;
        $fatal(1,"Math watchdog timeout");
    end
    initial begin
        if (!$value$plusargs("VECTORS=%s",directory)) $fatal(1,"Missing vectors");
        stream = $fopen({directory,"/math.txt"},"r");
        if (!stream) $fatal(1,"Cannot open math vectors");
        request = 0;
        count = 0;
        for (integer unit_index=1; unit_index<=4; unit_index=unit_index+1)
            for (integer stage=0; stage<SCALE_STAGES; stage=stage+1) valid_pipe[unit_index][stage]=0;
        repeat(2) @(negedge clk);
        rst_n = 1;
        drain = 0;
        while (drain < SCALE_STAGES+1) begin
            request = 0;
            if (!$feof(stream)) begin
                fields=$fscanf(stream,"%h %h %h %h %h\n",operation,left_value,right_value,auxiliary,expected);
                if (fields == 5) begin
                    count=count+1;
                    if (operation == 0) begin
                        if ({16'b0,decode_weight(left_value[15:0],right_value[2:0])} !== expected)
                            $fatal(1,"Decode mismatch vector=%0d",count);
                    end else if (operation<=4) request[operation]=1;
                    else $fatal(1,"Unknown math operation");
                end else if (!(fields == -1 && $feof(stream))) $fatal(1,"Malformed math vector");
            end else drain=drain+1;
            for (integer unit_index=1; unit_index<=4; unit_index=unit_index+1) begin
                for (integer stage=SCALE_STAGES-1; stage>0; stage=stage-1) begin
                    valid_pipe[unit_index][stage]=valid_pipe[unit_index][stage-1];
                    expected_pipe[unit_index][stage]=expected_pipe[unit_index][stage-1];
                end
                valid_pipe[unit_index][0]=request[unit_index];
                expected_pipe[unit_index][0]=expected;
            end
            @(posedge clk);
            #0.001;
            for (integer unit_index=1; unit_index<=4; unit_index=unit_index+1) begin
                depth=unit_index==1 ? FPADD_STAGES-1 : unit_index==2 ? MUL_STAGES-1 : unit_index==3 ? SHIFT_STAGES-1 : SCALE_STAGES-1;
                if (valid_result[unit_index] !== valid_pipe[unit_index][depth]) $fatal(1,"Math valid mismatch unit=%0d",unit_index);
                if (valid_pipe[unit_index][depth] && result[unit_index] !== expected_pipe[unit_index][depth])
                    $fatal(1,"Math mismatch unit=%0d expected=%h actual=%h input_count=%0d",unit_index,expected_pipe[unit_index][depth],result[unit_index],count);
            end
            @(negedge clk);
        end
        if (!count) $fatal(1,"Empty math test");
        $fclose(stream);
        $display("PASS math vectors=%0d",count);
        $finish;
    end
endmodule
