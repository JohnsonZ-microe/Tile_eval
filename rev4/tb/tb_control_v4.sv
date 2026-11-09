`timescale 1ns/1ps
module tb_control_v4;
    parameter logic [5:0] TEST_ID = 6'd16;
    localparam logic [31:0] EXPECTED_ID = 32'h80000300 | {26'b0, TEST_ID};
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic dn_valid = 0, up_valid, sync0, sync1, err_line;
    logic [511:0] dn_payload = 0;
    logic [31:0] dn_sideband = 4;
    logic [1:0] up_credit = 0;
    logic [127:0] up_payload;
    logic [23:0] up_sideband;
    tile_ffn_v4 #(.RRAM_WORDS(16), .SRC_ID({26'b0, TEST_ID})) dut(.clk(clk), .rst_n(rst_n),
        .dn_valid(dn_valid), .dn_payload(dn_payload), .dn_sideband(dn_sideband),
        .up_valid(up_valid), .up_credit(up_credit), .up_payload(up_payload),
        .up_sideband(up_sideband), .sync0(sync0), .sync1(sync1), .err_line(err_line),
        .sim_load(1'b0), .sim_addr(21'd0), .sim_data(1024'd0));
    logic [127:0] expected_data[0:511];
    logic [23:0] expected_sb[0:511];
    integer head = 0, tail = 0, debt = 0, cycles = 0, stalls = 0;
    bit return_enable = 1;
    task automatic tick;
        #1;
        up_credit = return_enable && debt > 0 ? 1 : 0;
        #1;
        if (dut.bus_u.credit == 0 && dut.st_valid) stalls++;
        debt -= int'(up_credit);
        @(posedge clk); #1; cycles++;
        if (cycles > 10000) $fatal(1, "control watchdog");
        if (up_valid) begin
            if (tail >= head || up_payload !== expected_data[tail] ||
                up_sideband !== expected_sb[tail])
                $fatal(1, "STATUS sequence/data index=%0d got=%h/%h expected=%h/%h",
                       tail,up_sideband,up_payload,expected_sb[tail],expected_data[tail]);
            tail++; debt++;
        end
        if (dut.sched_u.cnt[9] !== 32'(stalls)) $fatal(1, "credit stall counter");
        if (dut.stf_cnt > 2) $fatal(1, "STATUS FIFO range");
        @(negedge clk);
    endtask
    task automatic control(input integer target, op, address, value);
        dn_valid = 1;
        dn_sideband = 32'(4 | ((head & 255) << 3));
        dn_payload = 512'(op) | (512'(target) << 4) |
                     (512'(address) << 11) | (512'(value) << 23);
        if (op == 2 && (target == int'(TEST_ID) || target == 127)) begin
            expected_data[head] = {83'b0,1'b0,12'(address),32'(value)};
            expected_sb[head] = {4'b0,2'b0,1'b1,8'(head),1'b0,TEST_ID,2'd2};
            head++;
        end
        tick(); dn_valid = 0;
    endtask
    task automatic flush;
        integer waited = 0;
        dn_valid = 0;
        while (tail != head || debt != 0) begin
            tick(); waited++;
            if (waited > 1000) $fatal(1, "missing STATUS response");
        end
        repeat (5) tick();
    endtask
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (integer index = 0; index < 16; index++) begin
            control(int'(TEST_ID),1,256+4*index,32'h12340000+index);
            tick();
        end
        for (integer target = 0; target < 128; target++)
            control(target,2,0,EXPECTED_ID);
        flush();
        for (integer index = 0; index < 64; index++)
            control(index % 2 ? int'(TEST_ID) : 127,2,256+4*(index%16),32'h12340000+(index%16));
        flush();
        return_enable = 0;
        for (integer index = 0; index < 8; index++) begin
            control(int'(TEST_ID),2,0,EXPECTED_ID);
            repeat (4) tick();
        end
        repeat (40) tick();
        if (dut.stf_cnt !== 2 || stalls == 0) $fatal(1, "STATUS full/stall coverage");
        return_enable = 1; flush();
        if (tail != 74 || dut.sched_u.err_q !== 0) $fatal(1, "control final checks");
        control(int'(TEST_ID),1,12'h00c,32'h00040000);
        repeat (3) tick();
        force dut.sched_u.quant_ov = 1'b1;
        force dut.sched_u.quant_err = 1'b1;
        tick();
        if (dut.sched_u.err_q !== 22'h040000) $fatal(1, "numeric event missing");
        force dut.sched_u.quant_ov = 1'b0;
        control(int'(TEST_ID),1,12'h008,32'h00040000);
        repeat (4) tick();
        if (dut.sched_u.err_q !== 0) $fatal(1, "held quant error defeats W1C");
        force dut.sched_u.quant_ov = 1'b1;
        tick();
        if (dut.sched_u.err_q !== 22'h040000) $fatal(1, "new numeric event not rearmed");
        force dut.sched_u.quant_ov = 1'b0;
        force dut.sched_u.quant_err = 1'b0;
        control(int'(TEST_ID),1,12'h008,32'h00040000);
        repeat (4) tick();
        release dut.sched_u.quant_ov;
        release dut.sched_u.quant_err;
        if (dut.sched_u.err_q !== 0) $fatal(1, "numeric final clear failed");
        $display("PASS control replies=%0d stall_cycles=%0d numeric_w1c=1",tail,stalls);
        $finish;
    end
endmodule
