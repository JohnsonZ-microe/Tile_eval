// Tile FFN revision 4 top level: frozen rev3 PE (tile_pe_v3) plus the full
// single-tile V4.1 FFN datapath and the frozen data_bus v0.12 protocol
// subset. See docs/SPEC.md for the supported subset and rev4 additions.
module tile_ffn_v4 #(
    parameter int RRAM_WORDS = 8192,
    parameter logic [31:0] SRC_ID = 32'd16
) (
    input  logic clk, rst_n,
    // down link (broadcast; the tile never stalls it -- errors instead)
    input  logic dn_valid,
    input  logic [511:0] dn_payload,
    input  logic [31:0] dn_sideband,
    // up link (tile -> L1 phits with credit returns)
    output logic up_valid,
    input  logic [1:0] up_credit,
    output logic [127:0] up_payload,
    output logic [23:0] up_sideband,
    // SYNC bundle toward the hub
    output logic sync0, sync1, err_line,
    // simulation-only RRAM image load (refused while running)
    input  logic sim_load,
    input  logic [20:0] sim_addr,
    input  logic [1023:0] sim_data
);
    import pe4_pkg::*;
    // ---------------- bus ----------------
    logic cmd_valid;
    logic [511:0] cmd_payload;
    logic [7:0] cmd_pass;
    logic xfifo_push, xfifo_kind, xfifo_ovf;
    logic [2:0] xfifo_in_lane;
    logic [9:0] xfifo_in_idx;
    logic [511:0] xfifo_in_data;
    logic h_valid;
    logic [2:0] h_lane;
    logic [9:0] h_idx;
    logic [7:0] h_pass;
    logic [511:0] h_data;
    logic ctrl_valid;
    logic [3:0] ctrl_op;
    logic [6:0] ctrl_target;
    logic [11:0] ctrl_addr;
    logic [31:0] ctrl_data;
    logic [7:0] ctrl_tag;
    logic dn_reserved;
    logic xfifo_pop;
    logic xfifo_out_kind;
    logic [2:0] xfifo_out_lane;
    logic [9:0] xfifo_out_idx;
    logic [511:0] xfifo_out_data;
    logic [7:0] xfifo_out_pass;
    logic xfifo_empty;
    logic [7:0] xfifo_level;
    logic up_credit_err;
    logic hup_ready;
    logic ysrc_ready, st_ready;
    // ---------------- scheduler ----------------
    logic [21:0] sched_err_events;
    logic rram_req, rram_ready, rram_valid;
    logic [20:0] rram_addr;
    logic [1023:0] rram_rdata;
    logic run_active, load_err;
    logic stg_wr_x, stg_wr_xs, stg_rd_req, stg_rd_valid;
    logic [2:0] stg_wr_lane;
    logic [9:0] stg_wr_idx, stg_rd_kb;
    logic [511:0] stg_wr_data;
    logic [1023:0] stg_x_data;
    logic [31:0] stg_xs_data;
    logic hbuf_wr_valid, hbuf_wr_err, hbuf_rd_req, hbuf_rd_valid;
    logic hbuf_wr_bank, hbuf_rd_bank, hbuf_take, hbuf_release;
    logic [2:0] hbuf_wr_lane, hbuf_ntok;
    logic [6:0] hbuf_wr_idx, hbuf_rd_idx;
    logic [255:0] hbuf_wr_q;
    logic [7:0] hbuf_wr_se, hbuf_pass, hbuf_owner_pass0, hbuf_owner_pass1;
    logic [1023:0] hbuf_rd_data;
    logic [31:0] hbuf_rd_scales;
    logic [1:0] hbuf_owner_valid, hbuf_bank_ready;
    logic pe_in_valid, pe_in_ready, pe_out_valid;
    logic [2:0] pe_wfmt;
    logic [1023:0] pe_weights, pe_acts, pe_out_results;
    logic [31:0] pe_ascales, pe_tag;
    logic [255:0] pe_wscales;
    logic [3:0] pe_mask;
    logic [6:0] pe_col_base, pe_out_col_base;
    logic pe_first, pe_last;
    logic act_in_valid, act_out_valid;
    logic [31:0] act_g [0:3], act_u [0:3], act_w [0:3];
    logic [15:0] act_gb, act_ub;
    logic [15:0] act_h [0:3];
    logic hup_valid, hup_last;
    logic [127:0] hup_payload;
    logic [7:0] hup_tag;
    logic yacc_load_valid, yacc_commit_trigger, yacc_busy;
    logic yacc_bank;
    logic yacc_bias_en_q;
    logic [1279:0] yacc_db_bus;
    logic [7:0] yacc_load_cen;
    logic [6:0] yacc_load_base;
    logic [1023:0] yacc_load_data;
    logic [3:0] yacc_mask;
    logic [5:0] yacc_slots [0:3];
    logic [31:0] yacc_weights [0:3];
    logic reg_wr_valid, reg_rd_valid, reg_rd_ack;
    logic [11:0] reg_wr_addr, reg_rd_addr;
    logic [31:0] reg_wr_data, reg_rd_data;
    logic [21:0] err_status_q, err_extra;
    logic drain_illegal_ev, v0_drain_ev;
    logic yb_valid;
    logic [127:0] yb_payload;
    logic yb_last;
    logic [1:0] yb_segment;
    logic [7:0] yb_tag;
    // ---- CTRL/drain/event signals (moved up from the CTRL-decode section:
    //      they are used in instance port connections below; DC requires
    //      declaration before use — VER-956) ----
    logic drain_fire, drain_bank, drain_lastseg;
    logic [5:0] drain_slot;
    logic [7:0] drain_cstart, drain_count;
    logic [1:0] drain_seg;
    logic st_valid;
    logic [127:0] st_payload;
    logic [7:0] st_tag;
    logic rpgm_ev, proto_ctrl_ev;
    logic cnt_clear, ctrl_seen;
    logic up_crd_stall, y_yield_ev;
    logic [7:0] reg_rd_tag;
    logic [21:0] alarm_mask;
    logic alarm_valid, alarm_rdy;
    logic [127:0] alarm_payload;
    logic [1:0] pe_err_sticky, pe_err_prev;
    // ---------------- instances ----------------
    pe4_bus bus_u (
        .clk(clk), .rst_n(rst_n),
        .dn_valid(dn_valid), .dn_payload(dn_payload), .dn_sideband(dn_sideband),
        .cmd_valid(cmd_valid), .cmd_payload(cmd_payload), .cmd_pass(cmd_pass),
        .xfifo_push(xfifo_push), .xfifo_kind(xfifo_kind), .xfifo_ovf(xfifo_ovf),
        .xfifo_in_lane(xfifo_in_lane), .xfifo_in_idx(xfifo_in_idx),
        .xfifo_in_data(xfifo_in_data),
        .h_valid(h_valid), .h_lane(h_lane), .h_idx(h_idx), .h_pass(h_pass),
        .h_data(h_data),
        .ctrl_valid(ctrl_valid), .ctrl_op(ctrl_op), .ctrl_target(ctrl_target),
        .ctrl_addr(ctrl_addr), .ctrl_data(ctrl_data), .ctrl_tag(ctrl_tag),
        .dn_reserved(dn_reserved),
        .xfifo_pop(xfifo_pop), .xfifo_out_kind(xfifo_out_kind),
        .xfifo_out_lane(xfifo_out_lane), .xfifo_out_idx(xfifo_out_idx),
        .xfifo_out_data(xfifo_out_data), .xfifo_out_pass(xfifo_out_pass),
        .xfifo_empty(xfifo_empty), .xfifo_level(xfifo_level), .sync0(sync0),
        .up_credit(up_credit), .up_valid(up_valid), .up_payload(up_payload),
        .up_sideband(up_sideband), .up_credit_err(up_credit_err),
        .hup_valid(hup_valid), .hup_ready(hup_ready),
        .hup_payload(hup_payload), .hup_last(hup_last),
        .hup_src(SRC_ID[7:0]), .hup_tag(hup_tag),
        .ysrc_valid(yb_valid), .ysrc_ready(ysrc_ready),
        .ysrc_payload(yb_payload), .ysrc_last(yb_last),
        .ysrc_segment(yb_segment), .ysrc_tag(yb_tag), .ysrc_src(SRC_ID[7:0]),
        .st_valid(st_valid), .st_ready(st_ready), .st_payload(st_payload),
        .st_tag(st_tag), .st_src(SRC_ID[7:0]));
    pe4_rram #(.WORDS(RRAM_WORDS)) rram_u (
        .clk(clk), .rst_n(rst_n), .run_active(run_active),
        .rd_req(rram_req), .rd_ready(rram_ready), .rd_addr(rram_addr),
        .rd_valid(rram_valid), .rd_data(rram_rdata),
        .sim_load(sim_load), .sim_addr(sim_addr), .sim_data(sim_data),
        .load_err(load_err));
    pe4_staging stg_u (
        .clk(clk), .rst_n(rst_n),
        .wr_x(stg_wr_x), .wr_xs(stg_wr_xs), .wr_lane(stg_wr_lane),
        .wr_idx(stg_wr_idx), .wr_data(stg_wr_data),
        .rd_req(stg_rd_req), .rd_kb(stg_rd_kb),
        .x_data(stg_x_data), .xs_data(stg_xs_data), .rd_valid(stg_rd_valid));
    pe4_hbuf hbuf_u (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(hbuf_wr_valid), .wr_bank(hbuf_wr_bank),
        .wr_lane(hbuf_wr_lane), .wr_idx(hbuf_wr_idx),
        .wr_q(hbuf_wr_q), .wr_se(hbuf_wr_se), .wr_err(hbuf_wr_err),
        .rd_req(hbuf_rd_req), .rd_bank(hbuf_rd_bank), .rd_idx(hbuf_rd_idx),
        .rd_data(hbuf_rd_data), .rd_scales(hbuf_rd_scales),
        .rd_valid(hbuf_rd_valid),
        .own_take(hbuf_take), .own_release(hbuf_release),
        .own_bank(hbuf_wr_bank_sel), .own_pass(hbuf_pass), .own_ntok(hbuf_ntok),
        .owner_valid(hbuf_owner_valid), .bank_ready(hbuf_bank_ready),
        .owner_pass0(hbuf_owner_pass0), .owner_pass1(hbuf_owner_pass1));
    tile_pe_v3 pe_u (
        .clk(clk), .rst_n(rst_n), .in_valid(pe_in_valid),
        .in_ready(pe_in_ready), .in_wfmt(pe_wfmt),
        .in_weights(pe_weights), .in_activations(pe_acts),
        .in_activation_scales(pe_ascales), .in_weight_scales(pe_wscales),
        .in_token_mask(pe_mask), .in_col_base(pe_col_base),
        .in_first(pe_first), .in_last(pe_last), .in_tag(pe_tag),
        .busy(), .out_valid(pe_out_valid), .out_done(), .out_tag(),
        .out_token_mask(), .out_col_mask(), .out_col_base(pe_out_col_base),
        .out_results(pe_out_results), .out_error(), .error_sticky(pe_err_sticky),
        .rd_col(7'd0), .rd_lane(2'd0), .rd_valid(), .rd_data());
    pe4_act act_i (
        .clk(clk), .rst_n(rst_n), .in_valid(act_in_valid),
        .g(act_g), .u(act_u), .w(act_w), .gb(act_gb), .ub(act_ub),
        .out_valid(act_out_valid), .h(act_h));
    pe4_yacc yacc_u (
        .clk(clk), .rst_n(rst_n),
        .load_valid(yacc_load_valid), .load_base(yacc_load_base),
        .load_cen(yacc_load_cen), .load_data(yacc_load_data),
        .commit_trigger(yacc_commit_trigger), .commit_bank(yacc_bank),
        .commit_bias_en(yacc_bias_en_q), .commit_db(yacc_db_bus),
        .commit_mask(yacc_mask), .commit_slots(yacc_slots),
        .commit_weights(yacc_weights), .commit_busy(yacc_busy),
        .commit_rd_active(), .commit_bank_id(),
        .drain_valid(drain_fire), .drain_bank(drain_bank),
        .drain_slot(drain_slot), .drain_col_start(drain_cstart),
        .drain_count(drain_count), .drain_segment(drain_seg),
        .drain_last_seg(drain_lastseg),
        .drain_illegal(drain_illegal_ev), .v0_drain(v0_drain_ev),
        .yb_valid(yb_valid), .yb_ready(ysrc_ready),
        .yb_payload(yb_payload), .yb_last(yb_last),
        .yb_segment(yb_segment), .yb_tag(yb_tag));
    pe4_sched sched_u (
        .clk(clk), .rst_n(rst_n),
        .cmd_in_valid(cmd_valid), .cmd_in_payload(cmd_payload),
        .cmd_in_pass(cmd_pass),
        .xfifo_empty(xfifo_empty), .xfifo_out_kind(xfifo_out_kind),
        .xfifo_out_lane(xfifo_out_lane), .xfifo_out_idx(xfifo_out_idx),
        .xfifo_out_data(xfifo_out_data), .xfifo_out_pass(xfifo_out_pass),
        .xfifo_pop(xfifo_pop),
        .h_valid(h_valid), .h_lane(h_lane), .h_idx(h_idx),
        .h_pass(h_pass), .h_data(h_data),
        .rram_req(rram_req), .rram_ready(rram_ready), .rram_addr(rram_addr),
        .rram_valid(rram_valid), .rram_data(rram_rdata),
        .run_active(run_active),
        .stg_wr_x(stg_wr_x), .stg_wr_xs(stg_wr_xs), .stg_wr_lane(stg_wr_lane),
        .stg_wr_idx(stg_wr_idx), .stg_wr_data(stg_wr_data),
        .stg_rd_req(stg_rd_req), .stg_rd_kb(stg_rd_kb),
        .stg_x_data(stg_x_data), .stg_xs_data(stg_xs_data),
        .stg_rd_valid(stg_rd_valid),
        .hbuf_wr_valid(hbuf_wr_valid), .hbuf_wr_bank(hbuf_wr_bank),
        .hbuf_wr_lane(hbuf_wr_lane), .hbuf_wr_idx(hbuf_wr_idx),
        .hbuf_wr_q(hbuf_wr_q), .hbuf_wr_se(hbuf_wr_se),
        .hbuf_wr_err(hbuf_wr_err),
        .hbuf_rd_req(hbuf_rd_req), .hbuf_rd_bank(hbuf_rd_bank),
        .hbuf_rd_idx(hbuf_rd_idx), .hbuf_rd_data(hbuf_rd_data),
        .hbuf_rd_scales(hbuf_rd_scales), .hbuf_rd_valid(hbuf_rd_valid),
        .hbuf_take(hbuf_take), .hbuf_release(hbuf_release),
        .hbuf_bank(hbuf_wr_bank_sel), .hbuf_pass(hbuf_pass),
        .hbuf_ntok(hbuf_ntok),
        .hbuf_owner_valid(hbuf_owner_valid), .hbuf_bank_ready(hbuf_bank_ready),
        .hbuf_owner_pass0(hbuf_owner_pass0), .hbuf_owner_pass1(hbuf_owner_pass1),
        .pe_in_valid(pe_in_valid), .pe_in_ready(pe_in_ready),
        .pe_wfmt(pe_wfmt), .pe_weights(pe_weights), .pe_acts(pe_acts),
        .pe_ascales(pe_ascales), .pe_wscales(pe_wscales), .pe_mask(pe_mask),
        .pe_col_base(pe_col_base), .pe_first(pe_first), .pe_last(pe_last),
        .pe_tag(pe_tag), .pe_out_valid(pe_out_valid),
        .pe_out_results(pe_out_results), .pe_out_col_base(pe_out_col_base),
        .act_in_valid(act_in_valid), .act_g(act_g), .act_u(act_u),
        .act_w(act_w), .act_out_valid(act_out_valid), .act_h(act_h),
        .act_gb(act_gb), .act_ub(act_ub),
        .hup_valid(hup_valid), .hup_ready(hup_ready),
        .hup_payload(hup_payload), .hup_last(hup_last), .hup_tag(hup_tag),
        .yacc_load_valid(yacc_load_valid), .yacc_load_cen(yacc_load_cen),
        .yacc_load_base(yacc_load_base), .yacc_load_data(yacc_load_data),
        .yacc_commit_trigger(yacc_commit_trigger), .yacc_bank(yacc_bank),
        .yacc_bias_en(yacc_bias_en_q), .yacc_db(yacc_db_bus),
        .yacc_mask(yacc_mask), .yacc_slots(yacc_slots),
        .yacc_weights(yacc_weights), .yacc_busy(yacc_busy),
        .reg_wr_valid(reg_wr_valid), .reg_wr_addr(reg_wr_addr),
        .reg_wr_data(reg_wr_data), .reg_rd_valid(reg_rd_valid),
        .reg_rd_addr(reg_rd_addr), .reg_rd_data(reg_rd_data),
        .reg_rd_ack(reg_rd_ack),
        .err_extra(err_extra), .cnt_clear(cnt_clear), .ctrl_seen(ctrl_seen),
        .alarm_mask(alarm_mask), .alarm_valid(alarm_valid),
        .alarm_ready(alarm_rdy), .alarm_payload(alarm_payload),
        .up_beat(up_valid), .up_crd_stall(up_crd_stall), .y_yield(y_yield_ev),
        .sync1(sync1), .run_active_any(),
        .err_status(err_status_q), .tile_status_level(),
        .err_events(sched_err_events));
    // ---------------- CTRL decode ----------------
    // (signal declarations moved above, before the instances)
    assign up_crd_stall = 0;
    assign y_yield_ev = 0;
    assign alarm_rdy = st_ready && alarm_valid;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            drain_fire <= 0; rpgm_ev <= 0; proto_ctrl_ev <= 0;
            reg_wr_valid <= 0; reg_rd_valid <= 0; cnt_clear <= 0;
            ctrl_seen <= 0;
            reg_wr_addr <= 0; reg_wr_data <= 0;
            reg_rd_addr <= 0; reg_rd_tag <= 0;
        end else begin
            drain_fire <= 0; rpgm_ev <= 0; proto_ctrl_ev <= 0;
            reg_wr_valid <= 0; reg_rd_valid <= 0; cnt_clear <= 0;
            ctrl_seen <= ctrl_valid;
            if (ctrl_valid) begin
                if (ctrl_op >= 4'd9) proto_ctrl_ev <= 1;
                else case (ctrl_op)
                    4'd0: begin
                        drain_fire <= 1;
                        drain_bank <= ctrl_addr[6];
                        drain_slot <= ctrl_addr[5:0];
                        drain_seg <= ctrl_addr[8:7];
                        drain_cstart <= ctrl_data[7:0];
                        drain_count <= ctrl_data[15:8];
                        drain_lastseg <= ctrl_data[16];
                    end
                    // register accesses latch addr/data/tag here and present
                    // them together with the valid pulse one cycle later
                    4'd1: begin
                        reg_wr_valid <= 1;
                        reg_wr_addr <= ctrl_addr;
                        reg_wr_data <= ctrl_data;
                    end
                    4'd2: begin
                        reg_rd_valid <= 1;
                        reg_rd_addr <= ctrl_addr;
                        reg_rd_tag <= ctrl_tag;
                    end
                    4'd3: cnt_clear <= 1;
                    default: rpgm_ev <= 1;            // ops 4-8: rpgm subset
                endcase
            end
        end
    end
    // ---- #8 PE numeric/transaction error aggregation (wire-level) ----
    // rev3 PE errors[0] (data: weight 127 / scale 255 / reserved activation
    // code) -> ERR_STATUS.NUMERIC; errors[1] (malformed transaction) ->
    // CMD_ILLEGAL. Edge-detected on the PE sticky outputs.
    always_ff @(posedge clk) begin
        if (!rst_n) pe_err_prev <= 2'b00;
        else pe_err_prev <= pe_err_sticky;
    end
    wire [1:0] pe_err_new = pe_err_sticky & ~pe_err_prev;
    // ---- #4 STATUS register replies (data_bus 6.3 STATUS_REG) ----
    // 2-deep FIFO; err=1 with data=0 for unaligned/unmapped offsets.
    typedef struct packed {
        logic [7:0] tag;
        logic [11:0] addr;
        logic [31:0] data;
        logic err;
    } stf_t;
    stf_t stf [0:1];
    logic [1:0] stf_cnt, stf_head, stf_tail;
    wire stf_push = reg_rd_valid && (stf_cnt != 2'd2);
    wire stf_pop = st_ready && !alarm_valid && (stf_cnt != 0);
    wire stf_addr_ok = (reg_rd_addr[1:0] == 2'b00) &&
        ((reg_rd_addr <= 12'h010) ||
         ((reg_rd_addr >= 12'h020) && (reg_rd_addr <= 12'h050)) ||
         ((reg_rd_addr >= 12'h100) && (reg_rd_addr <= 12'h140)) ||
         ((reg_rd_addr >= 12'h180) && (reg_rd_addr <= 12'h1C0)));
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stf_cnt <= 0; stf_head <= 0; stf_tail <= 0;
        end else begin
            if (stf_push) begin
                stf[stf_head] <= '{tag: reg_rd_tag, addr: reg_rd_addr,
                    data: stf_addr_ok ? reg_rd_data : 32'b0,
                    err: !stf_addr_ok};
                stf_head <= stf_head + 1;
            end
            if (stf_pop) stf_tail <= stf_tail + 1;
            case ({stf_push, stf_pop})
                2'b10: stf_cnt <= stf_cnt + 1;
                2'b01: stf_cnt <= stf_cnt - 1;
                default: ;
            endcase
        end
    end
    // ---- #3 ALARM (STATUS subtype 0xF3) outranks register replies ----
    assign st_valid = alarm_valid || (stf_cnt != 0);
    assign st_payload = alarm_valid ? alarm_payload :
        {83'b0, stf[stf_tail].err, stf[stf_tail].addr, stf[stf_tail].data};
    assign st_tag = alarm_valid ? 8'hF3 : stf[stf_tail].tag;
    // extra error bits from the bus, yacc, rram, CTRL decode and the PE
    wire pgm_seen = dn_valid && dn_sideband[2:0] == FT_PGM;
    always_comb begin
        err_extra = sched_err_events;
        err_extra[ERR_PROTO_TYPE] = dn_reserved;
        err_extra[ERR_PROTO_CTRL] = proto_ctrl_ev;
        err_extra[ERR_X_FIFO_OVF] = xfifo_ovf;
        err_extra[ERR_UP_CREDIT] = up_credit_err;
        err_extra[ERR_RPGM] = rpgm_ev | pgm_seen;
        err_extra[ERR_DRAIN_ILLEGAL] = drain_illegal_ev;
        err_extra[ERR_V0_DRAIN] = v0_drain_ev;
        err_extra[ERR_UNSUPPORTED] = err_extra[ERR_UNSUPPORTED] |
            pgm_seen | load_err;
        err_extra[ERR_NUMERIC] = err_extra[ERR_NUMERIC] | pe_err_new[0];
        err_extra[ERR_CMD_ILLEGAL] = err_extra[ERR_CMD_ILLEGAL] |
            pe_err_new[1];
    end
    // P3-6: err line driven while the masked status is non-zero
    assign err_line = |(err_status_q & ~alarm_mask);
endmodule

