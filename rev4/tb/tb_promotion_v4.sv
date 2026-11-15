// White-box transition test: inject an isolated scheduler boundary.
// Does not prove external-interface reachability or full Tile numerical results.
`timescale 1ns/1ps
module tb_promotion_v4;
    import pe4_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    tile_ffn_v4 #(.RRAM_WORDS(4096)) dut (
        .clk(clk), .rst_n(rst_n), .dn_valid(1'b0), .dn_payload(512'd0),
        .dn_sideband(32'd0), .up_credit(2'd0),
        .up_valid(), .up_payload(), .up_sideband(), .sync0(), .sync1(), .err_line(),
        .sim_load(1'b0), .sim_addr(21'd0), .sim_data(1024'd0));
    cmd_t old_head, successor;
    logic [1:0] bias_index_q, bias_left_q;
    integer checked = 0, stalled = 0, issued = 0, scales = 0;
    logic [31:0] counter_seed;
    integer counter_cases = 0, collision_cases = 0;
    integer quant_guard_cases = 0;
    logic guard_valid, guard_bank, guard_release, guard_release_bank;
    logic [1:0] route_owners;
    integer route_guard_cases = 0;
    logic [511:0] collision_payload;
    string vcdfile;
    initial if ($value$plusargs("VCD=%s", vcdfile)) begin
        $dumpfile(vcdfile); $dumpvars(0, tb_promotion_v4);
    end
    initial begin
        #10000;
        $fatal(1, "PROMOTION watchdog");
    end
    task automatic check_transition(input bit d_commit, input integer bias_index, input integer scenario);
        logic [20:0] expected_address;
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        old_head = '0; old_head.valid = 1; old_head.pass_id = 5;
        old_head.phase = d_commit ? 1 : 0;
        successor = '0; successor.valid = 1; successor.phase = 1;
        successor.pass_id = 9; successor.bias_en = 1;
        successor.n_tok = 1; successor.lane_mask = 1;
        bias_index_q = 2'(bias_index);
        bias_left_q = (scenario == 1 && bias_index < 2) ? 2'd2 : 2'd1;
        // All force RHS variables are module-static. Release before the edge
        // under test; the scheduler's own NBA assignments perform promotion.
        force dut.sched_u.slot = '{old_head, successor};
        force dut.sched_u.iss = '{'0, '{valid:1'b1, bias:1'b1,
            bidx:bias_index_q, bleft:bias_left_q, default:'0}};
        force dut.sched_u.cp = '{'{nkb:17'd160, ngroups:6'd9,
            ncols:4'd8, sw:4'd1, period:3'd1, legal:1'b1, default:'0},
            '{nkb:17'd160, ngroups:6'd9, ncols:4'd8, sw:4'd1,
              period:3'd1, legal:1'b1, default:'0}};
        force dut.sched_u.wsh = '{'{default:32'hdeadbeef}, '{default:32'h12345678}};
        force dut.sched_u.phase_base = '{21'h20, 21'h600};
        force dut.sched_u.tail_base = '{21'h100, 21'h800};
        force dut.sched_u.hup_beat = 0;
        force dut.sched_u.hup_beats = 1;
        if (d_commit) force dut.sched_u.pstate = dut.sched_u.P_DCOMMIT;
        else force dut.sched_u.pstate = dut.sched_u.P_HUP;
        force dut.rram_ready = 1'b0;
        force dut.hup_ready = 1'b0;
        force dut.yacc_busy = 1'b1;
        #1;
        release dut.sched_u.slot;
        release dut.sched_u.iss;
        release dut.sched_u.wsh;
        release dut.sched_u.phase_base;
        release dut.sched_u.tail_base;
        release dut.sched_u.hup_beat; release dut.sched_u.hup_beats;
        release dut.sched_u.pstate;
        @(posedge clk); #1;
        if (dut.sched_u.slot[0].pass_id !== 8'd5 ||
            dut.sched_u.tail_base[0] !== 21'h100 || dut.sync1 !== 1'b0)
            $fatal(1, "PROMOTION retired while blocked path=%0d", d_commit);
        if (dut.sched_u.cnt[0] !== 32'd0 || dut.sched_u.cnt[1] !== 32'd0)
            $fatal(1, "PROMOTION counter advanced while blocked");
        stalled++;
        @(negedge clk);
        if (scenario == 1) force dut.rram_ready = 1'b1;
        if (scenario == 2) begin
            // The first queued scale is consumed ON the retirement edge. A
            // second pending return verifies retagging of an older RQ entry.
            force dut.sched_u.rq = '{
                '{slot:1'b1, full:1'b1, scale:1'b1, phase:1'b1,
                  ncols:4'd8, ngroups:6'd10, nkb:8'd72,
                  data:{128{8'h5a}}, default:'0},
                '{slot:1'b1, bias:1'b1, phase:1'b1, default:'0}, '0, '0};
            force dut.sched_u.rq_cnt = 3'd2;
            #1; release dut.sched_u.rq; release dut.sched_u.rq_cnt;
        end
        force dut.hup_ready = 1'b1;
        force dut.yacc_busy = 1'b0;
        @(posedge clk); #1;
        if (dut.sched_u.slot[0] !== successor || dut.sched_u.slot[1].valid !== 1'b0 ||
            dut.sched_u.phase_base[0] !== 21'h600 ||
            dut.sched_u.tail_base[0] !== 21'h800 || dut.sync1 !== 1'b1)
            $fatal(1, "PROMOTION state mismatch path=%0d index=%0d", d_commit, bias_index);
        if (dut.sched_u.cnt[0] !== (d_commit ? 32'd0 : 32'd1) ||
            dut.sched_u.cnt[1] !== (d_commit ? 32'd1 : 32'd0))
            $fatal(1, "PROMOTION retirement counter lost or misclassified");
        if (dut.sched_u.iss[1].valid !== 1'b0)
            $fatal(1, "PROMOTION stale successor issuer");
        for (integer i = 0; i < 80; i++)
            if (dut.sched_u.wsh[0][i] !== (scenario == 2 ? 32'h5a : 32'h12345678))
                $fatal(1, "PROMOTION scale ownership mismatch index=%0d", i);
        if (scenario == 1) begin
            if (dut.sched_u.rq_cnt !== 3'd1 || dut.sched_u.rq[0].slot !== 1'b0 ||
                dut.sched_u.rq[0].bidx !== bias_index_q ||
                dut.sched_u.iss[0].started !== 1'b1)
                $fatal(1, "PROMOTION simultaneous issue lost or mistagged");
            if (bias_index < 2) begin
                if (dut.sched_u.iss[0].bidx !== bias_index_q + 2'd1 ||
                    dut.sched_u.iss[0].bleft !== 2'd1 || dut.sched_u.iss[0].bias !== 1'b1)
                    $fatal(1, "PROMOTION bias issue replayed");
            end else if (dut.sched_u.iss[0].bias !== 1'b0 || dut.sched_u.iss[0].scale !== 1'b1)
                $fatal(1, "PROMOTION final bias replayed");
            issued++;
        end
        if (scenario == 2) begin
            if (dut.sched_u.rq_cnt !== 3'd1 || dut.sched_u.rq_cons !== 2'd1 ||
                dut.sched_u.rq[1].slot !== 1'b0)
                $fatal(1, "PROMOTION outstanding queue lost or mistagged");
            scales++;
        end
        force dut.rram_ready = 1'b1;
        force dut.sched_u.hbuf_bank_ready = 2'b11;
        #1;
        expected_address = (scenario == 1 && bias_index == 2) ? 21'h600 :
            (21'h800 + 21'(bias_index) + (scenario == 1 ? 21'd1 : 21'd0));
        // In scenario 2 an older return blocks a fresh issuer; its combinational
        // address is unspecified while no new request is legal.
        if ((scenario != 2 && dut.rram_addr !== expected_address) ||
            dut.rram_req !== (scenario == 2 ? 1'b0 : 1'b1))
            $fatal(1, "PROMOTION next request got=%h expected=%h", dut.rram_addr, expected_address);
        checked++;
        // Reset before the next request is sampled; response data is not checked.
        @(negedge clk); rst_n = 0;
        release dut.rram_ready; release dut.hup_ready; release dut.yacc_busy;
        release dut.sched_u.cp; release dut.sched_u.hbuf_bank_ready;
    endtask
    // Scheduler-port collision: bypass bus traffic, retain real admission and
    // retirement logic. The external full-Tile CMD_RETIRE probe is separate.
    task automatic check_command_collision(input bit d_commit);
        rst_n = 0; repeat (3) @(negedge clk); rst_n = 1;
        old_head = '0; old_head.valid = 1; old_head.phase = d_commit ? 1 : 0;
        old_head.pass_id = 5; old_head.hbank = 0;
        collision_payload = '0;
        collision_payload[1:0] = d_commit ? 0 : 1;
        collision_payload[21:20] = 2'b11;
        collision_payload[42:22] = 21'h200;
        collision_payload[45:43] = 3'd1;
        collision_payload[47] = 1'b1;
        force dut.sched_u.slot = '{old_head, '0};
        force dut.sched_u.cp = '{'{gu_words:16'h100, d_words:16'h80,
            nkb:17'd160, ngroups:6'd9, ncols:4'd8, sw:4'd1, period:3'd1,
            bias_en:1'b1, bias_first_d:2'd1, legal:1'b1, default:'0}, '0};
        force dut.sched_u.hup_beat = 0; force dut.sched_u.hup_beats = 1;
        if (d_commit) force dut.sched_u.pstate = dut.sched_u.P_DCOMMIT;
        else force dut.sched_u.pstate = dut.sched_u.P_HUP;
        force dut.rram_ready = 1'b0;
        force dut.hup_ready = 1'b1; force dut.yacc_busy = 1'b0;
        force dut.sched_u.cmd_in_valid = 1'b1;
        force dut.sched_u.cmd_in_payload = collision_payload;
        force dut.sched_u.cmd_in_pass = 8'd9;
        #1; release dut.sched_u.slot; release dut.sched_u.hup_beat;
        release dut.sched_u.hup_beats; release dut.sched_u.pstate;
        @(posedge clk); #1;
        if (dut.sched_u.slot[0].valid !== 1'b1 || dut.sched_u.slot[1].valid !== 1'b0 ||
            dut.sched_u.slot[0].pass_id !== 8'd9 ||
            dut.sched_u.slot[0].phase !== (d_commit ? 2'd0 : 2'd1) ||
            dut.sched_u.phase_base[0] !== (d_commit ? 21'h200 : 21'h300) ||
            dut.sched_u.tail_base[0] !== 21'h380 ||
            dut.sched_u.iss[0].valid !== 1'b1 || dut.sched_u.iss[0].started !== 1'b0 ||
            dut.sched_u.iss[0].bias !== 1'b1 ||
            dut.sched_u.iss[0].bidx !== (d_commit ? 2'd0 : 2'd1) ||
            dut.sched_u.ev_cmd_illegal !== 1'b0 || dut.sync1 !== 1'b1)
            $fatal(1, "CMD_COLLISION lost descriptor or issuer path=%0d", d_commit);
        if (d_commit && (dut.sched_u.hbuf_take !== 1'b1 ||
            dut.sched_u.hbuf_release !== 1'b1 || dut.sched_u.hbuf_bank !== 1'b1 ||
            dut.sched_u.hbuf_release_bank !== 1'b0))
            $fatal(1, "CMD_COLLISION bank ownership targets conflated");
        collision_cases++;
        @(negedge clk); rst_n = 0;
        release dut.sched_u.cmd_in_valid; release dut.sched_u.cmd_in_payload;
        release dut.sched_u.cmd_in_pass; release dut.sched_u.cp;
        release dut.rram_ready; release dut.hup_ready; release dut.yacc_busy;
    endtask
    // Counter boundary test. Entire counter array is seeded, then released
    // before clocking; only the real scheduler logic may update it.
    task automatic check_counters(input bit d_commit, input integer mode);
        logic [31:0] expected_phase, expected_other, expected_sync;
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        counter_seed = mode == 0 ? 32'd7 : mode == 1 ? 32'hfffffffe :
                       mode == 2 ? 32'hffffffff : 32'd19;
        old_head = '0; old_head.valid = 1; old_head.phase = d_commit ? 1 : 0;
        force dut.sched_u.slot = '{old_head, '0};
        force dut.sched_u.cnt = '{default:counter_seed};
        force dut.sched_u.hup_beat = 0;
        force dut.sched_u.hup_beats = 1;
        if (d_commit) force dut.sched_u.pstate = dut.sched_u.P_DCOMMIT;
        else force dut.sched_u.pstate = dut.sched_u.P_HUP;
        force dut.rram_ready = 1'b0;
        force dut.hup_ready = 1'b0;
        force dut.yacc_busy = 1'b1;
        force dut.sched_u.cnt_clear = 1'b0;
        #1;
        release dut.sched_u.slot; release dut.sched_u.cnt;
        release dut.sched_u.hup_beat; release dut.sched_u.hup_beats;
        release dut.sched_u.pstate;
        @(posedge clk); #1;
        if (dut.sched_u.cnt[0] !== counter_seed || dut.sched_u.cnt[1] !== counter_seed ||
            dut.sched_u.cnt[11] !== counter_seed)
            $fatal(1, "COUNTERS incremented while retirement blocked");
        @(negedge clk);
        force dut.hup_ready = 1'b1; force dut.yacc_busy = 1'b0;
        if (mode == 3) force dut.sched_u.cnt_clear = 1'b1;
        @(posedge clk); #1;
        expected_phase = mode == 3 ? 32'd0 : mode == 2 ? 32'hffffffff : counter_seed + 32'd1;
        expected_other = mode == 3 ? 32'd0 : counter_seed;
        if (dut.sched_u.cnt[d_commit ? 1 : 0] !== expected_phase ||
            dut.sched_u.cnt[d_commit ? 0 : 1] !== expected_other || dut.sync1 !== 1'b1)
            $fatal(1, "COUNTERS retirement/saturation/clear mismatch path=%0d mode=%0d", d_commit, mode);
        if (mode == 3)
            for (integer i = 0; i < 13; i++)
                if (dut.sched_u.cnt[i] !== 32'd0) $fatal(1, "COUNTERS clear missed index=%0d", i);
        @(negedge clk); force dut.sched_u.cnt_clear = 1'b0;
        @(posedge clk); #1;
        // CNT_SYNC1 samples the registered pulse one edge after retirement.
        // A clear on the prior edge does not suppress this later event.
        expected_sync = mode == 3 ? 32'd1 : mode == 2 ? 32'hffffffff : counter_seed + 32'd1;
        if (dut.sched_u.cnt[11] !== expected_sync || dut.sync1 !== 1'b0)
            $fatal(1, "COUNTERS registered SYNC1 accounting mismatch");
        @(posedge clk); #1;
        if (dut.sched_u.cnt[d_commit ? 1 : 0] !== expected_phase ||
            dut.sched_u.cnt[d_commit ? 0 : 1] !== expected_other ||
            dut.sched_u.cnt[11] !== expected_sync)
            $fatal(1, "COUNTERS counted a completion more than once");
        counter_cases++;
        @(negedge clk); rst_n = 0;
        release dut.rram_ready; release dut.hup_ready; release dut.yacc_busy;
        release dut.sched_u.cnt_clear;
    endtask
    task automatic check_quant_guard(input bit bank, input bit release_bank, input integer release_age);
        rst_n = 0;
        repeat (3) @(negedge clk);
        guard_valid = 0; guard_bank = bank;
        guard_release = 0; guard_release_bank = release_bank;
        force dut.sched_u.quant_valid = guard_valid;
        force dut.sched_u.hsel = guard_bank;
        force dut.sched_u.quant_lane = 3'd0;
        force dut.sched_u.quant_idx = 7'd1;
        force dut.sched_u.quant_h = 512'd0;
        force dut.sched_u.hbuf_release = guard_release;
        force dut.sched_u.hbuf_release_bank = guard_release_bank;
        rst_n = 1;
        for (integer age = 0; age <= 5; age++) begin
            guard_valid = age == 0;
            guard_release = age == release_age;
            #1;
            // Observe before the edge consuming quantizer output. Real
            // quantizer data/tag pipeline is used, with only inputs forced.
            if (dut.sched_u.quant_ov !== (age == 4))
                $fatal(1, "QUANT_GUARD output latency age=%0d", age);
            if (age == 4) begin
                if (dut.sched_u.quant_otag !== {bank,3'd0,7'd1})
                    $fatal(1, "QUANT_GUARD tag alignment");
                if (dut.sched_u.quant_stale !== (release_age >= 0 && bank == release_bank) ||
                    dut.hbuf_wr_valid !== !(release_age >= 0 && bank == release_bank))
                    $fatal(1, "QUANT_GUARD release age=%0d bank=%0d target=%0d", release_age, bank, release_bank);
                if (release_age >= 0 && bank == release_bank &&
                    dut.sched_u.err_events[ERR_H_ORDER] !== 1'b1)
                    $fatal(1, "QUANT_GUARD missing error");
            end
            @(posedge clk); #1;
            @(negedge clk);
        end
        quant_guard_cases++;
        rst_n = 0;
        release dut.sched_u.quant_valid; release dut.sched_u.hsel;
        release dut.sched_u.quant_lane; release dut.sched_u.quant_idx;
        release dut.sched_u.quant_h; release dut.sched_u.hbuf_release;
        release dut.sched_u.hbuf_release_bank;
    endtask
    task automatic check_route_guard(input bit bank, input bit release_bank);
        rst_n = 0;
        repeat (3) @(negedge clk);
        route_owners = 2'b01 << bank;
        guard_release_bank = release_bank;
        force dut.sched_u.hbuf_owner_valid = route_owners;
        force dut.sched_u.hbuf_owner_pass0 = 8'd5;
        force dut.sched_u.hbuf_owner_pass1 = 8'd5;
        force dut.sched_u.hbuf_release = 1'b1;
        force dut.sched_u.hbuf_release_bank = guard_release_bank;
        force dut.sched_u.h_valid = 1'b1;
        force dut.sched_u.h_pass = 8'd5;
        force dut.sched_u.h_idx = 10'd1;
        force dut.sched_u.h_lane = 3'd0;
        force dut.sched_u.h_data = 512'd0;
        rst_n = 1;
        @(posedge clk); #1;
        if (dut.sched_u.quant_valid !== (bank != release_bank) ||
            dut.sched_u.ev_horder !== (bank == release_bank))
            $fatal(1, "ROUTE_GUARD bank=%0d release=%0d", bank, release_bank);
        if (bank != release_bank && dut.sched_u.hsel !== bank)
            $fatal(1, "ROUTE_GUARD wrong selected bank");
        route_guard_cases++;
        @(negedge clk); rst_n = 0;
        release dut.sched_u.hbuf_owner_valid;
        release dut.sched_u.hbuf_owner_pass0; release dut.sched_u.hbuf_owner_pass1;
        release dut.sched_u.hbuf_release; release dut.sched_u.hbuf_release_bank;
        release dut.sched_u.h_valid; release dut.sched_u.h_pass;
        release dut.sched_u.h_idx; release dut.sched_u.h_lane; release dut.sched_u.h_data;
    endtask
    initial begin
        for (integer bank = 0; bank < 2; bank++)
            for (integer target = 0; target < 2; target++)
                check_route_guard(1'(bank), 1'(target));
        if (route_guard_cases != 4) $fatal(1, "ROUTE_GUARD incomplete coverage");
        $display("CHECK route_guard cases=4 rejected=2 independent=2");
        for (integer bank = 0; bank < 2; bank++) begin
            check_quant_guard(1'(bank), 1'(bank), -1);
            for (integer target = 0; target < 2; target++)
                for (integer age = 0; age <= 4; age++)
                    check_quant_guard(1'(bank), 1'(target), age);
        end
        if (quant_guard_cases != 22) $fatal(1, "QUANT_GUARD incomplete coverage");
        $display("CHECK quant_guard cases=22 canceled=10 independent=10 baseline=2");
        for (integer path = 0; path < 2; path++)
            for (integer index = 0; index < 3; index++)
                for (integer scenario = 0; scenario < 3; scenario++)
                    check_transition(1'(path), index, scenario);
        if (checked != 18 || stalled != 18 || issued != 6 || scales != 6) $fatal(1, "PROMOTION incomplete coverage");
        for (integer path = 0; path < 2; path++)
            for (integer mode = 0; mode < 4; mode++) check_counters(1'(path), mode);
        for (integer path = 0; path < 2; path++) check_command_collision(1'(path));
        if (collision_cases != 2) $fatal(1, "CMD_COLLISION incomplete coverage");
        $display("CHECK command_collision paths=2 descriptors=2 bank_targets=1");
        if (counter_cases != 8) $fatal(1, "COUNTERS incomplete coverage");
        $display("CHECK counters paths=2 cases=8 blocked=8 saturation=4 clear=2 no_double=8");
        $display("CHECK promotion paths=2 distinct_tail=18 stalled=18 address_checks=12 simultaneous_issue=6 scale_consume=6");
        $display("PASS promotion cases=18");
        $finish;
    end
endmodule
