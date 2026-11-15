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
    initial begin
        for (integer path = 0; path < 2; path++)
            for (integer index = 0; index < 3; index++)
                for (integer scenario = 0; scenario < 3; scenario++)
                    check_transition(1'(path), index, scenario);
        if (checked != 18 || stalled != 18 || issued != 6 || scales != 6) $fatal(1, "PROMOTION incomplete coverage");
        $display("CHECK promotion paths=2 distinct_tail=18 stalled=18 address_checks=12 simultaneous_issue=6 scale_consume=6");
        $display("PASS promotion cases=18");
        $finish;
    end
endmodule
