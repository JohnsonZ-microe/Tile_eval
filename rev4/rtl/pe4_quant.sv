// h quantizer (arith_cells 6 contract): 32 BF16 values per cycle ->
// 32 E4M3 codes + one UE8M0 block scale.
//   amax = max(max_j |h[j]|, fp32(1e-4)); with A = 1.f*2^E:
//   e = (f <= 0.75) ? E-8 : E-7   (divider-free, arith_cells-checked)
//   q[j] = E4M3(h[j] / 2^e)  RNE, tie->even code, |v|>448 -> 448, -0 -> 0x80
//   se = e + 127 in [105,247]
// Non-finite block (P5-5): se forced to 247; +inf/-inf -> 0x7E/0xFE,
// NaN -> 0x00, err_nonfinite -> ERR_STATUS.NUMERIC.
// rev4.1 timing fix: the magnitude maximum is a balanced 5-level binary
// tree of 15-bit max2 units (32 inputs -> 1) with the 1e-4 floor applied
// once after the tree. The previous serial 32-stage compare chain was the
// critical path (-2.39 ns at 1 ns). Semantics are bit-identical: max is
// associative, and the widened 15-bit pattern {1'b0, mag, 16'b0} never
// crosses the f<=0.75 boundary differently than the full 32-bit compare
// (mantissa bits [22:16] are exactly mag[6:0]; low 16 bits are zero), so
// the golden vectors apply unchanged.
module pe4_quant (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic [511:0] in_h,      // 32 x BF16
    input  logic [12:0] in_tag,     // {bank, lane[2:0], idx[9:0]}
    output logic out_valid,
    output logic [255:0] out_q,     // 32 x E4M3
    output logic [7:0] out_se,
    output logic [12:0] out_tag,
    output logic err_nonfinite
);
    import pe4_pkg::*;
    localparam logic [31:0] FLOOR_1EM4 = 32'h38d1b717;
    localparam logic [14:0] FLOOR_15   = 15'h38d1;   // 1e-4 top 15 bits
    logic [31:0] hq [0:31];
    logic [14:0] amag_q;             // registered tree maximum incl. floor
    logic nf_q;                      // any non-finite h in the block
    logic [12:0] tag_q;
    logic v0, v1, v2;
    logic signed [11:0] e_sel_q;
    logic [7:0] q_c [0:31];
    // C0: 15-bit magnitude extraction + balanced max tree + floor
    function automatic logic [14:0] max2(input logic [14:0] a,
                                         input logic [14:0] b);
        return (a >= b) ? a : b;
    endfunction
    logic [14:0] mag [0:31];
    logic [14:0] t1 [0:15], t2 [0:7], t3 [0:3], t4 [0:1], t5, amag_max;
    logic [31:0] nf_vec;
    logic nf_c;
    always_comb begin
        for (int j = 0; j < 32; j++) mag[j] = in_h[16*j +: 16][14:0];
        for (int j = 0; j < 16; j++) t1[j] = max2(mag[2*j], mag[2*j+1]);
        for (int j = 0; j < 8; j++)  t2[j] = max2(t1[2*j], t1[2*j+1]);
        for (int j = 0; j < 4; j++)  t3[j] = max2(t2[2*j], t2[2*j+1]);
        t4[0] = max2(t3[0], t3[1]);
        t4[1] = max2(t3[2], t3[3]);
        t5 = max2(t4[0], t4[1]);
        amag_max = (t5 >= FLOOR_15) ? t5 : FLOOR_15;
        for (int j = 0; j < 32; j++)
            nf_vec[j] = (mag[j][14:7] == 8'hff);
        nf_c = |nf_vec;
    end
    // C1: exponent selection from the registered tree maximum (always a
    // normal >= 1e-4): exponent field = amag[14:7], the f<=0.75 boundary
    // reduces to amag[6:0] <= 0x60 because mantissa [22:16] == amag[6:0].
    logic signed [11:0] e_norm;
    always_comb begin
        e_norm = $signed({4'b0, amag_q[14:7]}) - 12'sd127;
        if (amag_q[6:0] <= 7'h60) e_sel_q = e_norm - 12'sd8;
        else e_sel_q = e_norm - 12'sd7;
    end
    // C2: encode (forced e = 120 when the block is non-finite) on hq
    always_comb begin
        for (int j = 0; j < 32; j++) begin
            if (hq[j][30:23] == 8'hff && hq[j][22:0] != 0)
                q_c[j] = 8'h00;                                   // NaN
            else if (hq[j][30:23] == 8'hff)
                q_c[j] = hq[j][31] ? 8'hfe : 8'h7e;               // +-inf
            else
                q_c[j] = e4m3_encode(hq[j], nf_q ? 12'sd120 : e_sel_q);
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v0 <= 0; v1 <= 0; v2 <= 0;
            out_valid <= 0;
            out_q <= 0; out_se <= 0; out_tag <= 0; err_nonfinite <= 0;
        end else begin
            v0 <= in_valid;
            v1 <= v0;
            v2 <= v1;
            out_valid <= v2;
            if (in_valid) begin
                for (int j = 0; j < 32; j++) hq[j] <= {in_h[16*j +: 16], 16'b0};
                amag_q <= amag_max;
                nf_q <= nf_c;
                tag_q <= in_tag;
            end
            if (v2) begin
                for (int j = 0; j < 32; j++) out_q[8*j +: 8] <= q_c[j];
                out_se <= nf_q ? 8'd247 : 8'(e_sel_q + 12'sd127);
                out_tag <= tag_q;
                err_nonfinite <= nf_q;
            end
        end
    end
endmodule
