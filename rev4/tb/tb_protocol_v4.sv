`timescale 1ns/1ps
module tb_protocol_v4;
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_protocol_v4);
        end
    end
    logic  clk = '0;
    logic  rst_n = '0;
    logic  dn_valid = '0;
    logic [511:0] dn_payload = '0;
    logic [31:0] dn_sideband = '0;
    logic  cmd_valid;
    logic [511:0] cmd_payload;
    logic [7:0] cmd_pass;
    logic  xfifo_push;
    logic  xfifo_kind;
    logic  xfifo_ovf;
    logic [2:0] xfifo_in_lane;
    logic [9:0] xfifo_in_idx;
    logic [511:0] xfifo_in_data;
    logic  h_valid;
    logic [2:0] h_lane;
    logic [9:0] h_idx;
    logic [7:0] h_pass;
    logic [511:0] h_data;
    logic  ctrl_valid;
    logic [3:0] ctrl_op;
    logic [6:0] ctrl_target;
    logic [11:0] ctrl_addr;
    logic [31:0] ctrl_data;
    logic [7:0] ctrl_tag;
    logic  dn_reserved;
    logic  xfifo_pop = '0;
    logic  xfifo_out_kind;
    logic [2:0] xfifo_out_lane;
    logic [9:0] xfifo_out_idx;
    logic [511:0] xfifo_out_data;
    logic [7:0] xfifo_out_pass;
    logic  xfifo_empty;
    logic [7:0] xfifo_level;
    logic  sync0;
    logic [1:0] up_credit = '0;
    logic  up_valid;
    logic [127:0] up_payload;
    logic [23:0] up_sideband;
    logic  up_credit_err;
    logic  credit_stall;
    logic  hup_valid = '0;
    logic  hup_ready;
    logic [127:0] hup_payload = '0;
    logic  hup_last = '0;
    logic [7:0] hup_src = '0;
    logic [7:0] hup_tag = '0;
    logic  ysrc_valid = '0;
    logic  ysrc_ready;
    logic [127:0] ysrc_payload = '0;
    logic  ysrc_last = '0;
    logic [1:0] ysrc_segment = '0;
    logic [7:0] ysrc_tag = '0;
    logic [7:0] ysrc_src = '0;
    logic  st_valid = '0;
    logic  st_ready;
    logic [127:0] st_payload = '0;
    logic [7:0] st_tag = '0;
    logic [7:0] st_src = '0;
    always #5 clk = ~clk;
    pe4_bus #(.TILE_ID(7'd16)) dut(
        .clk(clk),
        .rst_n(rst_n),
        .dn_valid(dn_valid),
        .dn_payload(dn_payload),
        .dn_sideband(dn_sideband),
        .cmd_valid(cmd_valid),
        .cmd_payload(cmd_payload),
        .cmd_pass(cmd_pass),
        .xfifo_push(xfifo_push),
        .xfifo_kind(xfifo_kind),
        .xfifo_ovf(xfifo_ovf),
        .xfifo_in_lane(xfifo_in_lane),
        .xfifo_in_idx(xfifo_in_idx),
        .xfifo_in_data(xfifo_in_data),
        .h_valid(h_valid),
        .h_lane(h_lane),
        .h_idx(h_idx),
        .h_pass(h_pass),
        .h_data(h_data),
        .ctrl_valid(ctrl_valid),
        .ctrl_op(ctrl_op),
        .ctrl_target(ctrl_target),
        .ctrl_addr(ctrl_addr),
        .ctrl_data(ctrl_data),
        .ctrl_tag(ctrl_tag),
        .dn_reserved(dn_reserved),
        .xfifo_pop(xfifo_pop),
        .xfifo_out_kind(xfifo_out_kind),
        .xfifo_out_lane(xfifo_out_lane),
        .xfifo_out_idx(xfifo_out_idx),
        .xfifo_out_data(xfifo_out_data),
        .xfifo_out_pass(xfifo_out_pass),
        .xfifo_empty(xfifo_empty),
        .xfifo_level(xfifo_level),
        .sync0(sync0),
        .up_credit(up_credit),
        .up_valid(up_valid),
        .up_payload(up_payload),
        .up_sideband(up_sideband),
        .up_credit_err(up_credit_err),
        .credit_stall(credit_stall),
        .hup_valid(hup_valid),
        .hup_ready(hup_ready),
        .hup_payload(hup_payload),
        .hup_last(hup_last),
        .hup_src(hup_src),
        .hup_tag(hup_tag),
        .ysrc_valid(ysrc_valid),
        .ysrc_ready(ysrc_ready),
        .ysrc_payload(ysrc_payload),
        .ysrc_last(ysrc_last),
        .ysrc_segment(ysrc_segment),
        .ysrc_tag(ysrc_tag),
        .ysrc_src(ysrc_src),
        .st_valid(st_valid),
        .st_ready(st_ready),
        .st_payload(st_payload),
        .st_tag(st_tag),
        .st_src(st_src));

    logic [533:0] fifo_expected[0:4095];
    integer head = 0, tail = 0, count = 0, credits = 6, locked = 0;
    integer cycles = 0, up_checked = 0, fifo_checked = 0;
    integer hseq = 0, yseq = 0, sseq = 0;
    integer credit_cases = 0;
    bit take_h, take_y, take_s;
    task automatic tick;
        integer selected;
        bit write_ok, read_ok, sent, overflow, credit_error;
        logic [127:0] payload;
        logic [23:0] sideband;
        #1;
        write_ok = dn_valid && (dn_sideband[2:0] == 1 ||
                   dn_sideband[2:0] == 2) && count < 128;
        read_ok = xfifo_pop && count > 0;
        overflow = dn_valid && (dn_sideband[2:0] == 1 ||
                   dn_sideband[2:0] == 2) && count == 128;
        if (read_ok) begin
            if ({xfifo_out_pass, xfifo_out_lane, xfifo_out_idx,
                 xfifo_out_kind, xfifo_out_data} !== fifo_expected[tail])
                $fatal(1, "FIFO order/metadata cycle=%0d", cycles);
            tail++; fifo_checked++;
        end
        if (write_ok) begin
            fifo_expected[head] = {dn_sideband[10:3], dn_sideband[13:11],
                dn_sideband[23:14], dn_sideband[2:0] == 2, dn_payload};
            head++;
        end
        selected = locked != 0 ? locked : (hup_valid ? 1 :
                   (ysrc_valid ? 2 : (st_valid ? 3 : 0)));
        sent = credits > 0 && ((selected == 1 && hup_valid) ||
               (selected == 2 && ysrc_valid) || (selected == 3 && st_valid));
        take_h = sent && selected == 1;
        take_y = sent && selected == 2;
        take_s = sent && selected == 3;
        if ({hup_ready, ysrc_ready, st_ready} !== {take_h, take_y, take_s})
            $fatal(1, "arbitration/credit readiness");
        if (credit_stall !== (credits == 0 && ((selected == 1 && hup_valid) ||
            (selected == 2 && ysrc_valid) || (selected == 3 && st_valid))))
            $fatal(1, "credit stall event");
        if (ctrl_valid !== (dn_valid && dn_sideband[2:0] == 4 &&
            (dn_payload[10:4] == 16 || dn_payload[10:4] == 127)))
            $fatal(1, "CTRL target filter");
        case (selected)
            1: begin
                payload = hup_payload;
                sideband = {4'd0, 2'd0, hup_last, hup_tag, hup_src[6:0], 2'd0};
                if (sent) locked = hup_last ? 0 : 1;
            end
            2: begin
                payload = ysrc_payload;
                sideband = {2'd0, ysrc_segment, 2'd0, ysrc_last,
                            ysrc_tag, ysrc_src[6:0], 2'd1};
                if (sent) locked = ysrc_last ? 0 : 2;
            end
            default: begin
                payload = st_payload;
                sideband = {4'd0, 2'd0, 1'b1, st_tag, st_src[6:0], 2'd2};
                if (sent) locked = 0;
            end
        endcase
        credit_error = credits + int'(up_credit) > 6;
        if (!credit_error) credits += int'(up_credit);
        if (sent) credits--;
        count += int'(write_ok) - int'(read_ok);
        @(posedge clk); #1;
        if (xfifo_level !== 8'(count) || sync0 !== read_ok || xfifo_ovf !== overflow)
            $fatal(1, "FIFO count/credit/overflow cycle=%0d", cycles);
        if (up_valid !== sent || up_credit_err !== credit_error)
            $fatal(1, "up valid/credit error cycle=%0d", cycles);
        if (dut.credit !== 3'(credits) || dut.credit > 6)
            $fatal(1, "credit counter recovery cycle=%0d got=%0d expected=%0d",
                   cycles, dut.credit, credits);
        if (sent) begin
            if (up_payload !== payload || up_sideband !== sideband)
                $fatal(1, "up data/metadata cycle=%0d", cycles);
            up_checked++;
        end
        hseq += int'(take_h); yseq += int'(take_y); sseq += int'(take_s);
        cycles++;
        @(negedge clk);
    endtask

    task automatic check_credit_case(input integer initial_credit,
                                     input integer returned,
                                     input bit request_beat);
        rst_n = 0;
        dn_valid = 0; xfifo_pop = 0; up_credit = 0;
        hup_valid = 0; ysrc_valid = 0; st_valid = 0;
        @(posedge clk); #1;
        if (dut.credit !== 3'd6 || up_credit_err !== 0 || up_valid !== 0)
            $fatal(1, "credit case reset");
        @(negedge clk);
        rst_n = 1; credits = 6; locked = 0; count = 0;
        hup_valid = 1; hup_last = 1;
        hup_payload = 128'h1234; hup_tag = 8'h5a; hup_src = 8'd16;
        repeat (6-initial_credit) tick();
        hup_valid = request_beat; up_credit = 2'(returned);
        tick();
        up_credit = 0; hup_valid = 0;
        tick();
        if (up_credit_err !== 0) $fatal(1, "credit error pulse did not clear");
        credit_cases++;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        for (integer index = 0; index < 128; index++) begin
            dn_valid = 1; dn_sideband = 32'(1 | (index << 3) |
                ((index % 4) << 11) | (index << 14));
            dn_payload = 512'(index);
            tick();
        end
        xfifo_pop = 1;
        tick();
        for (integer index = 0; index < 600; index++) begin
            dn_sideband = 32'(2 | ((index % 256) << 3) |
                ((index % 4) << 11) | ((index % 1024) << 14));
            dn_payload = 512'(index + 1000);
            tick();
        end
        dn_valid = 0;
        repeat (130) tick();
        xfifo_pop = 0;
        for (integer target = 0; target < 128; target++) begin
            dn_valid = 1; dn_sideband = 4;
            dn_payload = 512'(target << 4);
            tick();
        end
        dn_valid = 0;
        for (integer index = 0; index < 900; index++) begin
            if (!hup_valid || take_h)
                hup_valid = (index < 300 || hseq % 5 != 0) && index % 4 != 0;
            if (!ysrc_valid || take_y)
                ysrc_valid = (index < 600 || yseq % 3 != 0) && index % 3 != 0;
            if (!st_valid || take_s) st_valid = index % 5 != 0;
            hup_payload = 128'(hseq); hup_tag = 8'(hseq/5);
            hup_src = 8'(hseq % 128); hup_last = hseq % 5 == 4;
            ysrc_payload = 128'(10000+yseq); ysrc_tag = 8'(yseq/3);
            ysrc_src = 8'(yseq % 128); ysrc_last = yseq % 3 == 2;
            ysrc_segment = 2'(yseq % 4);
            st_payload = 128'(20000+sseq); st_tag = 8'(sseq); st_src = 8'(sseq % 128);
            up_credit = (index % 60 >= 30 && credits < 6) ? 1 : 0;
            tick();
        end
        if (fifo_checked < 700 || up_checked < 100 || yseq == 0 || sseq == 0)
            $fatal(1, "protocol coverage did not exercise all paths");
        for (integer initial_credit = 0; initial_credit <= 6; initial_credit++)
            for (integer returned = 0; returned <= 2; returned++)
                for (integer request_beat = 0; request_beat <= 1; request_beat++)
                    check_credit_case(initial_credit, returned, 1'(request_beat));
        if (credit_cases != 42) $fatal(1, "credit case coverage");
        @(negedge clk); rst_n = 0;
        @(posedge clk); #1;
        if (xfifo_level !== 0 || up_valid !== 0 || dut.active_valid !== 0)
            $fatal(1, "reset failed to flush protocol state");
        $display("PASS protocol fifo=%0d up=%0d h=%0d y=%0d status=%0d credit_cases=%0d",
                 fifo_checked, up_checked, hseq, yseq, sseq, credit_cases);
        $finish;
    end
endmodule
