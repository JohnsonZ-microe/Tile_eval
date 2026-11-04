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
    always @(posedge clk) begin
        if (rst_n && up_valid) begin
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
        if (sync1) sync1_count++;
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
    initial begin
        if (!$value$plusargs("VECTORS=%s", vecdir)) vecdir = "vectors";
        void'($value$plusargs("GAP=%d", gap));
        void'($value$plusargs("CRED_PERIOD=%d", cred_period));
        repeat (4) @(posedge clk);
        rst_n = 1;
        // load the RRAM image through the simulation port
        rfd = $fopen({vecdir, "/rram.hex"}, "r");
        if (rfd == 0) begin
            $display("FATAL no rram.hex");
            $finish;
        end
        while ($fscanf(rfd, "%h %h", raddr32, word) == 2) begin
            sim_load_r = 1'b1;
            sim_addr_r = raddr32[20:0];
            sim_data_r = word;
            @(posedge clk);
            addr++;
        end
        $fclose(rfd);
        sim_load_r = 1'b0;
        $display("loaded %0d RRAM words", addr);
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
            forever begin
                rc = $fscanf(ffd, "%s %d %h %h", f1, sb, f2, pay);
                if (rc < 4) disable replay;
                while ((sb[2:0] == 3'd1 || sb[2:0] == 3'd2)
                       && xfifo_credit == 0)
                    @(posedge clk);
                if (sb[2:0] == 3'd1 || sb[2:0] == 3'd2) xfifo_credit--;
                dn_valid = 1;
                dn_sideband = sb;
                dn_payload = pay;
                flits++;
                repeat (gap) @(posedge clk);
                dn_valid = 0;
                @(posedge clk);
            end
        end
        $fclose(ffd);
        // ---------- drain and final checks ----------
        begin : drain
            integer idle = 0;
            while (idle < 200) begin
                @(posedge clk);
                idle = (up_valid || dut.bus_u.xfifo_level != 0
                        || dut.sched_u.pstate != 0
                        || dut.sched_u.rq_cnt != 0
                        || dut.yacc_u.commit_busy) ? 0 : idle + 1;
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
        // expected sticky errors after the injections: RPGM(bit17) +
        // CMD_ILLEGAL(bit2) set, every other bit clear
        if (dut.sched_u.err_q[17] !== 1'b1 || dut.sched_u.err_q[2] !== 1'b1
            || (dut.sched_u.err_q & ~(22'h2_0000 | 22'h4)) !== 22'h0) begin
            $display("FAIL err_status=%06x", dut.sched_u.err_q);
            errors++;
        end
        if (errors == 0)
            $display("PASS tile flits=%0d beats=%0d sync1=%0d",
                     flits, beats, sync1_count);
        else
            $display("FAIL tile errors=%0d flits=%0d beats=%0d",
                     errors, flits, beats);
        $finish;
    end
endmodule

