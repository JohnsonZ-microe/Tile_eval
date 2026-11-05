// Full-loop self-check bench: replays flits.txt with the hub-side x-FIFO
// credit model (128 seeded, one per sync[0] pop), returns up credits at a
// configurable rate, and compares every up beat against expect.txt.
// +VECTORS=<dir> +GAP=<n> +CRED_PERIOD=<n>
`timescale 1ns/1ps
module tb_tile_v4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer ffd, efd, rfd, errors = 0, beats = 0, flits = 0;
    integer gap = 1, cred_period = 1, cred_timer = 0;
    integer xfifo_credit = 128;
    integer sync1_count = 0;
    integer y_packet_count = 0;
    integer phase_requests = 0;
    integer wait_limit = 2000000;
    integer progress_cycles = 10000;
    integer max_cycles = 20000000;
    longint unsigned cycle_count = 0;
    string diagnostic_stage = "reset";
    integer diagnostic_target = 0;
    logic diagnostic_bank = 0;
    logic [5:0] diagnostic_slot = 0;
    integer up_outstanding = 0;
    string vecdir;
    logic [1023:0] a1, a2;
    logic dn_valid = 0;
    logic [511:0] dn_payload = 0;
    logic [31:0] dn_sideband = 0;
    logic [1:0] up_credit = 0;
    logic up_valid;
    logic [127:0] up_payload;
    logic [23:0] up_sideband;
    logic sync0, sync1, err_line;
    // optional VCD (run_vcs.sh / run.py --waves passes +VCD=<path>)
    string vcdfile;
    initial begin
        if ($value$plusargs("VCD=%s", vcdfile)) begin
            $dumpfile(vcdfile);
            $dumpvars(0, tb_tile_v4);
        end
    end
    // expected beat stream
    logic [1:0] e_type;
    logic [7:0] e_tag;
    logic e_last;
    logic [1:0] e_seg;
    logic [127:0] e_payload;
    logic e_valid = 0;
    // R4-fix (VIPCBD): drive the simulation load port through the port
    // connection; VCS forbids hierarchical assignment to input variables.
    logic sim_load_r = 0;
    logic [20:0] sim_addr_r = 0;
    logic [1023:0] sim_data_r = 0;
    tile_ffn_v4 #(.RRAM_WORDS(131072)) dut (
        .clk(clk), .rst_n(rst_n),
        .dn_valid(dn_valid), .dn_payload(dn_payload), .dn_sideband(dn_sideband),
        .up_valid(up_valid), .up_credit(up_credit), .up_payload(up_payload),
        .up_sideband(up_sideband),
        .sync0(sync0), .sync1(sync1), .err_line(err_line),
        .sim_load(sim_load_r), .sim_addr(sim_addr_r), .sim_data(sim_data_r));
    // ---------- up beat checker ----------
    logic [127:0] exp_payload;
    logic [23:0] exp_sideband;
    logic exp_last;
    integer erc;
    wire [11:0] drain_blocked;
    assign drain_blocked[0] = !((dut.sched_u.pstate === 3'd0) ||
                               (dut.sched_u.pstate === 3'd1));
    assign drain_blocked[1] = ({dut.sched_u.slot[0].valid, dut.sched_u.slot[1].valid} !== '0);
    assign drain_blocked[2] = ({dut.bus_u.xfifo_level, dut.sched_u.rq_cnt} !== '0);
    assign drain_blocked[3] = (dut.sched_u.cap_cnt !== '0);
    assign drain_blocked[4] = ({dut.pe_u.busy, dut.pe_in_valid, dut.pe_out_valid} !== '0);
    assign drain_blocked[5] = ({dut.sched_u.pend_act, dut.sched_u.pend_commit} !== '0);
    assign drain_blocked[6] = ({dut.yacc_u.commit_busy, dut.yacc_commit_trigger, dut.yacc_load_valid} !== '0);
    assign drain_blocked[7] = ({dut.yacc_u.dstate, dut.drain_fire} !== '0);
    assign drain_blocked[8] = ({dut.bus_u.active_valid, up_valid} !== '0);
    assign drain_blocked[9] = ({dut.bus_u.hup_valid, dut.yb_valid, dut.st_valid, dut.alarm_valid, dut.stf_cnt} !== '0);
    assign drain_blocked[10] = ({dut.rram_req, dut.rram_valid, dut.stg_rd_req, dut.stg_rd_valid, dut.hbuf_rd_req, dut.hbuf_rd_valid} !== '0);
    assign drain_blocked[11] = ({dn_valid, dut.cmd_valid, dut.h_valid, dut.ctrl_valid} !== '0);
    task automatic print_progress(input string event_name);
        $display("PROGRESS event=%s time=%0t cycle=%0d stage=%s target=%0d flits=%0d beats=%0d sync1=%0d y_packets=%0d x_credit=%0d up_credit=%0d x_fifo=%0d state=%0d rq=%0d pe_busy=%b y_busy=%b err=%06x y_bank=%0d y_slot=%0d y_valid=%b slot_valid=%b%b cap=%0d drain_blocked=%03x",
                 event_name, $time, cycle_count, diagnostic_stage,
                 diagnostic_target, flits, beats, sync1_count, y_packet_count,
                 xfifo_credit, dut.bus_u.credit, dut.bus_u.xfifo_level,
                 dut.sched_u.pstate, dut.sched_u.rq_cnt, dut.pe_u.busy,
                 dut.yacc_u.commit_busy, dut.sched_u.err_q,
                 diagnostic_bank, diagnostic_slot,
                 dut.yacc_u.vbit[diagnostic_bank][diagnostic_slot],
                 dut.sched_u.slot[1].valid, dut.sched_u.slot[0].valid,
                 dut.sched_u.cap_cnt, drain_blocked);
        $fflush();
    endtask
    task automatic diagnostic_timeout(input string reason);
        print_progress(reason);
        $fatal(1, "TIMEOUT %s", reason);
    endtask
    always @(posedge clk) begin
        if (!rst_n) cycle_count <= 0;
        else cycle_count <= cycle_count + 1;
    end
    always @(negedge clk) begin
        if (rst_n) begin
            if (cycle_count >= max_cycles) diagnostic_timeout("global_cycles");
            if (progress_cycles > 0) begin
                if (cycle_count != 0 && cycle_count % progress_cycles == 0)
                    print_progress("heartbeat");
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n && up_valid) begin
            if (up_sideband[1:0] == 2'd1 && up_sideband[17])
                y_packet_count++;
            if (!e_valid) begin
                $display("FAIL unexpected up beat sb=%06x pay=%032x",
                         up_sideband, up_payload);
                errors++;
            end else begin
                // UP_SB/UP_SB_Y are LSB-first: type@1:0 src@8:2 tag@16:9
                // last@17 nphit@19:18 segment@21:20 rsvd high
                exp_sideband = {2'b00, e_seg, 2'd0, e_last, e_tag,
                                7'h10, e_type};
                if (up_sideband !== exp_sideband
                        || up_payload !== e_payload) begin
                    $display("FAIL beat %0d sb=%06x/%06x pay=%032x/%032x",
                             beats, up_sideband, exp_sideband,
                             up_payload, e_payload);
                    errors++;
                end
                beats++;
                up_outstanding++;
            end
        end
        if (sync1) begin
            sync1_count++;
            print_progress("phase_complete");
        end
        if (sync0 && xfifo_credit < 128) xfifo_credit++;
    end
    // credit return model: one credit per cred_period cycles while owed
    always @(posedge clk) begin
        up_credit <= 0;
        if (rst_n && up_outstanding > 0) begin
            cred_timer++;
            if (cred_timer >= cred_period) begin
                up_credit <= 1;
                up_outstanding--;
                cred_timer = 0;
            end
        end
    end
    // checker consumes e_valid when a beat is accepted (module scope,
    // not nested in the initial block - R4-003)
    always @(posedge clk) begin
        if (rst_n && up_valid) e_valid <= 0;
    end
    // ---------- main replay ----------
    logic [1023:0] word;
    logic [31:0] raddr32;
    integer addr = 0;
    task automatic wait_phase(input integer target);
        integer waited;
        diagnostic_stage = "wait_phase";
        diagnostic_target = target;
        waited = 0;
        while (sync1_count < target) begin
            @(negedge clk);
            waited++;
            if (waited >= wait_limit)
                diagnostic_timeout("wait_phase");
        end
    endtask
    task automatic wait_y_ready(input logic bank, input logic [5:0] slot_id);
        integer waited;
        diagnostic_stage = "wait_y_ready";
        diagnostic_bank = bank;
        diagnostic_slot = slot_id;
        waited = 0;
        while (dut.yacc_u.commit_busy !== 1'b0 ||
               dut.sched_u.yacc_commit_trigger !== 1'b0 ||
               dut.yacc_u.vbit[bank][slot_id] !== 1'b1) begin
            @(negedge clk);
            waited++;
            if (waited >= wait_limit)
                diagnostic_timeout("wait_y_ready");
        end
    endtask
    task automatic wait_y_packet(input integer target);
        integer waited;
        diagnostic_stage = "wait_y_packet";
        diagnostic_target = target;
        waited = 0;
        while (y_packet_count < target) begin
            @(negedge clk);
            waited++;
            if (waited >= wait_limit)
                diagnostic_timeout("wait_y_packet");
        end
        print_progress("drain_complete");
    endtask
    initial begin
        if (!$value$plusargs("VECTORS=%s", vecdir)) vecdir = "vectors";
        void'($value$plusargs("GAP=%d", gap));
        void'($value$plusargs("CRED_PERIOD=%d", cred_period));
        void'($value$plusargs("WAIT_LIMIT=%d", wait_limit));
        void'($value$plusargs("PROGRESS_CYCLES=%d", progress_cycles));
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        if (wait_limit <= 0) $fatal(1, "WAIT_LIMIT must be positive");
        if (progress_cycles < 0) $fatal(1, "PROGRESS_CYCLES must be nonnegative");
        if (max_cycles <= 0) $fatal(1, "MAX_CYCLES must be positive");
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        diagnostic_stage = "rram_load";
        // load the RRAM image through the simulation port
        rfd = $fopen({vecdir, "/rram.hex"}, "r");
        if (rfd == 0) begin
            $display("FATAL no rram.hex");
            $finish;
        end
        while ($fscanf(rfd, "%h %h", raddr32, word) == 2) begin
            @(negedge clk);
            sim_load_r = 1'b1;
            sim_addr_r = raddr32[20:0];
            sim_data_r = word;
            @(posedge clk);
            addr++;
        end
        $fclose(rfd);
        @(negedge clk);
        sim_load_r = 1'b0;
        $display("loaded %0d RRAM words", addr);
        print_progress("rram_loaded");
        efd = $fopen({vecdir, "/expect.txt"}, "r");
        ffd = $fopen({vecdir, "/flits.txt"}, "r");
        if (efd == 0 || ffd == 0) begin
            $display("FATAL missing flits/expect");
            $finish;
        end
        // ---------- expected-beat loader ----------
        fork : beatloader
            forever begin
                @(negedge clk);
                if (!e_valid && efd != 0) begin
                    erc = $fscanf(efd, "%s %d %h %d %d %h",
                                  a1, e_type, e_tag, e_last, e_seg, e_payload);
                    e_valid = (erc >= 6);
                    if (erc < 6) efd = 0;
                end
            end
        join_none
        // ---------- replay loop ----------
        begin : replay
            logic [1023:0] f1;
            logic [1023:0] f2;
            integer rc;
            logic [31:0] sb;
            logic [511:0] pay;
            logic is_drain;
            integer drain_target;
            integer credit_waited;
            forever begin
                diagnostic_stage = "replay";
                rc = $fscanf(ffd, "%s %d %h %h", f1, sb, f2, pay);
                if (rc < 4) disable replay;
                if (sb[2:0] == 3'd0 && pay[1:0] == 2'd1)
                    wait_phase(phase_requests);
                is_drain = sb[2:0] == 3'd4 && pay[3:0] == 4'd0;
                drain_target = y_packet_count + 1;
                if (is_drain) begin
                    wait_phase(phase_requests);
                    wait_y_ready(pay[17], pay[16:11]);
                end
                credit_waited = 0;
                while ((sb[2:0] == 3'd1 || sb[2:0] == 3'd2)
                       && xfifo_credit == 0) begin
                    diagnostic_stage = "wait_x_credit";
                    @(posedge clk);
                    credit_waited++;
                    if (credit_waited >= wait_limit)
                        diagnostic_timeout("wait_x_credit");
                end
                diagnostic_stage = "send_flit";
                if (sb[2:0] == 3'd1 || sb[2:0] == 3'd2) xfifo_credit--;
                @(negedge clk);
                dn_valid = 1;
                dn_sideband = sb;
                dn_payload = pay;
                if (sb[2:0] == 3'd0 && pay[1:0] < 2'd2)
                    phase_requests++;
                flits++;
                @(negedge clk);
                dn_valid = 0;
                if (sb[2:0] == 3'd0 && pay[1:0] < 2'd2) begin
                    if (pay[1:0] == 0) print_progress("gu_sent");
                    else print_progress("d_sent");
                end
                if (is_drain) print_progress("drain_sent");
                repeat (gap > 0 ? gap : 1) @(negedge clk);
                if (is_drain) wait_y_packet(drain_target);
            end
        end
        $fclose(ffd);
        // ---------- drain and final checks ----------
        begin : drain
            integer idle = 0;
            integer waited = 0;
            diagnostic_stage = "final_drain";
            $display("DRAIN_BLOCK_BITS 0=state 1=slots 2=x_or_rram_queue 3=capture_queue 4=pe 5=epilogue 6=y_commit 7=drain_engine 8=up_packet 9=pending_output 10=memory_io 11=down_input; X/Z blocks idle");
            print_progress("final_drain_begin");
            while (idle < 200) begin
                @(negedge clk);
                waited++;
                idle = (drain_blocked === 12'b0) ? idle + 1 : 0;
                if (waited >= wait_limit && idle < 200)
                    diagnostic_timeout("final_drain");
            end
        end
        if (sync1_count != 24) begin
            $display("FAIL sync1 count %0d != 24", sync1_count);
            errors++;
        end
        if (e_valid) begin
            $display("FAIL missing expected beats");
            errors++;
        end
        if (dut.sched_u.err_q !== 22'h0e0004) begin
            $display("FAIL err_status=%06x", dut.sched_u.err_q);
            errors++;
        end
        if (errors == 0)
            $display("PASS tile flits=%0d beats=%0d sync1=%0d",
                     flits, beats, sync1_count);
        else
            $display("FAIL tile errors=%0d flits=%0d beats=%0d",
                     errors, flits, beats);
        $fflush();
        $finish;
    end
endmodule

