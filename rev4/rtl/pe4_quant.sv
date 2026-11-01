// h quantizer (arith_cells 6 contract): 32 BF16 values per cycle ->
// 32 E4M3 codes + one UE8M0 block scale.
//   amax = max(max_j |h[j]|, fp32(1e-4)); with A = 1.f*2^E:
//   e = (f <= 0.75) ? E-8 : E-7   (divider-free, arith_cells-checked)
//   q[j] = E4M3(h[j] / 2^e)  RNE, tie->even code, |v|>448 -> 448, -0 -> 0x80
//   se = e + 127 in [105,247]
// Non-finite block (P5-5): se forced to 247; +inf/-inf -> 0x7E/0xFE,
// NaN -> 0x00, err_nonfinite -> ERR_STATUS.NUMERIC.
module pe4_quant (
    input  logic clk, rst_n,
    input  logic in_valid,
    input  logic [511:0] in_h,      // 32 x BF16
    input  logic [10:0] in_tag,     // {bank[10], lane[9:7], idx[6:0]}
    output logic out_valid,
    output logic [255:0] out_q,     // 32 x E4M3
    output logic [7:0] out_se,
    output logic [10:0] out_tag,
    output logic err_nonfinite
);
    import pe4_pkg::*;
    localparam logic [31:0] FLOOR_1EM4 = 32'h38d1b717;
    logic [31:0] hq [0:31];
    logic [31:0] amax_q;
    logic nf_q;                     // any non-finite h in the block
    logic [12:0] tag_q;
    logic v0, v1, v2;
    logic signed [11:0] e_sel_q;
    logic [7:0] q_c [0:31];
    // C0: widen/abs + amax tree + non-finite detect (on the live input)
    logic [31:0] a32 [0:31];
    logic [31:0] amax_c;
    logic nf_c;
    always_comb begin
        // in_h[16j+14:16j] = low 15 bits of the BF16 field (no nested slice:
        // slicing a part-select expression is VER-324 in DC Presto)
        for (int j = 0; j < 32; j++) a32[j] = {1'b0, in_h[16*j +: 15], 16'b0};
        amax_c = FLOOR_1EM4;
        nf_c = 0;
        for (int j = 0; j < 32; j++) begin
            if (a32[j][30:23] == 8'hff) nf_c = 1;
            if (a32[j][30:0] > amax_c[30:0]) amax_c = a32[j];
        end
    end
    // C1: exponent selection from the registered amax (>= 1e-4 -> normal)
    logic signed [11:0] e_norm;
    always_comb begin
        e_norm = $signed({4'b0, amax_q[30:23]}) - 12'sd127;
        if (amax_q[22:0] <= 23'h600000) e_sel_q = e_norm - 12'sd8;
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
                amax_q <= amax_c;
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

