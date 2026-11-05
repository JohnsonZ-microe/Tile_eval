// Rev4 phase scheduler: CMD slots, CTX validation, RRAM word-stream issue
// (3-credit prefetch, tagged returns), weight-scale hold registers with
// 128-k retention, operand staging control with X_ORDER checking, PE
// request assembly (frozen rev3 tile_pe_v3 with its 36-stage pipeline and
// conservative RF occupancy), GU snapshot capture, SwiGLU launch and H_UP
// staging, D admission via the h-bank fence, D epilogue capture into the
// y commit buffer, phase DONE sync[1], and the tile register file.
// Overlap model (docs/SPEC.md 7): one phase owns the PE at a time; the next
// phase's RRAM prefetch, H quantization and y commit overlap its drain.
module pe4_sched (
    input  logic clk, rst_n,
    // bus side
    input  logic cmd_in_valid,
    input  logic [511:0] cmd_in_payload,
    input  logic [7:0] cmd_in_pass,
    output logic [1:0] err_pulse,           // {bit index valid, index>=8?}: see err_set
    output logic [4:0] err_idx,             // one-hot error event (see below)
    // X/XS FIFO interface
    input  logic xfifo_empty,
    input  logic xfifo_out_kind,
    input  logic [2:0] xfifo_out_lane,
    input  logic [9:0] xfifo_out_idx,
    input  logic [511:0] xfifo_out_data,
    input  logic [7:0] xfifo_out_pass,
    output logic xfifo_pop,
    // H flit interface (from bus)
    input  logic h_valid,
    input  logic [2:0] h_lane,
    input  logic [9:0] h_idx,
    input  logic [7:0] h_pass,
    input  logic [511:0] h_data,
    // RRAM
    output logic rram_req,
    input  logic rram_ready,
    output logic [20:0] rram_addr,
    input  logic rram_valid,
    input  logic [1023:0] rram_data,
    output logic run_active,
    // staging
    output logic stg_wr_x, stg_wr_xs,
    output logic [2:0] stg_wr_lane,
    output logic [9:0] stg_wr_idx,
    output logic [511:0] stg_wr_data,
    output logic stg_rd_req,
    output logic [7:0] stg_rd_kb,
    input  logic [1023:0] stg_x_data,
    input  logic [31:0] stg_xs_data,
    input  logic stg_rd_valid,
    // h buffer
    output logic hbuf_wr_valid,
    output logic hbuf_wr_bank,
    output logic [2:0] hbuf_wr_lane,
    output logic [6:0] hbuf_wr_idx,
    output logic [255:0] hbuf_wr_q,
    output logic [7:0] hbuf_wr_se,
    input  logic hbuf_wr_err,
    output logic hbuf_rd_req,
    output logic hbuf_rd_bank,
    output logic [6:0] hbuf_rd_idx,
    input  logic [1023:0] hbuf_rd_data,
    input  logic [31:0] hbuf_rd_scales,
    input  logic hbuf_rd_valid,
    output logic hbuf_take, hbuf_release, hbuf_bank,
    output logic [7:0] hbuf_pass,
    output logic [2:0] hbuf_ntok,   // token count 1..4; was [7:0] (LINK-3)
    input  logic [1:0] hbuf_owner_valid,
    input  logic [1:0] hbuf_bank_ready,
    input  logic [7:0] hbuf_owner_pass0,
    input  logic [7:0] hbuf_owner_pass1,
    // PE (frozen rev3)
    output logic pe_in_valid,
    input  logic pe_in_ready,
    output logic [2:0] pe_wfmt,
    output logic [1023:0] pe_weights, pe_acts,
    output logic [31:0] pe_ascales,
    output logic [255:0] pe_wscales,
    output logic [3:0] pe_mask,
    output logic [6:0] pe_col_base,
    output logic pe_first, pe_last,
    output logic [31:0] pe_tag,
    input  logic pe_out_valid,
    input  logic [1023:0] pe_out_results,
    input  logic [6:0] pe_out_col_base,
    // activation + H_UP packet
    output logic act_in_valid,
    output logic [31:0] act_g [0:3],
    output logic [31:0] act_u [0:3],
    output logic [31:0] act_w [0:3],
    output logic [15:0] act_gb,           // per-column gate bias (BF16)
    output logic [15:0] act_ub,           // per-column up bias (BF16)
    input  logic act_out_valid,
    input  logic [15:0] act_h [0:3],
    output logic hup_valid,
    input  logic hup_ready,
    output logic [127:0] hup_payload,
    output logic hup_last,
    output logic [7:0] hup_tag,
    // y engine
    output logic yacc_load_valid,
    output logic [7:0] yacc_load_cen,       // 8 column enables (R4-018)
    output logic [6:0] yacc_load_base,
    output logic [1023:0] yacc_load_data,
    output logic yacc_commit_trigger,
    output logic yacc_bank,
    output logic yacc_bias_en,            // slot0 BIAS_EN && first_v
    output logic [1279:0] yacc_db,        // 80 x BF16 down bias
    output logic [3:0] yacc_mask,
    output logic [5:0] yacc_slots [0:3],
    output logic [31:0] yacc_weights [0:3],
    input  logic yacc_busy,
    // CTRL register interface
    input  logic reg_wr_valid,
    input  logic [11:0] reg_wr_addr,
    input  logic [31:0] reg_wr_data,
    input  logic reg_rd_valid,
    input  logic [11:0] reg_rd_addr,
    output logic [31:0] reg_rd_data,
    output logic reg_rd_ack,
    input  logic [21:0] err_extra,          // error events from bus/yacc/top
    input  logic cnt_clear,                 // CTRL op 3
    input  logic ctrl_seen,                 // any CTRL flit observed
    // ALARM (STATUS subtype 0xF3, data_bus 6.3 P3-6): one packet when the
    // masked ERR_STATUS leaves zero; rearmed only after W1C clears it
    output logic [21:0] alarm_mask,
    output logic alarm_valid,
    input  logic alarm_ready,
    output logic [127:0] alarm_payload,
    // status/outputs
    input  logic up_beat, up_crd_stall, y_yield,
    output logic sync1,
    output logic run_active_any,
    output logic [21:0] err_status,
    output logic [7:0] tile_status_level,
    output logic [21:0] err_events          // per-cycle OR of new error bits
);
    import pe4_pkg::*;
    // (moved up from near the end of this file: used by the CTRL readback
    //  mux above its old position — VER-956; note: run.py's sanity scan
    //  counts RTL keywords even inside comments, so avoid them here)
    localparam logic [31:0] TILE_ID_P = 32'h0000_0110;  // ID 16, RRAM_LAT 1
    // ============================ CTX storage ============================
    // Class record: W0={H[15:0],H_KB[31:16]}, W1={H_COLS[15:0],I_V[31:16]},
    // W2=fmt fields (WFMT[2:0],SFMT[4:3],SBLK_128[5],BIAS_EN[6],WPLACE[7],
    // VACC_FP32[8]), W3={VSPLIT[15:0],N_LOCAL[31:16]}, W4..W7 addresses,
    // W8..W15 activation parameters; mode word {EP_PARTIAL[0],PARTIAL_Y_FMT[1]}
    logic [31:0] ctx_word [0:1][0:15];
    logic [31:0] ctx_mode [0:1];
    typedef struct packed {
        logic [2:0] fmt;
        logic sblk128;
        logic [16:0] nkb;
        logic [5:0] ngroups;
        logic [3:0] ncols;      // 4 bits: must hold 8 (fp4/int4) - R4-004
        logic [3:0] sw;
        logic [2:0] period;
        logic [15:0] gu_words;
        logic [15:0] d_words;
        logic bias_en;
        logic [1:0] bias_first_d;   // first tail word the D phase rereads
        logic legal;
    } classp_t;
    // NOTE: 'const ref' args are not supported by DC Presto (VER-294);
    // pass the array by value instead (function only reads it).
    function automatic classp_t resolve_class(input logic [31:0] w [0:15],
        input logic [31:0] mode);
        classp_t r;
        int nc, nkb, swd, per, guw, dwv;
        r = '0;
        r.fmt = w[2][2:0];
        r.sblk128 = w[2][5];
        r.bias_en = w[2][6];
        nc = ncols_of(r.fmt);
        r.ncols = 4'(nc);
        nkb = int'(w[0][15:0]) / 32;                       // H / 32
        r.nkb = 17'(nkb);
        r.ngroups = 6'((COLS_GU + nc - 1) / nc);
        per = (r.fmt == 2 || r.fmt == 3) ? 4 : 1;
        r.period = 3'(per);
        swd = (r.fmt == 5) ? 0 :
              (r.fmt == 0 || r.fmt == 1) ? (COLS_GU*8 + 1023) / 1024 :
              (r.fmt == 2) ? (COLS_GU*32 + 1023) / 1024 : (COLS_GU*16 + 1023) / 1024;
        r.sw = 4'(swd);
        guw = ((nkb + per - 1) / per) * swd + nkb * int'(r.ngroups);
        dwv = ((NKB_D + per - 1) / per) * swd + NKB_D * ((COLS_D + nc - 1) / nc);
        r.gu_words = 16'(guw);
        r.d_words = 16'(dwv);
        // bias tail (data_bus 4.6): 3 stored words of 64 BF16 entries;
        // GU covers bytes [0,144) -> words 0..1, D rereads word 1 (the
        // boundary word) and reads word 2 for bytes [144,304)
        r.bias_first_d = 2'd1;
        // rev4 validation (docs/SPEC.md 4): V4.1 geometry, VSPLIT=1,
        // BIAS_EN optional, WPLACE=h, VACC_FP32=0, BF16 Y, matched
        // SFMT/SBLK, V4.1 ACT preset
        r.legal = (w[0][15:0] == 16'(K_GU)) && (w[0][31:16] == 16'(NKB_GU)) &&
                  (w[1][15:0] == 16'(H_COLS)) && (w[1][31:16] == 16'(K_D)) &&
                  (w[3][15:0] == 16'd1) &&
                  (w[2][7] == 1'b0) && (w[2][8] == 1'b0) &&
                  (mode[0] == 1'b0) && (mode[1] == 1'b0) &&
                  (r.sblk128 == (r.fmt == 2 || r.fmt == 3));
        if (r.fmt == 5) r.legal = r.legal && w[2][4:3] == 2'd3;
        else if (r.fmt == 2) r.legal = r.legal && w[2][4:3] == 2'd2;
        else if (r.fmt == 3 || r.fmt == 4) r.legal = r.legal && w[2][4:3] == 2'd1;
        else r.legal = r.legal && w[2][4:3] == 2'd0;
        for (int k = 0; k < 8; k++)
            if (w[8+k] != V41_ACT[k]) r.legal = 1'b0;
        return r;
    endfunction
    classp_t cp [0:1];
    always_comb begin
        for (int c = 0; c < 2; c++) cp[c] = resolve_class(ctx_word[c], ctx_mode[c]);
    end
    // ======================= CMD slots and issue state ===================
    cmd_t slot [0:1];
    typedef struct packed {
        logic valid;
        logic [16:0] kb;
        logic [5:0] g;
        logic scale;
        logic [3:0] swi;
        logic [16:0] off;
        logic bias;         // reading the bias tail words first (4.6)
        logic [1:0] bidx;   // next tail word index (GU 0..1, D 1..2)
        logic [1:0] bleft;  // tail words still to read
        logic started;      // first word of this phase issued
    } iss_t;
    iss_t iss [0:1];
    logic [20:0] phase_base [0:1];
    logic [20:0] tail_base [0:1];
    // return queue: 4 entries carry per-word phase parameters (self-contained
    // consume; <=3 can be outstanding because of the RRAM credit budget)
    typedef struct packed {
        logic slot;
        logic phase;      // 0 GU, 1 D
        logic scale;
        logic bias;       // bias tail word (extraction at consume)
        logic [1:0] bidx; // tail word index of this return
        logic [3:0] swi;
        logic [7:0] kb;
        logic [5:0] g;
        logic [3:0] ncols;  // holds 8 (fp4/int4) - R4-004
        logic [5:0] ngroups;
        logic [7:0] nkb;
        logic [2:0] fmt;
        logic last_word;
        logic full;
        logic [1023:0] data;
    } rq_t;
    rq_t rq [0:3];
    // 2-bit wrap pointers for the 4-entry queue; rq_cnt saturates at 4
    logic [1:0] rq_push, rq_fill, rq_cons;
    logic [2:0] rq_cnt;
    logic cons_fire, cap_push;   // single-cycle pulses for R4-006 updates
    // capture FIFO (>= PE pipeline depth): dest 1 = GU snapshot, 2 = D commit
    logic [1:0] cap_q [0:63];
    logic [5:0] cap_head, cap_tail, cap_cnt;
    // weight-scale hold registers, per slot, 80 columns of 32 b
    logic [31:0] wsh [0:1][0:79];
    // bias contexts (data_bus 4.6): GU gate/up (36 each) + D down (80);
    // ownership is per phase, retired at the phase's epilogue use
    logic [15:0] bias_gb [0:35];
    logic [15:0] bias_ub [0:35];
    logic [15:0] bias_db [0:79];
    logic bias_gu_valid, bias_d_valid;
    logic ev_bias;
    logic pend_act, pend_commit;
    // operand holds: two banks keyed by kb parity
    logic [1023:0] hold_x [0:1];
    logic [31:0] hold_xs [0:1];
    logic hold_v [0:1];
    logic [1023:0] hold_h [0:1];
    logic [31:0] hold_hs [0:1];
    logic hold_hv [0:1];
    // staging pop progress per phase
    logic [79:0] x_popped;
    logic [2:0] xs_popped;
    // GU snapshot and ACT/H_UP
    logic [31:0] gu_snap [0:71][0:3];
    logic [15:0] hup_slot [0:143];
    typedef enum logic [2:0] {P_IDLE, P_RUN, P_ACT, P_ACTW, P_HUP, P_DCOMMIT} pstate_t;
    pstate_t pstate;
    logic [5:0] act_c, act_cout;
    logic [4:0] hup_beat, hup_beats;
    logic [31:0] last_hup_pass;
    // staging fill engine expected-order state
    logic [1:0] exp_grp;
    logic [2:0] exp_lane;
    logic [6:0] exp_idx;      // 0..31 within group
    // (moved up from the sections below: DC requires declaration before use,
    //  and these are read by the main always_ff further down — VER-956)
    logic [1:0] gu_slot;
    logic exp_kind;                 // 1 = XS phase, 0 = X phase
    logic [7:0] exp_pass;
    logic [6:0] exp_idx_full;
    logic [6:0] group_limit;
    logic [16:0] gu_iss_kb;
    logic quant_valid;
    logic [2:0] quant_lane;
    logic [6:0] quant_idx;
    logic [511:0] quant_h;
    logic hsel;
    logic quant_ov, quant_err;
    logic [255:0] quant_q;
    logic [7:0] quant_se;
    logic [10:0] quant_otag;
    logic [10:0] quant_unused;
    logic [7:0] stg_kb_q;
    logic [6:0] hbuf_kb_q;
    logic [7:0] stg_kb_qq;
    logic [6:0] hbuf_kb_qq;
    int ngroups1, sw1, per1;
    logic exp_xs_phase;
    // error and event bus (single-cycle pulses into the register file)
    logic ev_cmd_illegal, ev_unsupported, ev_xorder, ev_horder, ev_rramtag;
    logic ev_snapshot, ev_ctxbusy, ev_regaddr, ev_numeric, ev_hbank;
    // resolved active-phase helpers
    int ncols_i; logic [7:0] nkb_q; logic [5:0] ng_q;
    // ---- issue engine: slot 0 first; slot 1 may issue after slot 0 done ----
    logic iss_fire0, iss_fire1;
    logic [20:0] iss_addr;
    logic first_of_kb0, first_of_kb1;
    int ngroups0, sw0, per0;
    always_comb begin
        ngroups0 = (slot[0].phase == 0) ? int'(cp[slot[0].ctx_sel].ngroups)
            : (COLS_D + int'(cp[slot[0].ctx_sel].ncols) - 1)
              / int'(cp[slot[0].ctx_sel].ncols);
        sw0 = int'(cp[slot[0].ctx_sel].sw);
        per0 = int'(cp[slot[0].ctx_sel].period);
        first_of_kb0 = iss[0].scale ? (iss[0].swi == 0) : (iss[0].g == 0);
        first_of_kb1 = iss[1].scale ? (iss[1].swi == 0) : (iss[1].g == 0);
    end
    assign run_active_any = slot[0].valid || slot[1].valid;
    assign run_active = run_active_any;
    // operand readiness gate for the first word of each k-block
    logic opnd_ready0, opnd_ready1;
    always_comb begin
        if (slot[0].phase == 0)
            opnd_ready0 = x_popped[iss[0].kb[7:1]] && xs_popped[iss[0].kb[7:6]];
        else
            opnd_ready0 = hbuf_bank_ready[slot[0].hbank];
        if (slot[1].phase == 0)
            opnd_ready1 = x_popped[iss[1].kb[7:1]] && xs_popped[iss[1].kb[7:6]];
        else
            opnd_ready1 = hbuf_bank_ready[slot[1].hbank];
    end
    assign iss_fire0 = slot[0].valid && iss[0].valid && rram_ready &&
                       (iss[0].bias || (opnd_ready0 || !first_of_kb0)) &&
                       rq_cnt < 3'd4 &&
                       (iss[0].started || rq_cnt == 0);
    assign iss_fire1 = !iss[0].valid && slot[1].valid && iss[1].valid &&
                       rram_ready &&
                       (iss[1].bias || (opnd_ready1 || !first_of_kb1)) &&
                       rq_cnt < 3'd4 && (iss[1].started || rq_cnt == 0);
    assign rram_req = iss_fire0 || iss_fire1;
    assign rram_addr = iss_fire0 ?
        (iss[0].bias ? (tail_base[0] + {19'b0, iss[0].bidx})
                     : (phase_base[0] + iss[0].off)) :
        (iss[1].bias ? (tail_base[1] + {19'b0, iss[1].bidx})
                     : (phase_base[1] + iss[1].off));
    // ================= sequential core (part A: stream + epilogue) ========
    // consume-side combinational request assembly from the queue head
    rq_t head;
    assign head = rq[rq_cons[1:0]];
    wire head_ready = pe_in_valid;
    logic head_ready_unused;
    assign head_ready_unused = 1'b0;
    assign pe_in_valid = rq_cnt != 0 && head.full && !head.scale &&
        !head.bias &&
        ((head.phase == 0) ? hold_v[head.kb[0]] : hold_hv[head.kb[0]]);
    assign pe_wfmt = head.fmt;
    assign pe_weights = head.data;
    assign pe_acts = (head.phase == 0) ? hold_x[head.kb[0]] : hold_h[head.kb[0]];
    assign pe_ascales = (head.phase == 0) ? hold_xs[head.kb[0]] : hold_hs[head.kb[0]];
    always_comb begin
        pe_wscales = '0;
        for (int i = 0; i < 8; i++)
            if (i < int'(head.ncols))
                pe_wscales[32*i +: 32] = wsh[head.slot][head.g*head.ncols + i];
    end
    assign pe_mask = slot[head.slot].lane_mask;
    assign pe_col_base = 7'(head.g * head.ncols);
    assign pe_first = (head.kb == 0);
    assign pe_last = head.last_word;
    assign pe_tag = {slot[head.slot].pass_id, head.phase, head.kb, head.g, 4'b0};
    wire pe_accept = pe_in_valid && pe_in_ready;
    // bias consume condition (full head of bias kind, no PE involvement)
    wire head_ready_q = (rq_cnt != 0) && head.full && head.bias;
    // scale consume condition: in-order wsh update, no PE involvement
    wire head_scale_q = (rq_cnt != 0) && head.full && head.scale
        && !head.bias;
    assign cons_fire = head_ready_q || head_scale_q || pe_accept;
    assign cap_push = pe_accept;
    // staging / hbuf operand read issue: on the first MATRIX word of each
    // k-block (bias tail words trigger nothing)
    wire iss0_kb0 = iss_fire0 && first_of_kb0 && !iss[0].bias;
    wire iss1_kb0 = iss_fire1 && first_of_kb1 && !iss[1].bias;
    assign stg_rd_req = (slot[0].phase == 0 && iss0_kb0) ? 1'b1 :
                        (slot[1].phase == 0 && iss1_kb0) ? 1'b1 : 1'b0;
    assign stg_rd_kb = iss0_kb0 ? 8'(iss[0].kb) : 8'(iss[1].kb);
    assign hbuf_rd_req = (slot[0].phase == 1 && iss0_kb0) ? 1'b1 :
                         (slot[1].phase == 1 && iss1_kb0) ? 1'b1 : 1'b0;
    assign hbuf_rd_bank = iss0_kb0 ? slot[0].hbank : slot[1].hbank;
    assign hbuf_rd_idx = iss0_kb0 ? 7'(iss[0].kb) : 7'(iss[1].kb);
    // scale entry extraction at consume
    int wbits, eper, cols_ph;
    always_comb begin
        wbits = (head.fmt == 0 || head.fmt == 1) ? 8 : (head.fmt == 2) ? 32 : 16;
        eper = 1024 / wbits;
        cols_ph = (head.phase == 0) ? COLS_GU : COLS_D;
    end
    // ACT inputs
    assign act_in_valid = rst_n && (pstate == P_ACT);
    always_comb begin
        for (int t = 0; t < 4; t++) begin
            act_g[t] = gu_snap[act_c][t];
            act_u[t] = gu_snap[7'(act_c) + 7'd36][t];
            act_w[t] = slot[0].weights[t];
        end
    end
    // bias feeds: gb/ub for the streaming column (zero when disabled);
    // down-bias vector + enable for the y engine (latched at its trigger)
    assign act_gb = slot[0].bias_en ? bias_gb[act_c] : 16'h0000;
    assign act_ub = slot[0].bias_en ? bias_ub[act_c] : 16'h0000;
    assign yacc_bias_en = slot[0].valid && slot[0].bias_en;
    always_comb begin
        yacc_db = '0;
        for (int c = 0; c < 80; c++)
            yacc_db[16*c +: 16] = bias_db[c];
    end
    // H_UP payload from the slot
    always_comb begin
        hup_payload = '0;
        for (int e = 0; e < 8; e++)
            hup_payload[16*e +: 16] = hup_slot[8*hup_beat + e];
    end
    assign hup_last = (hup_beat == hup_beats - 1);
    assign hup_tag = last_hup_pass[7:0];
    // issue-side step helper: bias tail words first (data_bus 4.6), then
    // the matrix stream (scale groups interleaved with weight words)
    function automatic iss_t iss_step(input iss_t s_in, input int ngroups, sw, period);
        iss_t s;
        s = s_in;   // local copy: assigning the input arg itself warns (VER-1005)
        s.started = 1'b1;
        if (s.bias) begin
            if (s.bleft <= 2'd1) begin
                s.bias = 1'b0;
                s.kb = 0;
                s.g = 0;
                s.swi = 0;
                s.scale = (sw > 0);
            end else begin
                s.bidx = s.bidx + 2'd1;
                s.bleft = s.bleft - 2'd1;
            end
            return s;
        end
        if (s.scale) begin
            if (s.swi + 1 < sw) s.swi = s.swi + 4'(1);
            else begin s.scale = 1'b0; s.swi = 0; s.g = 0; end
        end else begin
            if (s.g + 1 < 6'(ngroups)) s.g = s.g + 6'(1);
            else begin
                s.g = 0;
                s.kb = s.kb + 17'(1);
                s.scale = (((s.kb) % 17'(period)) == 0) && (sw > 0);
                s.swi = 0;
            end
        end
        s.off = s.off + 17'(1);
        return s;
    endfunction
    // ================= sequential core (part B) ===========================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot[0] <= '0; slot[1] <= '0;
            iss[0] <= '0; iss[1] <= '0;
            phase_base[0] <= 0; phase_base[1] <= 0;
            for (int i = 0; i < 4; i++) rq[i] <= '0;
            rq_push <= 0; rq_fill <= 0; rq_cons <= 0; rq_cnt <= 0;
            stg_kb_q <= 0; stg_kb_qq <= 0;
            hbuf_kb_q <= 0; hbuf_kb_qq <= 0;
            for (int i = 0; i < 64; i++) cap_q[i] <= '0;
            cap_head <= 0; cap_tail <= 0; cap_cnt <= 0;
            // hold_* are unpacked arrays [0:1]: clear element-wise (ELAB-930)
            for (int c = 0; c < 2; c++) begin
                hold_v[c] <= 1'b0; hold_hv[c] <= 1'b0;
                hold_x[c] <= '0; hold_xs[c] <= '0;
                hold_h[c] <= '0; hold_hs[c] <= '0;
            end
            x_popped <= '0; xs_popped <= '0;
            for (int c = 0; c < 72; c++)
                for (int l = 0; l < 4; l++) gu_snap[c][l] <= 0;
            for (int e = 0; e < 144; e++) hup_slot[e] <= 0;
            pstate <= P_IDLE;
            act_c <= 0; act_cout <= 0; hup_beat <= 0; hup_beats <= 0;
            last_hup_pass <= 0;
            sync1 <= 0;
            yacc_commit_trigger <= 0;
            hbuf_take <= 0; hbuf_release <= 0;
            yacc_load_valid <= 0;
            ev_cmd_illegal <= 0; ev_unsupported <= 0; ev_xorder <= 0;
            ev_horder <= 0; ev_rramtag <= 0; ev_snapshot <= 0;
            ev_ctxbusy <= 0; ev_numeric <= 0; ev_hbank <= 0;
            ev_bias <= 0;
            pend_act <= 0;
            pend_commit <= 0;
            // staging expected-order state starts at XS group 0, lane 0
            exp_grp <= 0;
            exp_kind <= 1;
            exp_lane <= 0;
            exp_idx <= 0;
            bias_gu_valid <= 0;
            bias_d_valid <= 0;
            for (int i = 0; i < 36; i++) begin
                bias_gb[i] <= 0;
                bias_ub[i] <= 0;
            end
            for (int i = 0; i < 80; i++) bias_db[i] <= 0;
        end else begin
            sync1 <= 0;
            yacc_commit_trigger <= 0;
            hbuf_take <= 0; hbuf_release <= 0;
            yacc_load_valid <= 0;
            ev_bias <= 0;
            ev_cmd_illegal <= 0; ev_unsupported <= 0; ev_xorder <= 0;
            ev_horder <= 0; ev_rramtag <= 0; ev_snapshot <= 0;
            ev_ctxbusy <= 0; ev_numeric <= 0; ev_hbank <= 0;
            // ---- CMD latch ----
            if (cmd_in_valid) begin
                logic [511:0] pl;
                logic [1:0] cphase;
                logic [1:0] cclass;
                logic cctx;
                logic [2:0] cntok;
                logic cbad;
                pl = cmd_in_payload;
                cphase = pl[1:0];
                cclass = pl[10:9];
                cctx = pl[11];
                cntok = pl[45:43];
                cbad = (cphase == 2'd2) || (cphase == 2'd3) || (cclass == 2'd3) ||
                       (cntok == 0) || (cntok > 4) || (pl[19:12] != 8'd0) ||
                       (pl[20] != 1'b1) || (pl[21] != 1'b1) || !cp[cctx].legal;
                if (cphase == 2'd2) ev_unsupported <= 1;         // SCAN
                else if (cbad) ev_cmd_illegal <= 1;
                else if (slot[0].valid && slot[1].valid) ev_cmd_illegal <= 1;
                else begin
                    int si;
                    si = slot[0].valid ? 1 : 0;
                    slot[si].valid <= 1'b1;
                    slot[si].phase <= cphase;
                    slot[si].visit_slot <= pl[8:2];
                    slot[si].class_kind <= cclass;
                    slot[si].ctx_sel <= cctx;
                    slot[si].base_word <= pl[42:22];
                    slot[si].n_tok <= cntok;
                    slot[si].ybank <= pl[46];
                    slot[si].hbank <= pl[47];
                    slot[si].step_begin <= pl[48];
                    slot[si].step_end <= pl[49];
                    slot[si].expert_id <= pl[65:50];
                    slot[si].pass_id <= cmd_in_pass;
                    slot[si].step_id <= pl[287:256];
                    slot[si].lane_mask <= (4'b1 << cntok) - 4'b1;
                    for (int l = 0; l < 4; l++) begin
                        slot[si].y_slots[l] <= pl[96 + 40*l +: 6];
                        slot[si].weights[l] <= pl[102 + 40*l +: 32];
                    end
                    slot[si].first_v <= pl[20];
                    slot[si].last_v <= pl[21];
                    slot[si].fmt <= cp[cctx].fmt;
                    slot[si].sblk128 <= cp[cctx].sblk128;
                    slot[si].bias_en <= cp[cctx].bias_en;
                    iss[si].valid <= 1'b1;
                    iss[si].kb <= 0;
                    iss[si].g <= 0;
                    iss[si].swi <= 0;
                    iss[si].off <= 0;
                    iss[si].started <= 1'b0;
                    if (cp[cctx].bias_en) begin
                        // read the phase's bias tail words first (4.6)
                        iss[si].bias <= 1'b1;
                        iss[si].bidx <= (cphase == 1'd1)
                            ? cp[cctx].bias_first_d : 2'd0;
                        iss[si].bleft <= 2'd2;
                        iss[si].scale <= 1'b0;
                    end else begin
                        iss[si].bias <= 1'b0;
                        iss[si].bidx <= 2'd0;
                        iss[si].bleft <= 2'd0;
                        iss[si].scale <= (cp[cctx].sw > 0);
                    end
                    phase_base[si] <= 21'(pl[42:22]) +
                        (cphase == 1'd1 ? 21'(cp[cctx].gu_words) : 21'd0);
                    tail_base[si] <= 21'(pl[42:22]) +
                        21'(cp[cctx].gu_words) + 21'(cp[cctx].d_words);
                    hold_v[0] <= 1'b0; hold_v[1] <= 1'b0;   // fresh pass operands
                    hold_hv[0] <= 1'b0; hold_hv[1] <= 1'b0;
                    if (si == 0) begin
                        x_popped <= '0; xs_popped <= '0;
                        // fresh pass: the expected X/XS sequence restarts
                        exp_grp <= 0;
                        exp_kind <= 1;
                        exp_lane <= 0;
                        exp_idx <= 0;
                    end
                    if (cphase == 1'd0) begin
                        hbuf_take <= 1;                  // GU owns its h bank
                        hbuf_bank <= pl[47];
                        hbuf_pass <= cmd_in_pass;
                        hbuf_ntok <= cntok;
                        bias_gu_valid <= 1'b0;           // fresh GU bias ctx
                    end else begin
                        bias_d_valid <= 1'b0;            // fresh D bias ctx
                    end
                end
            end
            // ---- issue step + queue push (slot 0 first, then slot 1) ----
            if (iss_fire0) begin
                iss_t nxt;
                nxt = iss_step(iss[0], ngroups0, sw0, per0);
                rq[rq_push[1:0]].slot <= 0;
                rq[rq_push[1:0]].phase <= slot[0].phase;
                rq[rq_push[1:0]].bias <= iss[0].bias;
                rq[rq_push[1:0]].bidx <= iss[0].bidx;
                rq[rq_push[1:0]].scale <= iss[0].scale && !iss[0].bias;
                rq[rq_push[1:0]].swi <= iss[0].swi;
                rq[rq_push[1:0]].kb <= 8'(iss[0].kb);
                rq[rq_push[1:0]].g <= iss[0].g;
                rq[rq_push[1:0]].ncols <= cp[slot[0].ctx_sel].ncols;
                rq[rq_push[1:0]].ngroups <= 6'(ngroups0);
                rq[rq_push[1:0]].nkb <= (slot[0].phase == 0)
                    ? 8'(cp[slot[0].ctx_sel].nkb) : 8'(NKB_D);
                rq[rq_push[1:0]].fmt <= slot[0].fmt;
                rq[rq_push[1:0]].last_word <= !iss[0].bias && !iss[0].scale
                    && (nxt.kb == ((slot[0].phase == 0)
                        ? cp[slot[0].ctx_sel].nkb : 17'(NKB_D)));
                rq[rq_push[1:0]].full <= 1'b0;
                rq[rq_push[1:0]].data <= '0;
                iss[0] <= nxt;
                if (nxt.kb == ((slot[0].phase == 0)
                        ? cp[slot[0].ctx_sel].nkb : 17'(NKB_D)))
                    iss[0].valid <= 1'b0;
            end
            if (iss_fire1) begin
                iss_t nxt;
                nxt = iss_step(iss[1], ngroups1, sw1, per1);
                rq[rq_push[1:0]].slot <= 1;
                rq[rq_push[1:0]].phase <= slot[1].phase;
                rq[rq_push[1:0]].bias <= iss[1].bias;
                rq[rq_push[1:0]].bidx <= iss[1].bidx;
                rq[rq_push[1:0]].scale <= iss[1].scale && !iss[1].bias;
                rq[rq_push[1:0]].swi <= iss[1].swi;
                rq[rq_push[1:0]].kb <= 8'(iss[1].kb);
                rq[rq_push[1:0]].g <= iss[1].g;
                rq[rq_push[1:0]].ncols <= cp[slot[1].ctx_sel].ncols;
                rq[rq_push[1:0]].ngroups <= 6'(ngroups1);
                rq[rq_push[1:0]].nkb <= (slot[1].phase == 0)
                    ? 8'(cp[slot[1].ctx_sel].nkb) : 8'(NKB_D);
                rq[rq_push[1:0]].fmt <= slot[1].fmt;
                rq[rq_push[1:0]].last_word <= !iss[1].bias && !iss[1].scale
                    && (nxt.kb == ((slot[1].phase == 0)
                        ? cp[slot[1].ctx_sel].nkb : 17'(NKB_D)));
                rq[rq_push[1:0]].full <= 1'b0;
                rq[rq_push[1:0]].data <= '0;
                iss[1] <= nxt;
                if (nxt.kb == ((slot[1].phase == 0)
                        ? cp[slot[1].ctx_sel].nkb : 17'(NKB_D)))
                    iss[1].valid <= 1'b0;
            end
            // ---- RRAM return fill (strictly in issue order) ----
            if (rram_valid) begin
                if (rq_cnt != 0 && !rq[rq_fill[1:0]].full) begin
                    rq[rq_fill[1:0]].data <= rram_data;
                    rq[rq_fill[1:0]].full <= 1'b1;
                end else ev_rramtag <= 1;
            end
            // ---- consume: bias words fill the phase context; scale words
            // fill wsh; weight words feed the PE. rq_cons/rq_cnt/cap_q are
            // updated at the single points at the end of this block (R4-006)
            // and EVERY accepted weight word pushes a capture descriptor
            // (2'b00 = intermediate, no capture) so pops stay aligned with
            // pe_out_valid one-for-one (R4-011)
            if (head.bias && head_ready_q) begin
                // extract 64 BF16 entries of tail word head.bidx (4.6):
                // entries 0..35 gate, 36..71 up, 72..151 down
                for (int j = 0; j < 64; j++) begin
                    int e;
                    logic [15:0] code;
                    e = 64 * int'(head.bidx) + j;
                    code = head.data[16*j +: 16];
                    if (head.phase == 1'b0) begin
                        if (e < 36) bias_gb[e] <= code;
                        else if (e < 72) bias_ub[e - 36] <= code;
                    end else if (e >= 72 && e < 152)
                        bias_db[e - 72] <= code;
                end
                if ((head.phase == 1'b0 && head.bidx == 2'd1) ||
                    (head.phase == 1'b1 && head.bidx == 2'd2)) begin
                    if (head.phase == 1'b0) begin
                        if (bias_gu_valid) ev_bias <= 1;  // late/overwrite
                        bias_gu_valid <= 1'b1;
                    end else begin
                        if (bias_d_valid) ev_bias <= 1;
                        bias_d_valid <= 1'b1;
                    end
                end
            end else if (head_scale_q) begin
                // scale words consume in order without entering the PE
                for (int i = 0; i < 128; i++)
                    if (i < eper && head.swi*eper + i < cols_ph) begin
                        if (wbits == 32)
                            wsh[head.slot][head.swi*eper + i] <=
                                head.data[32*i +: 32];
                        else if (wbits == 16)
                            // pe3_scale reads weight_scale[15:0] and widens:
                            // 16-bit scales live in the LOW half (R4-033)
                            wsh[head.slot][head.swi*eper + i] <=
                                {16'b0, head.data[16*i +: 16]};
                        else
                            wsh[head.slot][head.swi*eper + i] <=
                                {24'b0, head.data[8*i +: 8]};
                    end
            end else if (pe_accept) begin
                // every weight accept pushes a descriptor: 00 intermediate,
                // {phase,last} for the final-k-block words (R4-011)
                cap_q[cap_head[5:0]] <= (head.kb == head.nkb - 8'd1)
                    ? {head.phase, head.last_word} : 2'b00;
                cap_head <= cap_head + 1;
            end
            // single-pointer/count updates (issue push and consume may
            // collide; both deltas applied together - R4-006)
            if (iss_fire0 || iss_fire1) begin
                rq_push <= rq_push + (iss_fire0 ? 2'd1 : 2'd0) +
                                      (iss_fire1 ? 2'd1 : 2'd0);
            end
            if (rram_valid && rq_cnt != 0 && !rq[rq_fill[1:0]].full)
                rq_fill <= rq_fill + 2'd1;
            if (cons_fire) begin
                rq_cons <= rq_cons + 2'd1;
                rq[rq_cons[1:0]].full <= 1'b0;
            end
            rq_cnt <= rq_cnt + (iss_fire0 ? 3'd1 : 3'd0) +
                               (iss_fire1 ? 3'd1 : 3'd0) -
                               (cons_fire ? 3'd1 : 3'd0);
            cap_cnt <= cap_cnt + (cap_push ? 6'd1 : 6'd0) -
                                (pe_out_valid ? 6'd1 : 6'd0);
            // ---- operand holds (banked by kb parity) ----
            if (stg_rd_valid) begin
                hold_x[stg_kb_qq[0]] <= stg_x_data;
                hold_xs[stg_kb_qq[0]] <= stg_xs_data;
                hold_v[stg_kb_qq[0]] <= 1'b1;
            end
            if (hbuf_rd_valid) begin
                hold_h[hbuf_kb_qq[0]] <= hbuf_rd_data;
                hold_hs[hbuf_kb_qq[0]] <= hbuf_rd_scales;
                hold_hv[hbuf_kb_qq[0]] <= 1'b1;
            end
            // ---- PE commit capture + phase epilogue FSM ----
            if (pe_out_valid) begin
                if (cap_cnt == 0) ev_snapshot <= 1;
                else begin
                    logic [1:0] kind;
                    kind = cap_q[cap_tail[5:0]];
                    if (!kind[1]) begin
                        // GU snapshot: 8 (or fewer) columns x 4 lanes
                        for (int c = 0; c < 8; c++)
                            if (c < int'(cp[slot[0].ctx_sel].ncols))
                                for (int l = 0; l < 4; l++)
                                    gu_snap[pe_out_col_base + c][l] <=
                                        pe_out_results[(c*4+l)*32 +: 32];
                    end else begin
                        // D commit-buffer load (column enables by format)
                        yacc_load_valid <= 1;
                        yacc_load_base <= pe_out_col_base;
                        for (int c = 0; c < 8; c++)
                            if (c < int'(cp[slot[0].ctx_sel].ncols))
                                yacc_load_cen[c] <= 1'b1;
                            else yacc_load_cen[c] <= 1'b0;
                        yacc_load_data <= pe_out_results;
                    end
                    cap_tail <= cap_tail + 1;
                    if (kind[0]) begin
                        if (!kind[1]) begin
                            if (slot[0].bias_en && !bias_gu_valid)
                                pend_act <= 1;    // wait for GU bias ctx
                            else begin
                                pstate <= P_ACT;
                                act_c <= 0;
                                act_cout <= 0;
                                for (int e = 0; e < 144; e++) hup_slot[e] <= 0;
                                last_hup_pass <= slot[0].pass_id;
                            end
                        end else begin
                            if (slot[0].bias_en && !bias_d_valid)
                                pend_commit <= 1; // wait for D bias ctx
                            else
                                pstate <= P_DCOMMIT;
                        end
                    end
                end
            end
            // pending epilogues resume once the bias context is valid
            if (pend_act && (!slot[0].bias_en || bias_gu_valid)) begin
                pend_act <= 0;
                pstate <= P_ACT;
                act_c <= 0;
                act_cout <= 0;
                for (int e = 0; e < 144; e++) hup_slot[e] <= 0;
                last_hup_pass <= slot[0].pass_id;
            end
            if (pend_commit && (!slot[0].bias_en || bias_d_valid)) begin
                pend_commit <= 0;
                pstate <= P_DCOMMIT;
            end
            case (pstate)
                P_ACT, P_ACTW: begin
                    // R4-016: outputs start arriving while inputs are still
                    // streaming (latency 24 < 36 input cycles), so collect in
                    // BOTH states; leave only when all 36 outputs landed
                    if (pstate == P_ACT) begin
                        if (act_c != 35) act_c <= act_c + 1;
                        else pstate <= P_ACTW;
                    end
                    if (act_out_valid) begin
                        for (int l = 0; l < 4; l++)
                            if (l < int'(slot[0].n_tok))
                                hup_slot[l*36 + act_cout] <= act_h[l];
                        if (act_cout == 35) begin
                            hup_beats <= (6'(slot[0].n_tok) * 36 + 7) / 8;
                            hup_beat <= 0;
                            pstate <= P_HUP;
                        end else act_cout <= act_cout + 1;
                    end
                end
                P_HUP: if (hup_ready) begin
                    if (hup_beat == hup_beats - 1) begin
                        sync1 <= 1;                       // GU phase DONE
                        slot[0] <= slot[1];
                        iss[0] <= iss[1];
                        phase_base[0] <= phase_base[1];
                        slot[1] <= '0;
                        pstate <= P_RUN;
                    end else hup_beat <= hup_beat + 1;
                end
                P_DCOMMIT: if (!yacc_busy) begin
                    yacc_commit_trigger <= 1;
                    yacc_bank <= slot[0].ybank;
                    yacc_mask <= slot[0].lane_mask;
                    for (int l = 0; l < 4; l++) begin
                        yacc_slots[l] <= slot[0].y_slots[l];
                        yacc_weights[l] <= slot[0].weights[l];
                    end
                    hbuf_release <= 1;                    // D frees its h bank
                    hbuf_bank <= slot[0].hbank;
                    sync1 <= 1;                           // D phase DONE
                    slot[0] <= slot[1];
                    iss[0] <= iss[1];
                    phase_base[0] <= phase_base[1];
                    slot[1] <= '0;
                    pstate <= P_RUN;
                end
                default: ;
            endcase
            // ---- staging fill engine: pop X/XS in the defined pass order ----
            // order per GU pass: for grp 0..2: XS(lane,grp) x n_tok, then
            // X(lane, idx=32*grp + i) for i in 0..group_limit-1, lanes inner
            if (xfifo_pop) begin
                logic match;
                logic [2:0] gl;
                gl = (gu_slot == 0) ? slot[0].n_tok : slot[1].n_tok;
                match = (xfifo_out_kind == exp_kind) &&
                        (xfifo_out_lane == exp_lane) &&
                        // XS entries are indexed by group, X by block index
                        (xfifo_out_idx == (exp_kind ? {7'b0, exp_grp}
                                                    : exp_idx_full)) &&
                        (xfifo_out_pass == exp_pass);
                if (!match || gu_slot == 2) ev_xorder <= 1;
                else begin
                    if (exp_kind) begin                    // XS flit
                        stg_wr_xs <= 1;
                        stg_wr_x <= 0;
                        if (exp_lane + 1 >= gl) xs_popped[exp_grp] <= 1;
                    end else begin
                        stg_wr_x <= 1;
                        stg_wr_xs <= 0;
                        if (exp_lane + 1 >= gl) x_popped[xfifo_out_idx] <= 1;
                    end
                    stg_wr_lane <= xfifo_out_lane;
                    stg_wr_idx <= xfifo_out_idx;
                    stg_wr_data <= xfifo_out_data;
                    // advance the expected sequence
                    if (exp_kind) begin
                        if (exp_lane + 1 >= gl) begin
                            exp_kind <= 0;
                            exp_lane <= 0;
                            exp_idx <= 0;
                        end else exp_lane <= exp_lane + 1;
                    end else begin
                        if (exp_lane + 1 >= gl) begin
                            exp_lane <= 0;
                            if (exp_idx + 1 >= group_limit) begin
                                exp_kind <= 1;
                                exp_idx <= 0;
                                exp_grp <= exp_grp + 1;
                            end else exp_idx <= exp_idx + 1;
                        end else exp_lane <= exp_lane + 1;
                    end
                end
            end else begin
                stg_wr_x <= 0;
                stg_wr_xs <= 0;
            end
            // ---- H routing through the quantizer into the h banks ----
            if (h_valid) begin
                if ((hbuf_owner_valid[0] && hbuf_owner_pass0 == h_pass &&
                     h_idx < 72)) begin
                    hsel <= 0;
                    quant_valid <= 1;
                end else if (hbuf_owner_valid[1] && hbuf_owner_pass1 == h_pass
                            && h_idx < 72) begin
                    hsel <= 1;
                    quant_valid <= 1;
                end else begin
                    ev_horder <= 1;
                    quant_valid <= 0;
                end
                quant_lane <= h_lane;
                quant_idx <= h_idx[6:0];
                quant_h <= h_data;
            end else quant_valid <= 0;
            // ---- delayed kb indices for operand-hold banking ----
            stg_kb_q <= stg_rd_kb;
            hbuf_kb_q <= hbuf_rd_idx;
            stg_kb_qq <= stg_kb_q;
            hbuf_kb_qq <= hbuf_kb_q;
        end
    end
    // ---- staging fill engine: combinational pop decision ----
    // (gu_slot/exp_kind/exp_pass/exp_idx_full/group_limit/gu_iss_kb are
    //  declared above, before the main always_ff)
    always_comb begin
        gu_slot = 2;
        if (slot[0].valid && slot[0].phase == 0) gu_slot = 0;
        else if (slot[1].valid && slot[1].phase == 0) gu_slot = 1;
        gu_iss_kb = (gu_slot == 0) ? iss[0].kb : iss[1].kb;
        group_limit = (exp_grp == 2) ? 7'd16 : 7'd32;
        exp_idx_full = {exp_grp, exp_idx[4:0]};
        exp_pass = (gu_slot == 0) ? slot[0].pass_id : slot[1].pass_id;
    end
    wire exp_is_xs = exp_kind;
    wire [9:0] exp_out_idx = exp_is_xs ? {7'b0, exp_grp} : exp_idx_full;
    wire xs_writable = (exp_grp <= 1) || (gu_iss_kb >= 17'(64*(int'(exp_grp)-1)));
    wire x_writable = (exp_out_idx <= 1) ||
                      (gu_iss_kb >= 17'(2*int'(exp_out_idx) - 2));
    assign xfifo_pop = !xfifo_empty && gu_slot != 2 &&
        (exp_is_xs ? xs_writable : x_writable);
    // ---- quantizer ----
    // (quant_* / hsel signals declared above, before the main always_ff)
    wire [10:0] quant_tag = 11'({hsel, quant_lane, quant_idx});
    always_comb begin
        hbuf_wr_bank = quant_otag[10];
        hbuf_wr_valid = quant_ov;
        hbuf_wr_lane = quant_otag[9:7];
        hbuf_wr_idx = quant_otag[6:0];
        hbuf_wr_q = quant_q;
        hbuf_wr_se = quant_se;
    end
    pe4_quant quant_unit (
        .clk(clk), .rst_n(rst_n), .in_valid(quant_valid), .in_h(quant_h),
        .in_tag(quant_tag), .out_valid(quant_ov), .out_q(quant_q),
        .out_se(quant_se), .out_tag(quant_otag), .err_nonfinite(quant_err));
    // ---- slot-1 issue helpers ----
    // (ngroups1/sw1/per1 declared above, before the main always_ff)
    always_comb begin
        ngroups1 = (slot[1].phase == 0) ? int'(cp[slot[1].ctx_sel].ngroups)
            : (COLS_D + int'(cp[slot[1].ctx_sel].ncols) - 1)
              / int'(cp[slot[1].ctx_sel].ncols);
        sw1 = int'(cp[slot[1].ctx_sel].sw);
        per1 = int'(cp[slot[1].ctx_sel].period);
    end
    // fresh-phase issue guard: a phase's first word waits for an empty queue
    // so its scale words cannot overwrite the wsh of in-flight entries
    wire fresh0 = (iss[0].off == 0);
    wire fresh1 = (iss[1].off == 0);
    assign hup_valid = (pstate == P_HUP);
    // stall events for the counters
    wire x_stall_ev = slot[0].valid && iss[0].valid && first_of_kb0 &&
                      !opnd_ready0 && rram_ready;
    wire rram_stall_ev = (slot[0].valid && iss[0].valid && !rram_ready) ||
                         (slot[1].valid && iss[1].valid && !rram_ready);
    // ---- register file, sticky errors, counters ----
    logic [21:0] err_q, alarm_mask_q;
    logic alarm_armed, alarm_pending;
    logic [4:0] err_first_bit;
    logic [7:0] err_first_pass;
    logic [31:0] cnt [0:12];
    logic [31:0] reg_rd_data_c;
    logic [21:0] err_w1c;
    logic [21:0] err_new;
    logic [21:0] err_q_n;
    logic [4:0] err_first_bit_n;
    logic [7:0] err_first_pass_n;
    always_comb begin
        err_w1c = (reg_wr_valid && reg_wr_addr == 12'h008)
                  ? reg_wr_data[21:0] : '0;
        err_events = '0;
        err_events[ERR_CMD_ILLEGAL] = ev_cmd_illegal;
        err_events[ERR_X_ORDER] = ev_xorder;
        err_events[ERR_H_ORDER] = ev_horder | hbuf_wr_err;
        err_events[ERR_RRAM_TAG] = ev_rramtag;
        err_events[ERR_SNAPSHOT] = ev_snapshot;
        err_events[ERR_UNSUPPORTED] = ev_unsupported;
        err_events[ERR_NUMERIC] = quant_err;
        err_events[ERR_CTX_BUSY] = ev_ctxbusy;
        err_events[ERR_REG_ADDR] = ev_regaddr;
        err_events[ERR_H_BANK] = ev_hbank;
        err_events[ERR_BIAS] = ev_bias;
        err_new = err_events | err_extra;
        err_q_n = (err_q & ~err_w1c) | err_new;
        err_first_bit_n = err_first_bit;
        err_first_pass_n = err_first_pass;
        if ((|err_new) && err_q == '0) begin
            for (int b = 21; b >= 0; b--)
                if (err_new[b]) begin
                    err_first_bit_n = 5'(b);
                    err_first_pass_n = slot[0].valid
                        ? slot[0].pass_id : slot[1].pass_id;
                end
        end
    end
    assign alarm_mask = alarm_mask_q;
    assign alarm_valid = alarm_pending;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            err_q <= '0;
            alarm_mask_q <= '0;
            alarm_armed <= 1;
            alarm_pending <= 0;
            alarm_payload <= 0;
            err_first_bit <= 0;
            err_first_pass <= 0;
            ev_regaddr <= 0;   // single owner of ev_regaddr (ELAB-366 fix)
            for (int i = 0; i < 13; i++) cnt[i] <= 0;
        end else begin
            err_q <= err_q_n;
            err_first_bit <= err_first_bit_n;
            err_first_pass <= err_first_pass_n;
            // ALARM (P3-6): one packet when the masked status leaves zero;
            // rearmed only after W1C (or a mask write) brings it back to 0
            if (alarm_armed && ((err_q_n & ~alarm_mask_q) != '0)) begin
                alarm_pending <= 1;
                alarm_armed <= 0;
                alarm_payload <= {80'b0, err_first_pass_n, 3'b0,
                                  err_first_bit_n, err_q_n};
            end else if ((err_q_n & ~alarm_mask_q) == '0) begin
                alarm_armed <= 1;
            end
            if (alarm_pending && alarm_ready) alarm_pending <= 0;
            if (cnt_clear) for (int i = 0; i < 13; i++) cnt[i] <= 0;
            else begin
                if (sync1) begin
                    if (cnt[11] != '1) cnt[11] <= cnt[11] + 1; // CNT_SYNC1
                end
                // GU/D counted separately at their own retire points (R4-021)
                if (sync1 && pstate == P_HUP && hup_last &&
                        cnt[0] != '1) cnt[0] <= cnt[0] + 1;   // CNT_GU
                if (sync1 && pstate == P_DCOMMIT &&
                        cnt[1] != '1) cnt[1] <= cnt[1] + 1;   // CNT_D
                if (xfifo_pop && cnt[3] != '1) cnt[3] <= cnt[3] + 1;
                if (h_valid && cnt[4] != '1) cnt[4] <= cnt[4] + 1;
                if (rram_req && cnt[5] != '1) cnt[5] <= cnt[5] + 1;
                if (x_stall_ev && cnt[6] != '1) cnt[6] <= cnt[6] + 1;
                if (rram_stall_ev && cnt[7] != '1) cnt[7] <= cnt[7] + 1;
                if (up_beat && cnt[8] != '1) cnt[8] <= cnt[8] + 1;
                if (up_crd_stall && cnt[9] != '1) cnt[9] <= cnt[9] + 1;
                if (y_yield && cnt[10] != '1) cnt[10] <= cnt[10] + 1;
                if (ctrl_seen && cnt[12] != '1) cnt[12] <= cnt[12] + 1;
            end
            ev_regaddr <= 0;   // 1-cycle pulse default; set below on bad address
            if (reg_wr_valid) begin
                if (reg_wr_addr == 12'h00c) alarm_mask_q <= reg_wr_data[21:0];
                if (reg_wr_addr >= 12'h100 && reg_wr_addr <= 12'h13c && !run_active_any)
                    ctx_word[0][(reg_wr_addr - 12'h100) >> 2] <= reg_wr_data;
                if (reg_wr_addr == 12'h140) ctx_mode[0] <= reg_wr_data;
                if (reg_wr_addr >= 12'h180 && reg_wr_addr <= 12'h1bc && !run_active_any)
                    ctx_word[1][(reg_wr_addr - 12'h180) >> 2] <= reg_wr_data;
                if (reg_wr_addr == 12'h1c0) ctx_mode[1] <= reg_wr_data;
                if (reg_wr_addr >= 12'h200) ev_regaddr <= 1;   // REMAP: rev4 no
            end
        end
    end
    // register read mux
    always_comb begin
        reg_rd_data_c = 32'h0;
        if (reg_wr_addr == 0) ;   // no-op guard
        case (reg_rd_addr)
            12'h000: reg_rd_data_c = {32'(TILE_ID_P)};
            12'h004: reg_rd_data_c = {24'b0, tile_status_level};
            12'h008: reg_rd_data_c = {10'b0, err_q};
            12'h00c: reg_rd_data_c = {10'b0, alarm_mask_q};
            12'h010: reg_rd_data_c = {24'b0, err_first_bit, err_first_pass};
            default: ;
        endcase
        for (int i = 0; i < 13; i++)
            if (reg_rd_addr == 12'h020 + 12'(4*i)) reg_rd_data_c = cnt[i];
        if (reg_rd_addr >= 12'h100 && reg_rd_addr <= 12'h13c)
            reg_rd_data_c = ctx_word[0][(reg_rd_addr - 12'h100) >> 2];
        if (reg_rd_addr == 12'h140) reg_rd_data_c = ctx_mode[0];
        if (reg_rd_addr >= 12'h180 && reg_rd_addr <= 12'h1bc)
            reg_rd_data_c = ctx_word[1][(reg_rd_addr - 12'h180) >> 2];
        if (reg_rd_addr == 12'h1c0) reg_rd_data_c = ctx_mode[1];
    end
    assign reg_rd_data = reg_rd_data_c;
    assign reg_rd_ack = reg_rd_valid;
    assign err_status = err_q;
    assign tile_status_level = {run_active_any, xfifo_empty, pstate[2:0],
                                iss[0].valid, iss[1].valid, rq_cnt[1:0]};
endmodule






