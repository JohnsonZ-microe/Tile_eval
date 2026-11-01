package pe4_pkg;
    // ---- fixed V4.1 single-tile FFN geometry (RTL-TILE-FFN-004) ----
    localparam int R = 4;                 // token lanes per pass
    localparam int COLS_GU = 72;          // 36 gate + 36 up columns
    localparam int COLS_D = 80;           // down output columns
    localparam int H_COLS = 36;           // local h columns (ceil(I_V/64))
    localparam int NKB_GU = 160;          // GU k-blocks (K = 5120)
    localparam int NKB_D = 72;            // D k-blocks (K = I_V = 2304)
    localparam int X_FLITS = 80;          // X flits per token (64 k each)
    localparam int XS_FLITS = 3;          // XS flits per token (64 k-blocks each)
    localparam int H_FLITS = 72;          // H flits per token (32 cols each)
    localparam int Y_ROWS = 10;           // rows of 8 FP32 per token slot
    localparam int K_GU = 5120;           // GU k depth (hidden)
    localparam int K_D = 2304;            // D k depth (I_V)
    // ---- frozen protocol constants (data_bus v0.12 subset) ----
    localparam logic [2:0] FT_CMD = 0, FT_X = 1, FT_XS = 2, FT_H = 3, FT_CTRL = 4, FT_PGM = 5;
    localparam logic [1:0] UP_H = 0, UP_Y = 1, UP_STATUS = 2;
    localparam int XFIFO_DEPTH = 128;     // 128 x (512b payload + 4b kind)
    localparam int UP_CREDITS = 6;        // tile->L1 sender reset credits
    localparam int RRAM_CREDITS = 3;      // rev4 logical prefetch budget
    localparam logic [31:0] CANON_NAN = 32'h7fc00000;
    // frozen ERR_STATUS bits 0..18 (tile.json); rev4 additions from bit 19
    localparam int ERR_PROTO_TYPE = 0, ERR_PROTO_CTRL = 1, ERR_CMD_ILLEGAL = 2;
    localparam int ERR_X_FIFO_OVF = 3, ERR_X_ORDER = 4, ERR_H_ORDER = 5;
    localparam int ERR_H_BANK = 6, ERR_Y_BANK = 7, ERR_V0_DRAIN = 8;
    localparam int ERR_DRAIN_ILLEGAL = 9, ERR_UP_SLOT = 10, ERR_UP_CREDIT = 11;
    localparam int ERR_HAZARD = 12, ERR_RRAM_TAG = 13, ERR_BIAS = 14;
    localparam int ERR_CTX_BUSY = 15, ERR_REG_ADDR = 16, ERR_RPGM = 17, ERR_NUMERIC = 18;
    localparam int ERR_UNSUPPORTED = 19;  // rev4: PGM/SCAN/VSPLIT/EP/REMAP etc.
    localparam int ERR_ORDER = 20;        // rev4: staging/RRAM stream order violation
    localparam int ERR_SNAPSHOT = 21;     // rev4: capture FIFO overflow/underflow
    localparam int ERR_W = 22;
    // V4.1 ACT preset: alpha=1, gate upper 10, up [-10,10], no softclip/bias
    localparam logic [31:0] V41_ACT [0:7] = '{32'h3f800000, 32'hff800000,
        32'h41200000, 32'hc1200000, 32'h41200000, 32'h00000000,
        32'h00000000, 32'h00000000};

    typedef struct packed {
        logic valid;
        logic [1:0] phase;                // 0 GU, 1 D
        logic [6:0] visit_slot;
        logic [1:0] class_kind;           // 0 routed, 1 shared, 2 dense
        logic ctx_sel;                    // CTX select (0/1); 'context' is
                                         // a SystemVerilog reserved keyword
        logic [20:0] base_word;           // GU base; D base = base + GU words
        logic [2:0] n_tok;
        logic ybank, hbank;
        logic first_v, last_v, step_begin, step_end;
        logic [7:0] pass_id;
        logic [31:0] step_id;
        logic [15:0] expert_id;
        logic [3:0] lane_mask;
        logic [5:0] y_slots [0:3];
        logic [31:0] weights [0:3];
        logic [2:0] fmt;                  // resolved from the latched CTX
        logic sblk128;
        logic bias_en;                    // CTX BIAS_EN (W2[6])
    } cmd_t;

    function automatic int ncols_of(input logic [2:0] fmt);
        return (fmt == 0 || fmt == 4) ? 8 : (fmt == 5 ? 2 : 4);
    endfunction

    function automatic int scale_words(input logic [2:0] fmt, input int cols);
        // scale words per scale group covering `cols` columns of one phase
        case (fmt)
            0, 1:  return (cols*8 + 1023)/1024;   // UE8M0 8b entries
            2:     return (cols*32 + 1023)/1024;  // FP32, 128-k retention
            3, 4:  return (cols*16 + 1023)/1024;  // BF16 entries
            default: return 0;                    // bf16 weights: none
        endcase
    endfunction

    function automatic int scale_period_kb(input logic [2:0] fmt);
        return (fmt == 2 || fmt == 3) ? 4 : 1;    // 128-k retention
    endfunction

    function automatic logic [31:0] bf16_widen(input logic [15:0] code);
        return {code, 16'b0};
    endfunction

    function automatic logic [15:0] fp32_to_bf16(input logic [31:0] x);
        // RNE then truncate; NaN stays NaN (frozen arith_cells 8: "NaN
        // inputs stay NaN"), inf and finite values take the rounding path
        logic [31:0] t;
        if (((&x[30:23]) && (|x[22:0])))
            return {x[31], 1'b1, 8'hff, 6'b0};      // canonical BF16 NaN
        t = x + 32'h00007fff + {31'b0, x[16]};      // RNE, then truncate
        return t[31:16];
    endfunction

    function automatic logic fp32_is_nan(input logic [31:0] x);
        return (&x[30:23]) && (|x[22:0]);
    endfunction

    function automatic logic fp32_ge(input logic [31:0] a, input logic [31:0] b);
        // a >= b, IEEE-style for non-NaN operands (caller screens NaN)
        if (a[30:0] == 0 && b[30:0] == 0) return 1'b1;       // +-0 equal
        if (a[31] ^ b[31]) return !a[31];                    // signs differ
        if (a[31]) return {1'b1, b[30:0]} >= {1'b1, a[30:0]}; // both negative
        return {1'b0, a[30:0]} >= {1'b0, b[30:0]};
    endfunction

    function automatic logic [31:0] fp32_clamp(input logic [31:0] x,
        input logic [31:0] lo, input logic [31:0] hi);
        if (fp32_is_nan(x)) return x;
        if (!fp32_ge(x, lo)) return lo;
        if (!fp32_ge(hi, x)) return hi;
        return x;
    endfunction


    function automatic logic [7:0] e4m3_encode(input logic [31:0] x,
        input logic signed [11:0] e);
        // E4M3(x / 2^e), finite fp32 x; RNE with tie->even code, |v|>448 -> 448,
        // -0 -> 0x80, +0 -> 0x00. Mirrors model/tile_reference.py e4m3_encode.
        logic s;
        logic signed [12:0] ex, ny;
        logic [24:0] m25;
        logic [3:0] kept;
        logic [24:0] mask, low;
        int shift;
        logic up;
        s = x[31];
        if (x[30:23] == 0) begin
            m25 = {2'b0, x[22:0]};
            ex = -13'sd126;
            if (m25 == 0) return s ? 8'h80 : 8'h00;
        end else begin
            m25 = {1'b0, 1'b1, x[22:0]};
            ex = $signed({5'b0, x[30:23]}) - 13'sd127;
        end
        ny = ex - $signed({e[11], e});   // sign-extended e (R4-008)
        if (ny >= -13'sd6) begin
            kept = m25[23:20];
            up = m25[19] && ((|(m25[18:0])) || m25[20]);
            if (up) begin
                kept = kept + 4'd1;
                if (kept == 4'd0) begin  // carry out of {1.mmm}
                    kept = 4'd8;
                    ny = ny + 13'sd1;
                end
            end
            if (ny > 13'sd8 || (ny == 13'sd8 && kept[2:0] > 3'd6))
                return s ? 8'hfe : 8'h7e;                  // saturate 448
            return s ? {1'b1, 4'(ny + 13'sd7), kept[2:0]}
                     : {1'b0, 4'(ny + 13'sd7), kept[2:0]};
        end
        // subnormal E4M3: q = round_even(m25 / 2^(14-ny)), ny <= -7
        shift = 14 - ny;
        if (shift >= 26) return s ? 8'h80 : 8'h00;
        mask = (25'b1 << (shift-1)) - 25'b1;  // bits BELOW guard only (R4-008)
        low = m25 & mask;
        kept = 4'(m25 >> shift);                           // 0..8
        up = m25[shift-1] && ((|low) || kept[0]);
        if (up) kept = kept + 4'd1;
        if (kept >= 4'd8) return s ? 8'h88 : 8'h08;        // promoted to 2^-6
        return s ? {1'b1, 4'd0, kept[2:0]} : {1'b0, 4'd0, kept[2:0]};
    endfunction
endpackage

