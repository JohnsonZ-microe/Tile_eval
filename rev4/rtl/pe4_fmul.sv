// FP32 multiply, bit-exact against the frozen oracle model/reference.py
// fp_mul: one rounding of the exact product, subnormals in/out, -0 rules,
// NaN -> canonical, inf*0 -> NaN. 4-stage pipeline (docs/WIDTHS.md).
// Verified against the Fraction oracle by tb_math_v4 vectors.
module pe4_fmul (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic [31:0] a, b,
    output logic out_valid,
    output logic [31:0] result
);
    import pe4_pkg::*;
    logic [31:0] ra, rb;
    logic v0, v1, v2;
    // S1 decode
    logic s0, s1s, neg;
    logic nan_a, nan_b, inf_a, inf_b, zero_a, zero_b, special;
    logic [47:0] prod;
    logic signed [12:0] ev;
    // S2 normalize/round
    logic [31:0] packed_r;
    logic inf_out, zero_out;
    int msb, shift;
    logic [23:0] sig;
    logic guard, sticky, round_up;
    logic signed [12:0] te;
    logic [47:0] wq;
    logic qround;
    logic [31:0] packed_q;   // S2 snapshot aligned with the valid pipeline (R4-007)
    logic special_q, inf_out_q, zero_out_q;
    logic nan_a_q, nan_b_q, zero_a_q, zero_b_q;
    logic s0_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v0 <= 0; v1 <= 0; v2 <= 0; out_valid <= 0;
            packed_q <= 0; special_q <= 0; inf_out_q <= 0; zero_out_q <= 0;
            nan_a_q <= 0; nan_b_q <= 0; zero_a_q <= 0; zero_b_q <= 0; s0_q <= 0;
        end else begin
            v0 <= in_valid;
            v1 <= v0;
            v2 <= v1;
            out_valid <= v2;
            // ---- S0: input registers ----
            if (in_valid) begin ra <= a; rb <= b; end
            // ---- S1: decode + exact 24x24 product ----
            if (v0) begin
                s0 <= ra[31] ^ rb[31];
                nan_a <= fp32_is_nan(ra);
                nan_b <= fp32_is_nan(rb);
                inf_a <= ra[30:23] == 8'hff && ra[22:0] == 0;
                inf_b <= rb[30:23] == 8'hff && rb[22:0] == 0;
                zero_a <= ra[30:0] == 0;
                zero_b <= rb[30:0] == 0;
                special <= fp32_is_nan(ra) || fp32_is_nan(rb) ||
                    (ra[30:23] == 8'hff && ra[22:0] == 0) ||
                    (rb[30:23] == 8'hff && rb[22:0] == 0);
                prod <= (ra[30:23] == 0 ? {1'b0, ra[22:0]} : {1'b1, ra[22:0]}) *
                        (rb[30:23] == 0 ? {1'b0, rb[22:0]} : {1'b1, rb[22:0]});
                ev <= (ra[30:23] == 0 ? -13'sd149 : $signed({5'b0, ra[30:23]}) - 13'sd150) +
                      (rb[30:23] == 0 ? -13'sd149 : $signed({5'b0, rb[30:23]}) - 13'sd150);
            end
            // ---- S2 snapshot: registered when prod/ev are valid (v1 cycle),
            //      so the final result register at v2 reads THIS transaction
            if (v1) begin
                packed_q <= packed_r;
                special_q <= special;
                inf_out_q <= inf_out;
                zero_out_q <= zero_out;
                nan_a_q <= nan_a;
                nan_b_q <= nan_b;
                zero_a_q <= zero_a;
                zero_b_q <= zero_b;
                s0_q <= s0;
            end
        end
    end
    // combinational S2 on registered prod/ev, then S3 registers the result
    logic [24:0] sig25;
    always_comb begin
        // find most significant bit of prod
        msb = -1;
        for (int i = 47; i >= 0; i--)
            if (msb < 0 && prod[i]) msb = i;
        guard = 0; sticky = 0; round_up = 0;
        sig = '0;
        sig25 = '0;
        te = 0;
        inf_out = 0; zero_out = 0;
        packed_r = {s0, 31'b0};
        if (prod == 0) begin
            zero_out = 1;                             // +-0, sign = s0
        end else begin
            te = ev + 13'sd(msb);   // exponent for a [1,2) significand
            if (te > 13'sd127) inf_out = 1;
            else if (te >= -13'sd126) begin
                if (msb >= 23) begin
                    shift = msb - 23;
                    sig25 = {1'b0, 24'(prod >> shift)};  // top 24 bits
                    if (shift > 0) begin
                        guard = prod[shift-1];
                        sticky = |(prod & ((48'b1 << (shift-1)) - 48'b1));
                    end
                    round_up = guard && (sticky || sig25[0]);
                    if (round_up) sig25 = sig25 + 25'd1;
                end else begin
                    sig25 = {1'b0, 24'(prod << (23 - msb))};  // exact
                end
                if (sig25 == 25'h1000000) begin
                    sig25 = 25'h800000;
                    te = te + 13'sd1;
                end
                if (te > 13'sd127) inf_out = 1;
                else if (sig25[23]) packed_r = {s0, 8'(te + 13'sd127), sig25[22:0]};
                else packed_r = {s0, 31'b0};           // defensive only
            end else begin
                // subnormal: q = round_even(prod * 2^(ev+149)) on 2^-149 grid
                shift = -(ev + 13'sd149);              // >= 1 here
                if (shift >= 49) begin
                    zero_out = 1'b1;                   // below half quantum
                end else begin
                    wq = prod >> shift;
                    if (shift > 0) begin
                        guard = prod[shift-1];
                        sticky = |(prod & ((48'b1 << (shift-1)) - 48'b1));
                    end
                    qround = guard && (sticky || wq[0]);
                    if (qround) wq = wq + 48'd1;
                    if (wq >= 48'h800000) packed_r = {s0, 8'h01, 23'b0}; // 2^-126
                    else if (wq == 0) zero_out = 1'b1;
                    else packed_r = {s0, 8'h00, 23'(wq)};
                end
            end
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result <= 0;
            s1s <= 0;
            neg <= 0;
        end else if (v2) begin
            if (special_q) begin
                if (nan_a_q || nan_b_q) result <= CANON_NAN;
                else if (zero_a_q || zero_b_q) result <= CANON_NAN;  // inf*0
                else result <= {s0_q, 8'hff, 23'b0};
            end else if (inf_out_q) result <= {s0_q, 8'hff, 23'b0};
            else if (zero_out_q) result <= {s0_q, 31'b0};
            else result <= packed_q;
        end
    end
endmodule
