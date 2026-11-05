// y accumulation engine: 2 x 20,480 B y banks (256 b rows of 8 FP32,
// 640 rows = 64 token slots x 10 rows covering 80 columns), V[2][64] bitmaps,
// an 80 x 4 FP32 D commit buffer, and the DRAIN read engine.
// Commit (P3-11): the scheduler loads the final 80 x R values at D DONE and
// triggers one commit; the engine performs one 8-word row read-modify-write
// per (lane,row): t = bf16(w * d) (WPLACE=h, VACC_FP32=0, no bias), then
// y_new = vsnap ? fp32(y_old + t) : fp32(+0.0 + t), overlapping the next
// phase. Rows of one commit never overlap; the next D DONE waits for
// commit_busy=0. Same-bank commit reads have priority over DRAIN reads,
// which yield one cycle (CNT_Y_YIELD at the top).
module pe4_yacc (
    input  logic clk, rst_n,
    input  logic load_valid,
    input  logic [6:0] load_base,          // column base 0..79 (any alignment)
    input  logic [7:0] load_cen,           // per-column enables (formats < 8 cols)
    input  logic [1023:0] load_data,       // (col*4+lane) x FP32
    input  logic commit_trigger,
    input  logic commit_bank,
    input  logic commit_bias_en,          // CMD first && CTX BIAS_EN
    input  logic [1279:0] commit_db,      // 80 x BF16 down bias
    input  logic [3:0] commit_mask,
    input  logic [5:0] commit_slots [0:3],
    input  logic [31:0] commit_weights [0:3],
    output logic commit_busy,
    output logic commit_rd_active,         // same-bank DRAIN yield hint
    output logic commit_bank_id,
    input  logic drain_valid,
    input  logic drain_bank,
    input  logic [5:0] drain_slot,
    input  logic [7:0] drain_col_start,
    input  logic [7:0] drain_count,
    input  logic [1:0] drain_segment,
    input  logic drain_last_seg,
    output logic drain_illegal,
    output logic v0_drain,
    output logic yb_valid,
    input  logic yb_ready,
    output logic [127:0] yb_payload,
    output logic yb_last,
    output logic [1:0] yb_segment,
    output logic [7:0] yb_tag
);
    import pe4_pkg::*;
    logic [255:0] yq0, yq1;
    logic we0, we1, re0, re1;
    logic [9:0] waddr0, waddr1, raddr0, raddr1;
    logic [255:0] wdata0, wdata1;
    logic rv0, rv1;
    pe4_sram #(.WIDTH(256), .DEPTH(640), .LAT(2)) ybank0 (
        .clk(clk), .we(we0), .wbe('1), .waddr(waddr0), .wdata(wdata0),
        .re(re0), .raddr(raddr0), .rdata(yq0), .rvalid(rv0));
    pe4_sram #(.WIDTH(256), .DEPTH(640), .LAT(2)) ybank1 (
        .clk(clk), .we(we1), .wbe('1), .waddr(waddr1), .wdata(wdata1),
        .re(re1), .raddr(raddr1), .rdata(yq1), .rvalid(rv1));
    logic [31:0] dbuf [0:79][0:3];
    logic vbit [0:1][0:63];
    typedef enum logic [1:0] {CIDLE, CRD, CWT, CDONE} cstate_t;
    cstate_t cstate;
    logic cbank;
    logic [3:0] cmask, cmask_left;
    logic [5:0] cslots [0:3];
    logic [31:0] cweights [0:3];
    logic [3:0] csnap;
    logic [1:0] lane_sel;
    logic [3:0] row_sel;
    logic [2:0] crd_cnt;
    logic [255:0] y_old_r;
    logic [31:0] mul_a [0:7], mul_b [0:7], mul_r [0:7];
    logic [7:0] mul_v;
    logic [31:0] addb_left [0:7], addb_right [0:7], addb_r [0:7];
    logic [7:0] addb_v, addb_vo;
    logic [31:0] add_left [0:7], add_right [0:7], add_r [0:7];
    logic [7:0] add_v, add_vo;
    logic [255:0] new_row_c;
    logic bias_lat;
    logic [1279:0] db_lat;
    // single-writer V bitmap interface (R4-030)
    logic v_set_req, v_clr_req;
    logic v_set_bank, v_clr_bank;
    logic [5:0] v_set_slot, v_clr_slot;
    for (genvar c = 0; c < 8; c++) begin : rowmath
        pe4_fmul fm (.clk(clk), .rst_n(rst_n), .in_valid(mul_v[c]),
            .a(mul_a[c]), .b(mul_b[c]), .out_valid(), .result(mul_r[c]));
        pe3_add ab (.clk(clk), .rst_n(rst_n), .in_valid(addb_v[c]),
            .bypass(1'b0), .left_value(addb_left[c]),
            .right_value(addb_right[c]),
            .out_valid(addb_vo[c]), .result(addb_r[c]), .commit_value());
        pe3_add ay (.clk(clk), .rst_n(rst_n), .in_valid(add_v[c]),
            .bypass(1'b0), .left_value(add_left[c]),
            .right_value(add_right[c]),
            .out_valid(add_vo[c]), .result(add_r[c]), .commit_value());
    end
    logic [5:0] cur_slot;
    assign cur_slot = cslots[lane_sel];
    assign commit_busy = (cstate != CIDLE);
    assign commit_rd_active = (cstate == CRD);
    assign commit_bank_id = cbank;
    // shared y-bank port arbitration: commit reads have priority on their
    // bank; a DRAIN read on the same bank yields (yield_stall below)
    logic cre, dre;
    logic [9:0] craddr, draddr;
    // declared here (before first use): DC Presto requires declaration
    // before use; these were previously declared further down (VER-956)
    logic dbank_q;   // registered drain bank for the shared read-port mux
    logic dbank;     // current DRAIN bank (set by the DRAIN FSM below)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            re0 <= 0; re1 <= 0; raddr0 <= 0; raddr1 <= 0;
        end else begin
            re0 <= (cre && !cbank) || (dre && !dbank_q);
            re1 <= (cre && cbank) || (dre && dbank_q);
            raddr0 <= (cre && !cbank) ? craddr : draddr;
            raddr1 <= (cre && cbank) ? craddr : draddr;
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin dbank_q <= 0; end
        else dbank_q <= dbank;
    end
    always_comb begin
        for (int c = 0; c < 8; c++) begin
            mul_a[c] = cweights[lane_sel];
            mul_b[c] = {bias_lat ? db_lat[16*(8*row_sel + c) +: 16]
                                 : 16'h0000, 16'b0};
            addb_left[c] = dbuf[8*row_sel + c][lane_sel];
            addb_right[c] = mul_r[c];
            add_left[c] = csnap[lane_sel] ? y_old_r[32*c +: 32] : 32'h00000000;
            add_right[c] = {fp32_to_bf16(addb_r[c]), 16'b0};
            new_row_c[32*c +: 32] = add_r[c];
        end
    end
    // ---- commit RMW sequencer: one row at a time; write after all adds ----
    // CRD cycle t0 asserts re (sram sees it in t1, row data valid t3) and
    // mul_v (fmul results valid t5). y_old_r captured during t3; adds fire
    // in t5; the write follows the add out_valid pulse.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cstate <= CIDLE;
            cbank <= 0; cmask <= 0; cmask_left <= 0; csnap <= 0;
            lane_sel <= 0; row_sel <= 0; crd_cnt <= 0;
            we0 <= 0; we1 <= 0;        // re0/re1/raddr0/raddr1 are owned by
            waddr0 <= 0; waddr1 <= 0;  // the read-port arbitration block above
            wdata0 <= 0; wdata1 <= 0;
            y_old_r <= 0; mul_v <= 0; add_v <= 0;
            cre <= 0; craddr <= 0;
            v_set_req <= 0;   // v_clr_req is owned by the DRAIN engine below
            for (int c = 0; c < 80; c++)
                for (int l = 0; l < 4; l++) dbuf[c][l] <= 0;
        end else begin
            we0 <= 0; we1 <= 0; cre <= 0;
            mul_v <= 0; add_v <= 0; addb_v <= 0;
            v_set_req <= 0;
            // NOTE: bias_lat/db_lat are latched ONLY at commit_trigger and
            // must persist through the whole RMW (R4-018); no per-cycle clear
            if (load_valid)
                for (int c = 0; c < 8; c++)
                    if (load_cen[c] && load_base + c < 80)
                        for (int l = 0; l < 4; l++)
                            dbuf[load_base + c][l] <= load_data[(c*4+l)*32 +: 32];
            case (cstate)
                CIDLE: if (commit_trigger) begin
                    cbank <= commit_bank;
                    cmask <= commit_mask;
                    cmask_left <= commit_mask;
                    bias_lat <= commit_bias_en;
                    db_lat <= commit_db;
                    for (int l = 0; l < 4; l++) begin
                        cslots[l] <= commit_slots[l];
                        cweights[l] <= commit_weights[l];
                        csnap[l] <= commit_mask[l] &&
                            vbit[commit_bank][commit_slots[l]];
                    end
                    lane_sel <= 0;
                    row_sel <= 0;
                    cstate <= CRD;
                end
                CRD: if (cmask_left[lane_sel]) begin
                    cre <= 1;
                    craddr <= 10'(10 * int'(cur_slot) + int'(row_sel));
                    mul_v <= 8'hff;
                    crd_cnt <= 0;
                    cstate <= CWT;
                end else begin
                    if (lane_sel == 3) cstate <= CDONE;
                    else lane_sel <= lane_sel + 1;
                    row_sel <= 0;
                end
                CWT: begin
                    if (crd_cnt != 3'd7) crd_cnt <= crd_cnt + 1;
                    if (crd_cnt == 3'd3) y_old_r <= cbank ? yq1 : yq0;
                    // chain: mul(w*b) fired at CRD (results at cnt==4) ->
                    // addb(d+wb) -> bf16 cast t -> addy(y_old or +0.0 + t)
                    if (crd_cnt == 3'd4) addb_v <= 8'hff;
                    if (|addb_vo) add_v <= 8'hff;
                    if (|add_vo) begin
                        if (cbank) begin
                            we1 <= 1;
                            waddr1 <= 10'(10 * int'(cur_slot) +
                                          int'(row_sel));
                            wdata1 <= new_row_c;
                        end else begin
                            we0 <= 1;
                            waddr0 <= 10'(10 * int'(cur_slot) +
                                          int'(row_sel));
                            wdata0 <= new_row_c;
                        end
                        if (row_sel == 9) begin
                            v_set_req <= 1;
                            v_set_bank <= cbank;
                            v_set_slot <= cur_slot;
                            row_sel <= 0;
                            cmask_left[lane_sel] <= 0;
                            if (lane_sel == 3) cstate <= CDONE;
                            else begin lane_sel <= lane_sel + 1; cstate <= CRD; end
                        end else begin
                            row_sel <= row_sel + 1;
                            cstate <= CRD;
                        end
                    end
                end
                CDONE: begin
                    cstate <= CIDLE;
                end
            endcase
        end
    end
    // ---- DRAIN read engine ----
    typedef enum logic [1:0] {DIDLE, DWAIT, DSEND, DV0} dstate_t;
    dstate_t dstate;
    logic [5:0] dslot;
    logic [7:0] dstart, dcount;
    logic [1:0] dseg;
    logic dlastseg, dv0;
    logic [6:0] drow, drow_last;
    logic [2:0] dwait_cnt;
    logic [127:0] dphit;
    logic yield_stall;
    logic row_is_last;
    assign row_is_last = (drow == drow_last);
    assign yield_stall = (dstate == DWAIT) && commit_rd_active &&
                         (commit_bank_id == dbank);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dstate <= DIDLE;
            dbank <= 0; dslot <= 0; dstart <= 0; dcount <= 0;
            dseg <= 0; dlastseg <= 0; dv0 <= 0;
            drow <= 0; drow_last <= 0; dwait_cnt <= 0;
            drain_illegal <= 0; v0_drain <= 0;
            yb_valid <= 0; yb_payload <= 0; yb_last <= 0;
            yb_segment <= 0; yb_tag <= 0;
            dre <= 0; draddr <= 0;
            v_clr_req <= 0;   // single owner: also reset here (ELAB-366 fix)
        end else begin
            drain_illegal <= 0; v0_drain <= 0;
            dre <= 0;                    // drain read is a 1-cycle pulse (R4-019)
            v_clr_req <= 0;
            case (dstate)
                DIDLE: if (drain_valid) begin
                    if (drain_count == 0 || drain_col_start + drain_count > 80) begin
                        drain_illegal <= 1;
                    end else begin
                        dbank <= drain_bank;
                        dslot <= drain_slot;
                        dstart <= drain_col_start;
                        dcount <= drain_count;
                        dseg <= drain_segment;
                        dlastseg <= drain_last_seg;
                        dv0 <= ~vbit[drain_bank][drain_slot];
                        if (!vbit[drain_bank][drain_slot]) v0_drain <= 1;
                        drow <= drain_col_start[6:0] >> 3;
                        drow_last <= (drain_col_start + drain_count - 1) >> 3;
                        dwait_cnt <= 0;
                        dstate <= vbit[drain_bank][drain_slot] ? DWAIT : DV0;
                    end
                end
                DWAIT: if (!yield_stall) begin
                    if (dwait_cnt == 0) begin
                        dre <= 1;
                        draddr <= 10'(10 * int'(dslot) + int'(drow));
                        dwait_cnt <= 1;
                    end else if (dwait_cnt < 4) begin
                        dwait_cnt <= dwait_cnt + 1;
                    end else begin
                        // sram rdata valid in this cycle: build the phit
                        for (int c = 0; c < 8; c++) begin
                            logic [7:0] col;
                            col = {drow, 3'(c)};
                            if (col >= dstart && col < dstart + dcount)
                                dphit[16*c +: 16] <= fp32_to_bf16(
                                    dbank ? yq1[32*c +: 32] : yq0[32*c +: 32]);
                            else dphit[16*c +: 16] <= 16'h0000;
                        end
                        dstate <= DSEND;
                    end
                end
                DSEND: begin
                    if (!yb_valid) begin
                    yb_valid <= 1;
                    yb_payload <= dphit;
                    yb_last <= row_is_last;
                    yb_segment <= dseg;
                    yb_tag <= {dbank, dslot, 1'b0};
                    end
                    if (yb_valid && yb_ready) begin
                        yb_valid <= 0;
                        if (row_is_last) begin
                            if (dlastseg && !dv0) begin
                v_clr_req <= 1;
                v_clr_bank <= dbank;
                v_clr_slot <= dslot;
            end
                            dstate <= DIDLE;
                        end else begin
                            drow <= drow + 1;
                            dwait_cnt <= 0;
                            dstate <= DWAIT;
                        end
                    end
                end
                DV0: begin
                    // never-written slot: zero payload beats, no SRAM reads
                    if (!yb_valid) begin
                    yb_valid <= 1;
                    yb_payload <= 128'h0;
                    yb_last <= row_is_last;
                    yb_segment <= dseg;
                    yb_tag <= {dbank, dslot, 1'b0};
                    end
                    if (yb_valid && yb_ready) begin
                        yb_valid <= 0;
                        if (row_is_last) dstate <= DIDLE;
                        else drow <= drow + 1;
                    end
                end
            endcase
        end
    end
    // vbit has exactly ONE always_ff writer; the two FSMs submit requests
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int b = 0; b < 2; b++)
                for (int s = 0; s < 64; s++) vbit[b][s] <= 0;
        end else begin
            if (v_set_req) vbit[v_set_bank][v_set_slot] <= 1'b1;
            if (v_clr_req) vbit[v_clr_bank][v_clr_slot] <= 1'b0;
        end
    end
endmodule


