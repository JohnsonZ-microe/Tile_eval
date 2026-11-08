// Isolated synthesis tops (DC), mirroring the rev2/rev3 probe convention.
module pe4_fmul_probe (
    input logic clk, rst_n, in_valid,
    input logic [31:0] a, b,
    output logic out_valid,
    output logic [31:0] result
);
    pe4_fmul dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .a(a), .b(b), .out_valid(out_valid), .result(result));
endmodule

module pe4_act_probe (
    input logic clk, rst_n, in_valid,
    input logic [127:0] g, u, w,
    input logic [15:0] gb, ub,
    output logic out_valid,
    output logic [63:0] h
);
    logic [31:0] gi [0:3], ui [0:3], wi [0:3];
    logic [15:0] ho [0:3];
    for (genvar t = 0; t < 4; t++) begin
        assign gi[t] = g[32*t +: 32];
        assign ui[t] = u[32*t +: 32];
        assign wi[t] = w[32*t +: 32];
        assign h[16*t +: 16] = ho[t];
    end
    pe4_act dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .g(gi), .u(ui), .w(wi), .gb(gb), .ub(ub),
        .out_valid(out_valid), .h(ho));
endmodule

module pe4_quant_probe (
    input logic clk, rst_n, in_valid,
    input logic [511:0] in_h,
    input logic [10:0] in_tag,
    output logic out_valid,
    output logic [255:0] out_q,
    output logic [7:0] out_se,
    output logic err_nonfinite
);
    pe4_quant dut (.clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .in_h(in_h), .in_tag(in_tag), .out_valid(out_valid),
        .out_q(out_q), .out_se(out_se), .out_tag(), .err_nonfinite(err_nonfinite));
endmodule

module pe4_yacc_probe (
    input logic clk, rst_n,
    input logic commit_trigger, commit_bank,
    input logic [3:0] commit_mask,
    input logic [23:0] commit_slots,
    input logic [127:0] commit_weights,
    output logic commit_busy
);
    logic [5:0] sl [0:3];
    logic [31:0] wt [0:3];
    for (genvar l = 0; l < 4; l++) begin
        assign sl[l] = commit_slots[6*l +: 6];
        assign wt[l] = commit_weights[32*l +: 32];
    end
    pe4_yacc dut (.clk(clk), .rst_n(rst_n),
        .load_valid(1'b0), .load_base(7'd0), .load_cen(8'd0),
        .load_data(1024'd0),
        .commit_trigger(commit_trigger), .commit_bank(commit_bank),
        .commit_bias_en(1'b0), .commit_db(1280'd0),
        .commit_mask(commit_mask), .commit_slots(sl), .commit_weights(wt),
        .commit_busy(commit_busy), .commit_rd_active(), .commit_bank_id(),
        .drain_yield(),
        .drain_valid(1'b0), .drain_bank(1'b0), .drain_slot(6'd0),
        .drain_col_start(8'd0), .drain_count(8'd0), .drain_segment(2'd0),
        .drain_last_seg(1'b0), .drain_illegal(), .v0_drain(),
        .yb_valid(), .yb_ready(1'b0), .yb_payload(), .yb_last(),
        .yb_segment(), .yb_tag());
endmodule

module tile_ffn_probe (
    input logic clk, rst_n,
    input logic dn_valid,
    input logic [511:0] dn_payload,
    input logic [31:0] dn_sideband,
    input logic [1:0] up_credit,
    output logic up_valid,
    output logic [127:0] up_payload,
    output logic [23:0] up_sideband,
    output logic sync0, sync1, err_line
);
    tile_ffn_v4 #(.RRAM_WORDS(64)) dut (
        .clk(clk), .rst_n(rst_n),
        .dn_valid(dn_valid), .dn_payload(dn_payload), .dn_sideband(dn_sideband),
        .up_valid(up_valid), .up_credit(up_credit),
        .up_payload(up_payload), .up_sideband(up_sideband),
        .sync0(sync0), .sync1(sync1), .err_line(err_line),
        .sim_load(1'b0), .sim_addr(21'd0), .sim_data(1024'd0));
endmodule
