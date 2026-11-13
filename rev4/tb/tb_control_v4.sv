`timescale 1ns/1ps
module tb_control_v4;
    parameter logic [5:0] TEST_ID = 6'd16;
    localparam logic [31:0] EXPECTED_ID = 32'h80000300 | {26'b0, TEST_ID};
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    // optional VCD (run.py --waves passes +VCD=<path>)
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_control_v4);
        end
    end
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
    integer context_cases = 0, rejected_commands = 0;
    integer context_busy_cases = 0;
    integer unaligned_cases = 0;
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
    task automatic check_context_formats;
        integer scale_format;
        control(int'(TEST_ID),1,12'h00c,32'h003fffff);
        control(int'(TEST_ID),1,12'h100,32'(5120 | (160 << 16)));
        control(int'(TEST_ID),1,12'h104,32'(36 | (2304 << 16)));
        control(int'(TEST_ID),1,12'h10c,1);
        control(int'(TEST_ID),1,12'h140,0);
        for (integer index = 0; index < 8; index++)
            control(int'(TEST_ID),1,12'h120+4*index,pe4_pkg::V41_ACT[index]);
        for (integer format_id = 0; format_id < 8; format_id++) begin
            scale_format = format_id == 5 ? 3 : format_id == 2 ? 2 :
                           (format_id == 3 || format_id == 4) ? 1 : 0;
            control(int'(TEST_ID),1,12'h108,format_id | (scale_format << 3) |
                    ((format_id == 2 || format_id == 3) ? 32 : 0));
            tick();
            if (dut.sched_u.cp[0].legal !== (format_id < 6))
                $fatal(1, "CTX format validity format=%0d", format_id);
            context_cases++;
            if (format_id >= 6) begin
                dn_valid = 1; dn_sideband = 0;
                dn_payload = (512'd3 << 20) | (512'd1 << 43);
                tick(); dn_valid = 0;
                repeat (5) begin
                    if (dut.sched_u.slot[0].valid !== 0 || dut.sched_u.slot[1].valid !== 0 ||
                        dut.rram_req !== 0 || dut.pe_in_valid !== 0)
                        $fatal(1, "reserved format started work");
                    tick();
                end
                if (dut.sched_u.err_q !== 22'h000004)
                    $fatal(1, "reserved format CMD_ILLEGAL missing");
                control(int'(TEST_ID),1,12'h008,4);
                repeat (3) tick();
                if (dut.sched_u.err_q !== 0) $fatal(1, "reserved format W1C failed");
                rejected_commands++;
            end
        end
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
    task automatic check_context_busy;
        integer address;
        control(int'(TEST_ID),1,12'h108,0);
        control(int'(TEST_ID),1,12'h180,32'h12345678);
        control(int'(TEST_ID),1,12'h1c0,0);
        repeat (3) tick();
        dn_valid = 1; dn_sideband = 0;
        dn_payload = (512'd3 << 20) | (512'd1 << 43);
        tick(); dn_valid = 0;
        repeat (3) tick();
        if (dut.sched_u.slot[0].valid !== 1'b1 || dut.rram_req !== 0)
            $fatal(1, "CTX busy probe failed to establish waiting CMD");
        for (integer index = 0; index < 4; index++) begin
            case (index)
                0: address = 12'h100;
                1: address = 12'h140;
                2: address = 12'h180;
                default: address = 12'h1c0;
            endcase
            control(int'(TEST_ID),1,address,32'hffffffff);
            repeat (4) tick();
            if (dut.sched_u.ctx_word[0][0] !== 32'(5120 | (160 << 16)) ||
                dut.sched_u.ctx_word[1][0] !== 32'h12345678 ||
                dut.sched_u.ctx_mode[0] !== 0 || dut.sched_u.ctx_mode[1] !== 0)
                $fatal(1, "busy CTX write modified storage");
            if (dut.sched_u.err_q !== 22'h008000 || dut.rram_req !== 0 ||
                dut.sched_u.slot[0].valid !== 1'b1)
                $fatal(1, "CTX_BUSY missing or active CMD disturbed");
            control(int'(TEST_ID),1,12'h008,32'h00008000);
            repeat (4) tick();
            if (dut.sched_u.err_q !== 0) $fatal(1, "CTX_BUSY W1C failed");
            context_busy_cases++;
        end
        rst_n = 0;
        @(posedge clk); #1;
        if (dut.sched_u.slot[0].valid !== 0 || dut.sched_u.slot[1].valid !== 0)
            $fatal(1, "CTX busy probe reset did not cancel CMD");
        @(negedge clk);
    endtask
    task automatic check_unaligned_context;
        control(int'(TEST_ID),1,12'h180,32'h12345678);
        repeat (3) tick();
        for (integer bank = 0; bank < 2; bank++) begin
            for (integer offset = 1; offset < 4; offset++) begin
                control(int'(TEST_ID),1,12'h100+bank*128+offset,32'hffffffff);
                repeat (4) tick();
                if (dut.sched_u.ctx_word[0][0] !== 32'(5120 | (160 << 16)) ||
                    dut.sched_u.ctx_word[1][0] !== 32'h12345678)
                    $fatal(1, "unaligned CTX write aliased a word");
                if (dut.sched_u.err_q !== 22'h010000)
                    $fatal(1, "unaligned CTX write REG_ADDR missing");
                control(int'(TEST_ID),1,12'h008,32'h00010000);
                repeat (4) tick();
                if (dut.sched_u.err_q !== 0) $fatal(1, "REG_ADDR W1C failed");
                unaligned_cases++;
            end
        end
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
        // quant_ov both gates the NUMERIC event (sched:1023) and drives
        // hbuf_wr_valid (sched:972): forcing it pulses writes into an
        // unowned h bank every cycle, latching H_ORDER (bit 5) -- unmasked,
        // so an ALARM STATUS fires that the 74-entry expectation queue
        // never counted (seen as payload ...00040020 = NUMERIC|H_ORDER).
        // Suppress only the observable error pulse; the gated write inside
        // pe4_hbuf never commits anyway.
        force dut.hbuf_u.wr_err = 1'b0;
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
        release dut.hbuf_u.wr_err;
        if (dut.sched_u.err_q !== 0) $fatal(1, "numeric final clear failed");
        check_context_formats();
        flush();
        if (context_cases != 8 || rejected_commands != 2) $fatal(1, "CTX format coverage");
        check_unaligned_context();
        if (unaligned_cases != 6) $fatal(1, "unaligned CTX coverage");
        check_context_busy();
        if (context_busy_cases != 4) $fatal(1, "CTX busy coverage");
        $display("PASS control replies=%0d stall_cycles=%0d numeric_w1c=1 context_cases=%0d rejected_commands=%0d context_busy_cases=%0d unaligned_cases=%0d",
                 tail,stalls,context_cases,rejected_commands,context_busy_cases,unaligned_cases);
        $finish;
    end
endmodule
