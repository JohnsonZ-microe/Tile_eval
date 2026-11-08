`timescale 1ns/1ps
module tb_memory_v4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic wr_valid = 0, wr_bank = 0, wr_err;
    logic [2:0] wr_lane = 0;
    logic [6:0] wr_idx = 0;
    logic [255:0] wr_q = 0;
    logic [7:0] wr_se = 127;
    logic rd_req = 0, rd_bank = 0, rd_valid;
    logic [6:0] rd_idx = 0;
    logic [1023:0] rd_data;
    logic [31:0] rd_scales;
    logic own_take = 0, own_release = 0, own_bank = 0;
    logic [7:0] own_pass = 0;
    logic [2:0] own_ntok = 1;
    logic [1:0] owner_valid, bank_ready;
    logic [7:0] owner_pass0, owner_pass1;
    pe4_hbuf hbuf(.*);
    logic mem_we = 0, mem_re = 0;
    logic [2:0] mem_addr = 0;
    logic [31:0] mem_data = 0, data2, data3;
    logic valid2, valid3;
    pe4_sram #(.WIDTH(32), .DEPTH(8), .LAT(2)) sram2(
        .clk(clk), .we(mem_we), .wbe(4'hf), .waddr(mem_addr), .wdata(mem_data),
        .re(mem_re), .raddr(mem_addr), .rdata(data2), .rvalid(valid2));
    pe4_sram #(.WIDTH(32), .DEPTH(8), .LAT(3)) sram3(
        .clk(clk), .we(mem_we), .wbe(4'hf), .waddr(mem_addr), .wdata(mem_data),
        .re(mem_re), .raddr(mem_addr), .rdata(data3), .rvalid(valid3));
    logic rreq = 0, rready, rvalid, rload = 0, ractive = 0, rerr;
    logic [20:0] raddr = 0, load_addr = 0;
    logic [1023:0] rdata, load_data = 0;
    pe4_rram #(.WORDS(16)) rram(.clk(clk), .rst_n(rst_n),
        .run_active(ractive), .rd_req(rreq), .rd_ready(rready), .rd_addr(raddr),
        .rd_valid(rvalid), .rd_data(rdata), .sim_load(rload),
        .sim_addr(load_addr), .sim_data(load_data), .load_err(rerr));
    integer cycle = 0, checked = 0, accepted = 0, returned = 0;
    logic sx = 0, ss = 0, sr = 0, sv;
    logic [2:0] slane = 0;
    logic [9:0] sidx = 0;
    logic [7:0] skb = 0;
    logic [511:0] swdata = 0;
    logic [1023:0] sxdata;
    logic [31:0] ssdata;
    bit sev[0:8191];
    integer sekb[0:8191];
    pe4_staging staging(.clk(clk), .rst_n(rst_n), .wr_x(sx), .wr_xs(ss),
        .wr_lane(slane), .wr_idx(sidx), .wr_data(swdata), .rd_req(sr),
        .rd_kb(skb), .x_data(sxdata), .xs_data(ssdata), .rd_valid(sv));
    bit ev2[0:8191], ev3[0:8191], erv[0:8191];
    logic [31:0] ed2[0:8191], ed3[0:8191];
    logic [1023:0] erd[0:8191];
    task automatic tick;
        #1;
        if (sr) begin sev[cycle+2] = 1; sekb[cycle+2] = skb; end
        if (mem_re) begin
            ev2[cycle+2] = 1; ed2[cycle+2] = 32'hdead0000 + mem_addr;
            ev3[cycle+3] = 1; ed3[cycle+3] = 32'hdead0000 + mem_addr;
        end
        if (rreq && rready && rst_n) begin
            erv[cycle+3] = 1; erd[cycle+3] = 1024'h12340000 + raddr;
            accepted++;
        end
        @(posedge clk); #1; cycle++;
        if (cycle >= 8190) $fatal(1, "memory watchdog");
        if (cycle > 4) begin
            if (sv !== sev[cycle]) $fatal(1, "staging return edge");
            if (sv) begin
                for (integer lane = 0; lane < 4; lane++) begin
                    if (ssdata[8*lane +: 8] !==
                        8'(((sekb[cycle] >> 6)&1)*64 + lane*8 + (sekb[cycle]&63)))
                        $fatal(1, "XS lane/index alignment");
                    for (integer element = 0; element < 32; element++)
                        if (sxdata[256*lane+8*element +: 8] !==
                            8'(((sekb[cycle] >> 1)&1)*64 + lane*8 +
                               (sekb[cycle]&1)*32 + element))
                            $fatal(1, "X lane/half alignment");
                end
            end
            if (valid2 !== ev2[cycle] || valid3 !== ev3[cycle])
                $fatal(1, "SRAM return edge cycle=%0d", cycle);
            if (valid2 && data2 !== ed2[cycle]) $fatal(1, "SRAM2 data");
            if (valid3 && data3 !== ed3[cycle]) $fatal(1, "SRAM3 data");
            if (rvalid !== erv[cycle]) $fatal(1, "RRAM return edge cycle=%0d", cycle);
            if (rvalid) begin
                if (rdata !== erd[cycle]) $fatal(1, "RRAM data");
                returned++;
            end
        end
        @(negedge clk);
    endtask
    function automatic logic [255:0] row_word(input integer bank, row, lane);
        return {8{32'(bank*10000 + row*4 + lane + 1)}};
    endfunction
    task automatic read_row(input integer bank, row, lanes);
        rd_bank = 1'(bank); rd_idx = 7'(row); rd_req = 1;
        tick();
        if (rd_valid !== 0) $fatal(1, "hbuf early return");
        rd_req = 0;
        tick();
        if (rd_valid !== 1) $fatal(1, "hbuf missing return");
        for (integer lane = 0; lane < lanes; lane++)
            if (rd_data[256*lane +: 256] !== row_word(bank,row,lane) ||
                rd_scales[8*lane +: 8] !== 8'(120+lane))
                $fatal(1, "hbuf data changed bank=%0d row=%0d lane=%0d", bank,row,lane);
        checked++;
        tick();
    endtask
    initial begin
        @(negedge clk);
        repeat (4) tick();
        rst_n = 1;
        for (integer bank = 0; bank < 2; bank++)
            for (integer lane = 0; lane < 4; lane++) begin
                sx = 1; ss = 1; sidx = 10'(bank); slane = 3'(lane);
                for (integer element = 0; element < 64; element++)
                    swdata[8*element +: 8] = 8'(bank*64 + lane*8 + element);
                tick();
            end
        sx = 0; ss = 0;
        for (integer block_id = 0; block_id < 160; block_id++) begin
            sr = 1; skb = 8'(block_id); tick();
        end
        sr = 0; repeat (3) tick();
        for (integer index = 0; index < 16; index++) begin
            rload = 1; load_addr = 21'(index); load_data = 1024'h12340000 + index;
            if (index < 8) begin
                mem_we = 1; mem_addr = 3'(index); mem_data = 32'hdead0000 + index;
            end else mem_we = 0;
            tick();
        end
        rload = 0; mem_we = 0; ractive = 1;
        for (integer index = 0; index < 200; index++) begin
            rreq = index % 5 != 0; raddr = 21'(index % 16);
            mem_re = index % 3 != 0; mem_addr = 3'(index % 8);
            tick();
        end
        rreq = 0; mem_re = 0; rload = 1; load_addr = 0; load_data = '1;
        tick();
        if (rerr !== 1) $fatal(1, "RRAM active load not rejected");
        rload = 0; rreq = 1; raddr = 0;
        tick(); rreq = 0;
        repeat (4) tick();
        if (accepted != returned || accepted < 100) $fatal(1, "RRAM lost returns");
        for (integer lanes = 1; lanes <= 4; lanes++) begin
            for (integer bank = 0; bank < 2; bank++) begin
                own_take = 1; own_bank = 1'(bank); own_pass = 8'(lanes);
                own_ntok = 3'(lanes); tick(); own_take = 0;
                if (owner_valid[bank] !== 1) $fatal(1, "h ownership not taken");
                for (integer row = 0; row < 72; row++) begin
                    for (integer lane = 0; lane < lanes; lane++) begin
                        wr_valid = 1; wr_bank = 1'(bank); wr_lane = 3'(lane);
                        wr_idx = 7'(row); wr_q = row_word(bank,row,lane);
                        wr_se = 8'(120+lane); tick();
                        if (wr_err !== 0) $fatal(1, "legal h write rejected");
                    end
                end
                wr_valid = 0;
                if (bank_ready[bank] !== 1) $fatal(1, "h full fence");
                read_row(bank,0,lanes);
                read_row(bank,71,lanes);
                wr_valid = 1; wr_bank = 1'(bank); wr_lane = 0; wr_idx = 0;
                wr_q = '1; tick();
                if (wr_err !== 1) $fatal(1, "duplicate write accepted");
                wr_idx = 72; tick();
                if (wr_err !== 1) $fatal(1, "out-of-range row accepted");
                wr_idx = 0; wr_lane = 7; tick();
                if (wr_err !== 1) $fatal(1, "out-of-range lane accepted");
                wr_valid = 0; read_row(bank,0,lanes);
                own_release = 1; tick(); own_release = 0;
                wr_valid = 1; wr_lane = 0; tick();
                if (wr_err !== 1) $fatal(1, "unowned write accepted");
                wr_valid = 0; read_row(bank,0,lanes);
            end
        end
        rst_n = 0; tick();
        if (owner_valid !== 0 || bank_ready !== 0) $fatal(1, "ownership reset");
        $display("PASS memory rows=%0d rram=%0d", checked, returned);
        $finish;
    end
endmodule
