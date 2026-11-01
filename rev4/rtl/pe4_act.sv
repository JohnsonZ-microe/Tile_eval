// Sigmoid ROM: BF16-code-indexed FP32 lookup, 2^16 entries (256 KiB max per
// table). Content is generated offline by scripts/gen_sigmoid_rom.py (double
// precision evaluation, one FP32 RNE rounding; NaN -> canonical NaN, +inf ->
// 1.0, -inf -> 0.0) and bound by the SHA-256 in docs/baseline.json. Four
// independent instances are used below (one per token lane).
module pe4_sigmoid_rom #(parameter string HEXFILE = "pe4_sigmoid_rom.hex") (
    input  logic clk,
    input  logic [15:0] code,
    output logic [31:0] value
);
`ifdef PE4_MEM_BLACKBOX
    // DC logic-check mode: the 256 KiB table is an unmapped macro
    pe4_bb_rom #(.DEPTH(65536), .WIDTH(32)) bb_i (
        .clk(clk), .code(code), .value(value));
`else
    logic [31:0] rom [0:65535];
    initial begin
        string path;
        if (!$value$plusargs("SIGMOID_HEX=%s", path)) path = HEXFILE;
        $readmemh(path, rom);
    end
    always_ff @(posedge clk) value <= rom[code];
`endif
endmodule

// Four-lane V4.1 SwiGLU activation with GU bias (arith_cells 5, data_bus 4.6):
//   g0 = fp32(g + gb);  u0 = fp32(u + ub)      (adds always execute; gb/ub =
//        +0.0 when bias is disabled -> the add itself normalises -0)
//   g1 = bf16(g0); u1 = bf16(u0)               (GU BF16 boundary)
//   g2 = clamp(g1, -inf, +10), u2 = clamp(u1, -10, +10)
//   s  = sigmoid_fp32(g2)        (ROM; g2 is BF16-exact, index g2[31:16])
//   v  = fp32(fp32(g2 * s) * u2)
//   h  = bf16(fp32(w * v))       (WPLACE=h, VACC_FP32=0)
// FP32 adds/multiplies use pe3_add/pe4_fmul (bit-exact vs the frozen
// oracle). Pipeline latency PE4_ACT_LAT = 24 cycles (1 input reg + 6 add +
// 1 clamp reg + 1 ROM + 3 fmul*4 + cast); out streams 1 pair/cycle.
module pe4_act (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic [31:0] g [0:3],
    input  logic [31:0] u [0:3],
    input  logic [31:0] w [0:3],
    input  logic [15:0] gb,               // per-column gate bias (all lanes)
    input  logic [15:0] ub,               // per-column up bias (all lanes)
    output logic out_valid,
    output logic [15:0] h [0:3]
);
    import pe4_pkg::*;
    // ---- stage A: input registers + bias adds (pe3_add, latency 6) ----
    logic [31:0] gr [0:3], ur [0:3];
    logic [15:0] gbr, ubr;
    logic va;
    logic [31:0] addg_r [0:3], addu_r [0:3];
    logic [3:0] addg_v, addu_v;    // 4 lanes, not 8 (R4-030)
    wire v_add = |addg_v;          // all eight adds pulse together
    for (genvar t = 0; t < 4; t++) begin : adds
        pe3_add ag (.clk(clk), .rst_n(rst_n), .in_valid(va),
            .bypass(1'b0), .left_value(gr[t]), .right_value({gbr, 16'b0}),
            .out_valid(addg_v[t]), .result(addg_r[t]), .commit_value());
        pe3_add au (.clk(clk), .rst_n(rst_n), .in_valid(va),
            .bypass(1'b0), .left_value(ur[t]), .right_value({ubr, 16'b0}),
            .out_valid(addu_v[t]), .result(addu_r[t]), .commit_value());
    end
    // ---- stage B..: cast + clamp, ROM, three multiplies, final cast ----
    logic [31:0] g2q [0:3], u2q [0:3];
    logic [15:0] vpipe;                   // packed valid shift register
    logic [15:0] code_r [0:3];
    logic [31:0] sq [0:3];
    logic [31:0] g2_d1 [0:3], g2_d2 [0:3];
    logic [31:0] u2p [0:5] [0:3];
    logic [31:0] wq  [0:17] [0:3];        // w aligned to v_add + 17
    logic [31:0] m1 [0:3], m2 [0:3], m3 [0:3];
    for (genvar t = 0; t < 4; t++) begin : roms
        pe4_sigmoid_rom sig (.clk(clk), .code(code_r[t]), .value(sq[t]));
        pe4_fmul mul1 (.clk(clk), .rst_n(rst_n), .in_valid(vpipe[2]),
            .a(g2_d2[t]), .b(sq[t]), .out_valid(), .result(m1[t]));
        pe4_fmul mul2 (.clk(clk), .rst_n(rst_n), .in_valid(vpipe[6]),
            .a(m1[t]), .b(u2p[5][t]), .out_valid(), .result(m2[t]));
        pe4_fmul mul3 (.clk(clk), .rst_n(rst_n), .in_valid(vpipe[10]),
            .a(m2[t]), .b(wq[17][t]), .out_valid(), .result(m3[t]));
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            va <= 0;
            vpipe <= '0;
            out_valid <= 0;
            gbr <= 0; ubr <= 0;
            for (int t = 0; t < 4; t++) begin
                gr[t] <= 0; ur[t] <= 0;
                g2q[t] <= 0; u2q[t] <= 0;
                h[t] <= 0;
                for (int s = 0; s <= 17; s++) wq[s][t] <= 0;
            end
        end else begin
            va <= in_valid;
            // stage A registers
            if (in_valid) begin
                for (int t = 0; t < 4; t++) begin
                    gr[t] <= g[t];
                    ur[t] <= u[t];
                end
                gbr <= gb;
                ubr <= ub;
            end
            // clamp stage fires on the add results (v_add cycle)
            if (v_add) begin
                for (int t = 0; t < 4; t++) begin
                    g2q[t] <= fp32_clamp({fp32_to_bf16(addg_r[t]), 16'b0},
                                         32'hff800000, 32'h41200000);
                    u2q[t] <= fp32_clamp({fp32_to_bf16(addu_r[t]), 16'b0},
                                         32'hc1200000, 32'h41200000);
                end
            end
            vpipe <= {vpipe[14:0], v_add};
            out_valid <= vpipe[15];
            for (int t = 0; t < 4; t++) begin
                code_r[t] <= g2q[t][31:16];
                g2_d1[t] <= g2q[t];
                u2p[0][t] <= u2q[t];
                wq[0][t] <= w[t];
                g2_d2[t] <= g2_d1[t];
                for (int s = 1; s <= 5; s++) u2p[s][t] <= u2p[s-1][t];
                for (int s = 1; s <= 17; s++) wq[s][t] <= wq[s-1][t];
                if (vpipe[15]) h[t] <= fp32_to_bf16(m3[t]);
            end
        end
    end
endmodule


