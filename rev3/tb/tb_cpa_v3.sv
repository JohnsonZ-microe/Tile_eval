module tb_cpa_v3;
    timeunit 1ns;
    timeprecision 1ps;
    logic clk=0;
    always #0.5 clk=~clk;
    logic rst_n=0, in_valid=0;
    logic [284:0] left_value, right_value, expected285, queued285, check285;
    logic [41:0] expected42, queued42, check42;
    logic [47:0] expected48, queued48, check48;
    wire [284:0] result285;
    wire [41:0] result42;
    wire [47:0] result48;
    wire valid285, valid42, valid48;
    logic queued_valid=0, check_valid;
    integer stream,fields,count=0,drain=0;
    string directory;
    pe3_cpa2 #(.WIDTH(285)) wide(clk,rst_n,in_valid,left_value,right_value,valid285,result285);
    pe3_cpa2 #(.WIDTH(42)) narrow(clk,rst_n,in_valid,left_value[41:0],right_value[41:0],valid42,result42);
    pe3_cpa2 #(.WIDTH(48),.CHUNK(24)) product_adder(clk,rst_n,in_valid,left_value[47:0],right_value[47:0],valid48,result48);
    initial begin
        #10000000;
        $fatal(1,"CPA watchdog timeout");
    end
    initial begin
        if (!$value$plusargs("VECTORS=%s",directory)) $fatal(1,"Missing vectors");
        stream=$fopen({directory,"/cpa.txt"},"r");
        if (!stream) $fatal(1,"Cannot open CPA vectors");
        while (drain < 2) begin
            @(negedge clk);
            if (!$feof(stream)) begin
                fields=$fscanf(stream,"%h %h %h %h %h %h %h\n",rst_n,in_valid,left_value,right_value,expected42,expected48,expected285);
                if (fields == 7) count=count+1;
                else if (fields == -1 && $feof(stream)) begin rst_n=1; in_valid=0; drain=drain+1; end
                else $fatal(1,"Malformed CPA vector");
            end else begin rst_n=1; in_valid=0; drain=drain+1; end
            check_valid=rst_n && queued_valid;
            check42=queued42; check48=queued48; check285=queued285;
            queued_valid=rst_n && in_valid;
            queued42=expected42; queued48=expected48; queued285=expected285;
            @(posedge clk);
            #0.001;
            if (valid42 !== check_valid || valid48 !== check_valid || valid285 !== check_valid)
                $fatal(1,"CPA valid mismatch vector=%0d",count);
            if (check_valid && (result42 !== check42 || result48 !== check48 || result285 !== check285))
                $fatal(1,"CPA result mismatch vector=%0d",count);
        end
        if (!count) $fatal(1,"Empty CPA test");
        $fclose(stream);
        $display("PASS cpa vectors=%0d",count);
        $finish;
    end
endmodule
