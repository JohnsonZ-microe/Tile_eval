// Full-loop self-check bench: replays flits.txt with the hub-side x-FIFO
// credit model (128 seeded, one per sync[0] pop), returns up credits at a
// configurable rate, and compares every up beat against expect.txt.
// +VECTORS=<dir> +GAP=<n> +CRED_PERIOD=<n>
`timescale 1ns/1ps
module tb_tile_v4;
    logic clk = 0, rst_n = 0;
    logic up_valid;
    logic [127:0] up_payload;
    logic [23:0] up_sideband;
    logic sync0, sync1, err_line;
    longint unsigned cycle_count = 0;
    always #5 clk = ~clk;
    integer ffd, efd, rfd, errors = 0, beats = 0, flits = 0;
    integer gap = 1, cred_period = 1, cred_timer = 0;
    integer xfifo_credit = 128;
    integer sync1_count = 0;
    integer y_packet_count = 0;
    integer phase_requests = 0;
    bit overlap = 0, pending_gather_fence = 0;
    integer expected_flits, expected_beats, expected_sync, expected_packets, cfd;
    logic [21:0] expected_errors;
    integer trace_fd = 0, trace_issue = 0, trace_return = 0, trace_consume = 0;
    integer trace_accept = 0, trace_commit = 0;
    integer trace_sync = 0, trace_beat = 0;
    string trace_path;
    bit [127:0] trace_y_valid = 0;
    initial begin
        if ($value$plusargs("TRACE=%s", trace_path)) begin
            trace_fd = $fopen(trace_path, "w");
            if (!trace_fd) $fatal(1, "cannot open TRACE");
            $fdisplay(trace_fd, "cycle,event,transaction,value");
        end
    end
    task automatic trace_event(input string event_name, input integer transaction, value);
        $fdisplay(trace_fd, "%0d,%s,%0d,%0d",
                  cycle_count, event_name, transaction, value);
    endtask
    always @(posedge clk) begin
        if (!rst_n) begin
            trace_issue = 0; trace_return = 0; trace_consume = 0;
            trace_accept = 0; trace_commit = 0; trace_y_valid = 0;
            trace_sync = 0; trace_beat = 0;
        end else if (trace_fd) begin
            if (dut.rram_req && dut.rram_ready) begin
                trace_event("rram_issue", trace_issue, 0);
                trace_issue++;
            end
            if (dut.rram_valid) begin
                trace_event("rram_return", trace_return, 0);
                trace_return++;
            end
            if (dut.sched_u.cons_fire) begin
                trace_event("rram_consume", trace_consume, 0);
                trace_consume++;
            end
            if (dut.sched_u.pe_accept) begin
                trace_event("pe_accept", trace_accept, dut.sched_u.pe_col_base);
                trace_accept++;
            end
            if (dut.pe_out_valid) begin
                trace_event("pe_commit", trace_commit, dut.pe_out_col_base);
                trace_commit++;
            end
            if (dut.sched_u.act_in_valid)
                trace_event("act_accept", dut.sched_u.act_c, 0);
            if (dut.sched_u.act_out_valid)
                trace_event("act_return", dut.sched_u.act_cout, 0);
            if (dut.sched_u.quant_valid)
                trace_event("quant_accept", dut.sched_u.quant_tag, 0);
            if (dut.sched_u.quant_ov) trace_event("quant_return", dut.sched_u.quant_otag, 0);
            if (dut.hbuf_release) trace_event("bank_release", dut.hbuf_wr_bank_sel, 0);
            if (sync1) begin
                trace_event("sync1", trace_sync, 0); trace_sync++;
            end
            if (up_valid) begin
                trace_event("up_beat", trace_beat, int'(up_sideband)); trace_beat++;
            end
            for (integer bank = 0; bank < 2; bank++)
                for (integer slot_id = 0; slot_id < 64; slot_id++) begin
                    if (dut.yacc_u.vbit[bank][slot_id] === 1'b1 &&
                        !trace_y_valid[bank*64+slot_id])
                        trace_event("y_ready", bank*64+slot_id, 0);
                    trace_y_valid[bank*64+slot_id] = dut.yacc_u.vbit[bank][slot_id] === 1'b1;
                end
            $fflush(trace_fd);
        end
    end
    integer wait_limit = 2000000;
    integer progress_cycles = 10000;
    integer max_cycles = 20000000;
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
    tile_ffn_v4 #(.RRAM_WORDS(262144)) dut (
        .clk(clk), .rst_n(rst_n),
        .dn_valid(dn_valid), .dn_payload(dn_payload), .dn_sideband(dn_sideband),
        .up_valid(up_valid), .up_credit(up_credit), .up_payload(up_payload),
        .up_sideband(up_sideband),
        .sync0(sync0), .sync1(sync1), .err_line(err_line),
        .sim_load(sim_load_r), .sim_addr(sim_addr_r), .sim_data(sim_data_r));
    // ---------- up beat checker ----------
    logic [30:0] rq_probe_metadata [0:3];
    logic [7:0] rq_probe_pass [0:3];
    logic [1023:0] rq_probe_data [0:3];
    longint unsigned rq_probe_issue_cycle [0:3];
    longint unsigned rq_probe_return_cycle [0:3];
    longint unsigned rq_probe_cycle = 0;
    integer rq_probe_issued = 0, rq_probe_returned = 0, rq_probe_consumed = 0;
    always @(posedge clk) begin : rq_identity_monitor
        integer entry_index, source_slot;
        logic [30:0] actual_metadata;
        if (!rst_n) begin
            rq_probe_cycle = 0;
            rq_probe_issued = 0; rq_probe_returned = 0; rq_probe_consumed = 0;
        end else begin
            if ($isunknown({dut.rram_req, dut.rram_ready, dut.rram_valid,
                            dut.sched_u.cons_fire}))
                $fatal(1, "RQ probe unknown handshake");
            if (dut.sched_u.rq_cnt !== 3'(rq_probe_issued-rq_probe_consumed))
                $fatal(1, "RQ probe reservation count");
            if (dut.rram_req && dut.rram_ready &&
                (rq_probe_issued-rq_probe_consumed >= 4 ||
                 rq_probe_issued-rq_probe_returned >= 3))
                $fatal(1, "RQ probe pre-edge capacity violation");
            if (rq_probe_returned < rq_probe_issued &&
                rq_probe_cycle == rq_probe_issue_cycle[rq_probe_returned % 4]+3 &&
                dut.rram_valid !== 1'b1)
                $fatal(1, "RQ probe missing scheduled return");
            if (dut.sched_u.cons_fire) begin
                if (rq_probe_consumed >= rq_probe_returned)
                    $fatal(1, "RQ probe consume before registered return");
                entry_index = rq_probe_consumed % 4;
                if (rq_probe_cycle <= rq_probe_return_cycle[entry_index])
                    $fatal(1, "RQ probe same-edge return bypass");
                actual_metadata = {dut.sched_u.head.slot, dut.sched_u.head.phase,
                    dut.sched_u.head.bias, dut.sched_u.head.scale,
                    dut.sched_u.head.bidx, dut.sched_u.head.swi,
                    dut.sched_u.head.kb, dut.sched_u.head.g,
                    dut.sched_u.head.ncols, dut.sched_u.head.fmt};
                if (actual_metadata !== rq_probe_metadata[entry_index] ||
                    dut.sched_u.slot[dut.sched_u.head.slot].pass_id !== rq_probe_pass[entry_index])
                    $fatal(1, "RQ probe metadata/pass mismatch transaction=%0d", rq_probe_consumed);
                if (dut.sched_u.head.full !== 1'b1 ||
                    dut.sched_u.head.data !== rq_probe_data[entry_index] ||
                    $isunknown(dut.sched_u.head.data))
                    $fatal(1, "RQ probe consumed data mismatch transaction=%0d", rq_probe_consumed);
                rq_probe_consumed++;
            end
            if (dut.rram_valid) begin
                if (rq_probe_returned >= rq_probe_issued)
                    $fatal(1, "RQ probe unsolicited return");
                entry_index = rq_probe_returned % 4;
                if (rq_probe_cycle-rq_probe_issue_cycle[entry_index] != 3)
                    $fatal(1, "RQ probe return latency transaction=%0d", rq_probe_returned);
                if ($isunknown(dut.rram_data))
                    $fatal(1, "RQ probe unknown returned data");
                rq_probe_data[entry_index] = dut.rram_data;
                rq_probe_return_cycle[entry_index] = rq_probe_cycle;
                rq_probe_returned++;
            end
            if (dut.rram_req && dut.rram_ready) begin
                if (rq_probe_issued-rq_probe_consumed >= 4)
                    $fatal(1, "RQ probe reservation overflow");
                if ({dut.sched_u.iss_fire1, dut.sched_u.iss_fire0} !== 2'b01 &&
                    {dut.sched_u.iss_fire1, dut.sched_u.iss_fire0} !== 2'b10)
                    $fatal(1, "RQ probe ambiguous issue slot");
                source_slot = dut.sched_u.iss_fire0 ? 0 : 1;
                entry_index = rq_probe_issued % 4;
                rq_probe_metadata[entry_index] = {1'(source_slot),
                    dut.sched_u.slot[source_slot].phase,
                    dut.sched_u.iss[source_slot].bias,
                    (dut.sched_u.iss[source_slot].scale && !dut.sched_u.iss[source_slot].bias),
                    dut.sched_u.iss[source_slot].bidx, dut.sched_u.iss[source_slot].swi,
                    8'(dut.sched_u.iss[source_slot].kb), dut.sched_u.iss[source_slot].g,
                    dut.sched_u.cp[dut.sched_u.slot[source_slot].ctx_sel].ncols,
                    dut.sched_u.slot[source_slot].fmt};
                rq_probe_pass[entry_index] = dut.sched_u.slot[source_slot].pass_id;
                if ($isunknown({rq_probe_metadata[entry_index], rq_probe_pass[entry_index]}))
                    $fatal(1, "RQ probe unknown issue metadata");
                rq_probe_issue_cycle[entry_index] = rq_probe_cycle;
                rq_probe_issued++;
            end
            rq_probe_cycle++;
        end
    end
    logic [127:0] exp_payload;
    logic [23:0] exp_sideband;
    logic exp_last;
    integer erc;
    wire [11:0] drain_blocked;
    always @(posedge clk) begin
        if (rst_n) begin
            if ($isunknown({dut.sched_u.rq_cnt, dut.sched_u.cap_cnt}) ||
                dut.sched_u.rq_cnt > 4 || dut.sched_u.cap_cnt > 63)
                $fatal(1, "queue count invariant");
            if (dut.sched_u.pe_accept &&
                dut.sched_u.slot[dut.sched_u.head.slot].valid !== 1'b1)
                $fatal(1, "PE accepted an orphaned slot descriptor");
            if (dut.yacc_load_valid && dut.yacc_u.commit_busy)
                $fatal(1, "D capture overwrote an active commit buffer");
        end
    end
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
        overlap = $test$plusargs("OVERLAP");
        cfd = $fopen({vecdir, "/checks.txt"}, "r");
        if (!cfd) $fatal(1, "missing checks.txt");
        if ($fscanf(cfd, "%d %d %d %d %h", expected_flits, expected_beats,
                    expected_sync, expected_packets, expected_errors) != 5 ||
            expected_flits <= 0 || expected_beats <= 0)
            $fatal(1, "malformed checks.txt");
        $fclose(cfd);
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
                if (!overlap && sb[2:0] == 3'd0 && pay[1:0] == 2'd1)
                    wait_phase(phase_requests);
                if (pending_gather_fence && sb[2:0] == 3'd3) begin
                    wait_phase(phase_requests - 1);
                    pending_gather_fence = 0;
                end
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
                if (overlap && sb[2:0] == 3'd0 && pay[1:0] == 2'd1)
                    pending_gather_fence = 1;
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
        if (sync1_count != expected_sync || flits != expected_flits ||
            beats != expected_beats || y_packet_count != expected_packets) begin
            $display("FAIL count mismatch flits=%0d/%0d beats=%0d/%0d sync=%0d/%0d y=%0d/%0d",
                     flits, expected_flits, beats, expected_beats,
                     sync1_count, expected_sync, y_packet_count, expected_packets);
            errors++;
        end
        if (e_valid) begin
            $display("FAIL missing expected beats");
            errors++;
        end
        if (dut.sched_u.err_q !== expected_errors) begin
            $display("FAIL err_status=%06x", dut.sched_u.err_q);
            errors++;
        end
        if (errors == 0) begin
            if (rq_probe_issued == 0 || rq_probe_issued != rq_probe_returned ||
                rq_probe_returned != rq_probe_consumed)
                $fatal(1, "RQ probe incomplete workload");
            $display("CHECK rq_identity issued=%0d returned=%0d consumed=%0d",
                     rq_probe_issued, rq_probe_returned, rq_probe_consumed);
            $display("PASS tile flits=%0d beats=%0d sync1=%0d",
                     flits, beats, sync1_count);
        end
        else
            $display("FAIL tile errors=%0d flits=%0d beats=%0d",
                     errors, flits, beats);
        $fflush();
        $finish;
    end
    integer calibration_fd = 0;
    integer calibration_epoch = 0;
    integer calibration_issue = 0, calibration_return = 0, calibration_consume = 0;
    longint unsigned calibration_cycle = 0;
    bit calibration_reset_seen = 0;
    bit [127:0] calibration_y_valid = 0;
    string calibration_path;
    initial begin
        if ($value$plusargs("CALIBRATION_TRACE=%s", calibration_path)) begin
            calibration_fd = $fopen(calibration_path, "w");
            if (!calibration_fd) $fatal(1, "cannot open CALIBRATION_TRACE");
            $fdisplay(calibration_fd, "epoch,cycle,sample,event,transaction,pass,phase,slot,kb,group,bank,payload");
        end
    end
    task automatic calibration_event(input string sampling, event_name,
        input longint unsigned edge_cycle,
        input integer transaction, pass_id, phase_id, slot_id, kb, group_id, bank,
        input logic [511:0] payload);
        $fdisplay(calibration_fd, "%0d,%0d,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0128h",
            calibration_epoch, edge_cycle, sampling, event_name, transaction,
            pass_id, phase_id, slot_id, kb, group_id, bank, payload);
    endtask
    always @(posedge clk) begin : calibration_monitor
        longint unsigned edge_cycle;
        integer issue_slot;
        edge_cycle = calibration_cycle;
        if (calibration_fd) begin
            if (!rst_n) begin
                if (!calibration_reset_seen) begin
                    calibration_event("pre", "reset", 0, -1, -1, -1, -1, -1, -1, -1, '0);
                    calibration_reset_seen = 1;
                end
                calibration_cycle = 0;
                calibration_y_valid = 0;
                calibration_issue = 0; calibration_return = 0; calibration_consume = 0;
            end else begin
                calibration_reset_seen = 0;
                if (dn_valid)
                    calibration_event("pre", "down", edge_cycle, int'(dn_sideband), int'(dn_sideband[10:3]), -1, -1, -1, -1, -1, dn_payload);
                if (up_credit != 0)
                    calibration_event("pre", "credit", edge_cycle, -1, -1, -1, -1, -1, -1, -1, 512'(up_credit));
                if (dut.rram_req && dut.rram_ready) begin
                    issue_slot = dut.sched_u.iss_fire0 ? 0 : 1;
                    calibration_event("pre", "memory_issue", edge_cycle, calibration_issue,
                        int'(dut.sched_u.slot[issue_slot].pass_id), int'(dut.sched_u.slot[issue_slot].phase),
                        issue_slot, int'(dut.sched_u.iss[issue_slot].kb), int'(dut.sched_u.iss[issue_slot].g),
                        -1, 512'(dut.rram_addr));
                    calibration_issue++;
                end
                if (dut.rram_valid) begin
                    calibration_event("pre", "memory_return", edge_cycle, calibration_return, -1, -1, -1, -1, -1, -1, '0);
                    calibration_return++;
                end
                if (dut.sched_u.cons_fire) begin
                    calibration_event("pre", "memory_consume", edge_cycle, calibration_consume,
                        int'(dut.sched_u.slot[dut.sched_u.head.slot].pass_id), int'(dut.sched_u.head.phase),
                        int'(dut.sched_u.head.slot), int'(dut.sched_u.head.kb), int'(dut.sched_u.head.g), -1,
                        512'({dut.sched_u.head.bias,dut.sched_u.head.scale}));
                    calibration_consume++;
                end
                if (dut.sched_u.pe_accept)
                    calibration_event("pre", "pe_accept", edge_cycle, int'(dut.pe_tag), int'(dut.sched_u.slot[dut.sched_u.head.slot].pass_id),
                        int'(dut.sched_u.head.phase), int'(dut.sched_u.head.slot), int'(dut.sched_u.head.kb), int'(dut.sched_u.head.g), -1,
                        512'({dut.pe_col_base,dut.pe_mask}));
                if (dut.stg_rd_req)
                    calibration_event("pre", "staging_request", edge_cycle, int'(dut.stg_rd_kb), -1, 0, -1, int'(dut.stg_rd_kb), -1, -1, '0);
                if (dut.stg_rd_valid)
                    calibration_event("pre", "staging_consume", edge_cycle, -1, -1, 0, -1, -1, -1, -1, '0);
                if (dut.hbuf_rd_req)
                    calibration_event("pre", "hbank_request", edge_cycle, int'(dut.hbuf_rd_idx), -1, 1, -1, int'(dut.hbuf_rd_idx), -1, int'(dut.hbuf_rd_bank), '0);
                if (dut.hbuf_rd_valid)
                    calibration_event("pre", "hbank_consume", edge_cycle, -1, -1, 1, -1, -1, -1, -1, '0);
                if (dut.act_in_valid)
                    calibration_event("pre", "act_accept", edge_cycle, int'(dut.sched_u.act_c), -1, 0, -1, -1, -1, -1, '0);
                if (dut.act_out_valid)
                    calibration_event("pre", "act_consume", edge_cycle, int'(dut.sched_u.act_cout), -1, 0, -1, -1, -1, -1, '0);
                if (dut.sched_u.quant_valid)
                    calibration_event("pre", "quant_accept", edge_cycle, int'(dut.sched_u.quant_tag), -1, 1, -1, -1, -1, -1, '0);
                if (dut.sched_u.quant_ov)
                    calibration_event("pre", "quant_consume", edge_cycle, int'(dut.sched_u.quant_otag), -1, 1, -1, -1, -1, -1, '0);
                if (dut.hbuf_release)
                    calibration_event("pre", "bank_release", edge_cycle, -1, -1, 1, -1, -1, -1, int'(dut.hbuf_wr_bank_sel), '0);
                if (dut.yacc_commit_trigger)
                    calibration_event("pre", "y_commit", edge_cycle, -1, -1, 1, -1, -1, -1, int'(dut.yacc_bank), 512'(dut.yacc_mask));
                if (dut.drain_fire)
                    calibration_event("pre", "drain_accept", edge_cycle, int'(dut.drain_slot), -1, 1, -1, -1, -1, int'(dut.drain_bank),
                        512'({dut.drain_cstart,dut.drain_count}));
                if (up_valid)
                    calibration_event("pre", "up_beat", edge_cycle, int'(up_sideband), int'(up_sideband[16:9]), -1, -1, -1, -1, -1, 512'(up_payload));
                if (sync1)
                    calibration_event("pre", "sync1", edge_cycle, -1, -1, -1, -1, -1, -1, -1, '0);
                #1;
                if (dut.pe_out_valid)
                    calibration_event("post", "pe_commit_visible", edge_cycle, int'(dut.pe_u.out_tag), -1, -1, -1, -1, -1, -1, 512'(dut.pe_out_col_base));
                for (integer bank_id = 0; bank_id < 2; bank_id++)
                    for (integer slot_id = 0; slot_id < 64; slot_id++) begin
                        if (dut.yacc_u.vbit[bank_id][slot_id] === 1'b1 && !calibration_y_valid[bank_id*64+slot_id])
                            calibration_event("post", "y_ready_visible", edge_cycle, slot_id, -1, 1, -1, -1, -1, bank_id, '0);
                        calibration_y_valid[bank_id*64+slot_id] = dut.yacc_u.vbit[bank_id][slot_id] === 1'b1;
                    end
                calibration_cycle = edge_cycle + 1;
            end
            $fflush(calibration_fd);
        end
    end
    always @(negedge rst_n) begin
        if (calibration_fd && calibration_cycle != 0) calibration_epoch++;
    end
endmodule

