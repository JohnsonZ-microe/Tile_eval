`timescale 1ns/1ps
module tb_yacc_v4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    // optional VCD (run.py --waves passes +VCD=<path>)
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_yacc_v4);
        end
    end
    logic load_valid = 0;
    logic [6:0] load_base = 0;
    logic [7:0] load_cen = 0;
    logic [1023:0] load_data = 0;
    logic commit_trigger = 0, commit_bank = 0, commit_bias_en = 1;
    logic [1279:0] commit_db = 0;
    logic [3:0] commit_mask = 0;
    logic [5:0] commit_slots[0:3];
    logic [31:0] commit_weights[0:3];
    logic commit_busy, commit_rd_active, commit_bank_id, drain_yield;
    logic drain_valid = 0, drain_bank = 0;
    logic [5:0] drain_slot = 0;
    logic [7:0] drain_col_start = 0, drain_count = 80;
    logic [1:0] drain_segment = 0;
    logic drain_last_seg = 1;
    logic drain_illegal, v0_drain, yb_valid, yb_ready = 0, yb_last;
    logic [127:0] yb_payload;
    logic [1:0] yb_segment;
    logic [7:0] yb_tag;
    integer cycles = 0, packets = 0;
    pe4_yacc dut(.*);
    logic [9:0] read_identity_addr [0:1];
    logic [9:0] read_identity_output [0:1];
    bit read_identity_known [0:1];
    bit read_identity_output_known [0:1];
    integer read_identity_checks = 0;
    always @(posedge clk) begin : read_identity_monitor
        if (!rst_n) begin
            read_identity_checks <= 0;
            for (integer bank = 0; bank < 2; bank++) begin
                read_identity_addr[bank] <= 0;
                read_identity_output[bank] <= 0;
                read_identity_known[bank] <= 0;
                read_identity_output_known[bank] <= 0;
            end
        end else begin
            if (dut.re0 === 1'b1) begin
                read_identity_addr[0] <= dut.raddr0;
                read_identity_known[0] <= 1;
            end
            if (dut.re1 === 1'b1) begin
                read_identity_addr[1] <= dut.raddr1;
                read_identity_known[1] <= 1;
            end
            for (integer bank = 0; bank < 2; bank++) begin
                read_identity_output[bank] <= read_identity_addr[bank];
                read_identity_output_known[bank] <= read_identity_known[bank];
            end
            if (dut.dstate == 2'd1 && dut.dwait_cnt == 3'd4 && !drain_yield) begin
                if (read_identity_output_known[dut.dbank] !== 1'b1 ||
                    read_identity_output[dut.dbank] !== 10'(10*int'(dut.dslot)+int'(dut.drow)))
                    $fatal(1, "Y read identity bank=%0d slot=%0d row=%0d actual_addr=%0d expected_addr=%0d cycle=%0d", dut.dbank,dut.dslot,dut.drow,read_identity_output[dut.dbank],10*int'(dut.dslot)+int'(dut.drow),cycles);
                read_identity_checks <= read_identity_checks + 1;
            end
        end
    end
    function automatic logic [31:0] input_value(input integer lane);
        case (lane)
            0: return 32'h3f800000;
            1: return 32'h40000000;
            2: return 32'h40400000;
            default: return 32'h40800000;
        endcase
    endfunction
    function automatic logic [15:0] expected_value(input integer lane, column);
        if (column < 76) return input_value(lane) >> 16;
        case (lane + column - 73)
            3: return 16'h4040;
            4: return 16'h4080;
            5: return 16'h40a0;
            6: return 16'h40c0;
            7: return 16'h40e0;
            8: return 16'h4100;
            default: return 16'h4110;
        endcase
    endfunction
    task automatic tick;
        @(posedge clk); #1; cycles++;
        if (cycles > 1000000) $fatal(1, "yacc global watchdog");
        if (drain_illegal || v0_drain) $fatal(1, "unexpected DRAIN error");
        @(negedge clk);
    endtask
    task automatic drain_one(input integer bank, slot_id, lane,
                             input bit concurrent_commit = 0,
                             input integer commit_lead = 0);
        integer received, waited;
        bit fire;
        logic [127:0] payload;
        logic last;
        logic [7:0] tag;
        if (concurrent_commit && commit_lead > 0) begin
            commit_trigger = 1; tick(); commit_trigger = 0;
            repeat (commit_lead - 1) tick();
        end
        drain_bank = 1'(bank); drain_slot = 6'(slot_id); drain_valid = 1;
        commit_trigger = concurrent_commit && commit_lead == 0;
        tick(); commit_trigger = 0; drain_valid = 0; received = 0; waited = 0;
        while (received < 10) begin
            yb_ready = concurrent_commit || waited % 11 >= 5;
            #1;
            fire = yb_valid && yb_ready;
            payload = yb_payload; last = yb_last; tag = yb_tag;
            if (fire) begin
                for (integer element = 0; element < 8; element++)
                    if (payload[16*element +: 16] !== expected_value(lane,received*8+element))
                        $fatal(1, "Y data bank=%0d slot=%0d column=%0d commit_lead=%0d got=%h expected=%h",bank,slot_id,received*8+element,commit_lead,payload[16*element +: 16],expected_value(lane,received*8+element));
                if (last !== (received == 9) || tag !== {1'(bank),6'(slot_id),1'b0} ||
                    yb_segment !== drain_segment) $fatal(1, "Y metadata");
                received++;
            end
            tick(); waited++;
            if (waited > 10000) $fatal(1, "Y missing packet");
        end
        yb_ready = 0;
        repeat (3) tick();
        if (dut.vbit[bank][slot_id] !== 0) $fatal(1, "last segment did not release slot");
        packets++;
    endtask
    task automatic wait_commit_idle;
        integer waited;
        waited = 0;
        while (commit_busy !== 0) begin
            tick(); waited++;
            if (waited > 10000) $fatal(1, "overlap commit timeout");
        end
        repeat (3) tick();
    endtask
    integer overlap_yields = 0;
    bit overlap_probe = 0;
    always @(posedge clk)
        if (rst_n && overlap_probe && drain_yield === 1'b1)
            overlap_yields = overlap_yields + 1;
    task automatic check_same_bank_overlap;
        integer yields_before;
        for (integer bank = 0; bank < 2; bank++) begin
            yields_before = overlap_yields;
            for (integer lead = 0; lead < 22; lead++) begin
            commit_bank = 1'(bank);
            commit_mask = 4'b0001;
            commit_slots[0] = 6'd0;
            commit_trigger = 1; tick(); commit_trigger = 0;
            wait_commit_idle();
            if (dut.vbit[bank][0] !== 1) $fatal(1, "overlap source slot not ready");
            commit_mask = 4'b0010;
            commit_slots[1] = 6'd1;
            $display("PROBE yacc_overlap bank=%0d commit_lead=%0d", bank, lead);
            $fflush();
            overlap_probe = 1;
            drain_one(bank, 0, 0, 1, lead);
            overlap_probe = 0;
            wait_commit_idle();
            if (dut.vbit[bank][1] !== 1) $fatal(1, "concurrent commit lost destination");
            drain_one(bank, 1, 1);
            end
            if (overlap_yields <= yields_before)
                $fatal(1, "same-bank yield not exercised bank=%0d", bank);
        end
        if (overlap_yields == 0) $fatal(1, "same-bank overlap did not exercise yield");
        $display("CHECK yacc_overlap banks=2 offsets=44 packets=88 yields=%0d", overlap_yields);
    endtask
    initial begin
        for (integer lane = 0; lane < 4; lane++) begin
            commit_slots[lane] = 0; commit_weights[lane] = 32'h3f800000;
        end
        commit_db[16*76 +: 16] = 16'h4000;
        commit_db[16*77 +: 16] = 16'h4040;
        commit_db[16*78 +: 16] = 16'h4080;
        commit_db[16*79 +: 16] = 16'h40a0;
        @(negedge clk);
        repeat (3) tick();
        rst_n = 1;
        for (integer bank = 0; bank < 2; bank++) begin
            for (integer group_id = 0; group_id < 16; group_id++) begin
                for (integer part = 0; part < 2; part++) begin
                    for (integer column = 0; column < 80; column += 8) begin
                        load_valid = 1; load_base = 7'(column); load_cen = 8'hff;
                        for (integer offset = 0; offset < 8; offset++)
                            for (integer lane = 0; lane < 4; lane++)
                                load_data[(offset*4+lane)*32 +: 32] = input_value(lane);
                        tick();
                    end
                    load_valid = 0; commit_bank = 1'(bank);
                    commit_mask = part == 0 ? 4'b1010 : 4'b0101;
                    for (integer lane = 0; lane < 4; lane++)
                        commit_slots[lane] = 6'(group_id*4+lane);
                    commit_trigger = 1; tick(); commit_trigger = 0;
                    begin
                        integer waited;
                        waited = 0;
                        while (commit_busy !== 0) begin
                            tick(); waited++;
                            if (waited > 10000)
                                $fatal(1, "Y commit timeout bank=%0d group=%0d part=%0d waited=%0d cycles=%0d state=%0d lane=%0d row=%0d mask=%b addb_vo=%h add_vo=%h",
                                    bank, group_id, part, waited, cycles, dut.cstate,
                                    dut.lane_sel, dut.row_sel, dut.cmask_left,
                                    dut.addb_vo, dut.add_vo);
                        end
                    end
                    repeat (3) tick();
                    for (integer lane = 0; lane < 4; lane++) begin
                        if (commit_mask[lane]) begin
                            if (dut.vbit[bank][group_id*4+lane] !== 1)
                                $fatal(1, "Y slot not published");
                            drain_one(bank,group_id*4+lane,lane);
                        end
                    end
                end
            end
        end
        if (packets != 128) $fatal(1, "Y slot coverage");
        check_same_bank_overlap();
        if (packets != 216) $fatal(1, "Y overlap packet coverage");
        if (read_identity_checks != 2160) $fatal(1, "Y read identity coverage");
        $display("CHECK yacc_read_identity rows=%0d", read_identity_checks);
        $display("PASS yacc packets=%0d cycles=%0d",packets,cycles);
        $finish;
    end
endmodule
