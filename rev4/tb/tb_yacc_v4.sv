`timescale 1ns/1ps
module tb_yacc_v4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
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
        case (lane)
            0: return 16'h4040;
            1: return 16'h4080;
            2: return 16'h40a0;
            default: return 16'h40c0;
        endcase
    endfunction
    task automatic tick;
        @(posedge clk); #1; cycles++;
        if (cycles > 1000000) $fatal(1, "yacc global watchdog");
        if (drain_illegal || v0_drain) $fatal(1, "unexpected DRAIN error");
        @(negedge clk);
    endtask
    task automatic drain_one(input integer bank, slot_id, lane);
        integer received, waited;
        bit fire;
        logic [127:0] payload;
        logic last;
        logic [7:0] tag;
        drain_bank = 1'(bank); drain_slot = 6'(slot_id); drain_valid = 1;
        tick(); drain_valid = 0; received = 0; waited = 0;
        while (received < 10) begin
            yb_ready = waited % 11 >= 5;
            #1;
            fire = yb_valid && yb_ready;
            payload = yb_payload; last = yb_last; tag = yb_tag;
            if (fire) begin
                for (integer element = 0; element < 8; element++)
                    if (payload[16*element +: 16] !== expected_value(lane,received*8+element))
                        $fatal(1, "Y data bank=%0d slot=%0d column=%0d",bank,slot_id,received*8+element);
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
    initial begin
        for (integer lane = 0; lane < 4; lane++) begin
            commit_slots[lane] = 0; commit_weights[lane] = 32'h3f800000;
        end
        for (integer column = 76; column < 80; column++)
            commit_db[16*column +: 16] = 16'h4000;
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
                        integer waited = 0;
                        while (commit_busy !== 0) begin
                            tick(); waited++;
                            if (waited > 10000) $fatal(1, "Y commit timeout");
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
        $display("PASS yacc packets=%0d cycles=%0d",packets,cycles);
        $finish;
    end
endmodule
