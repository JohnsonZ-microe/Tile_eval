package pe3_pkg;
    localparam int INPUT_STAGES = 2;
    localparam int DOT_STAGES = 13;
    localparam int SCALE_STAGES = 13;
    localparam int ADD_STAGES = 8;
    localparam int SHIFT_STAGES = 5;
    localparam int MUL_STAGES = 8;
    localparam int FPADD_STAGES = 7;
    localparam int RF_READ_STAGES = 1;
    localparam int ROUND_STAGES = 4;
    localparam int DOT_EXACT_DELAY = 6;
    localparam int PIPE_STAGES = INPUT_STAGES + DOT_STAGES + SCALE_STAGES + ADD_STAGES;
    localparam int COMMIT_DELAY = PIPE_STAGES - 1;
    localparam logic [31:0] CANON_NAN = 32'h7fc00000;
    typedef struct packed {
        logic valid;
        logic [2:0] fmt;
        logic [3:0] ncols, mask;
        logic [6:0] base;
        logic first_block, last_block;
        logic [31:0] tag, ascales;
        logic [255:0] wscales;
        logic [1:0] errors;
    } meta_t;
    function automatic logic nan32(input logic [31:0] value);
        return (&value[30:23]) && (|value[22:0]);
    endfunction
    function automatic logic inf32(input logic [31:0] value);
        return value[30:0] == 31'h7f800000;
    endfunction
    function automatic logic [15:0] decode_weight(input logic [15:0] code, input logic [2:0] fmt);
        integer magnitude, leading;
        logic [15:0] result;
        begin
            result = 0;
            magnitude = 0;
            leading = 0;
            if (fmt == 5) result = code;
            else if (fmt == 0) begin
                case (code[2:0])
                    0: result = 16'h0000;
                    1: result = 16'h3f00;
                    2: result = 16'h3f80;
                    3: result = 16'h3fc0;
                    4: result = 16'h4000;
                    5: result = 16'h4040;
                    6: result = 16'h4080;
                    7: result = 16'h40c0;
                endcase
                result[15] = code[3];
            end else if (fmt == 4) begin
                magnitude = code[3] ? 16-int'(code[3:0]) : int'(code[3:0]);
                for (integer index = 0; index < 4; index = index+1)
                    if ((magnitude >> index) != 0) leading = index;
                if (magnitude != 0)
                    result = {code[3], 8'(127+leading), 7'((magnitude << (7-leading)) & 127)};
            end else if (fmt <= 3) begin
                if (code[6:0] == 7'h7f) result = 0;
                else if (code[6:3] != 0)
                    result = {code[7], 8'(int'(code[6:3])+120), code[2:0], 4'b0};
                else if (code[2:0] != 0) begin
                    magnitude = int'(code[2:0]);
                    for (integer index = 0; index < 3; index = index+1)
                        if ((magnitude >> index) != 0) leading = index;
                    result = {code[7], 8'(118+leading), 7'((magnitude << (7-leading)) & 127)};
                end else result = {code[7], 15'b0};
            end
            return result;
        end
    endfunction
    function automatic logic [26:0] jam27(input logic [26:0] value, input logic [7:0] distance);
        logic [26:0] work;
        logic sticky;
        begin
            work = value;
            for (integer level = 0; level < 5; level = level+1) begin
                sticky = 0;
                for (integer index = 0; index < 27; index = index+1)
                    if (index < (1 << level)) sticky = sticky | work[index];
                if (distance[level]) work = (work >> (1 << level)) | {26'b0, sticky};
            end
            if (|distance[7:5]) work = {26'b0, |value};
            return work;
        end
    endfunction
    function automatic logic [31:0] pack_round(
        input logic negative, input logic [26:0] significand, input logic signed [11:0] exponent
    );
        logic [24:0] rounded;
        logic signed [11:0] adjusted;
        begin
            rounded = {1'b0, significand[26:3]} +
                      (significand[2] && (|significand[1:0] || significand[3]));
            adjusted = exponent;
            if (rounded[24]) begin
                rounded = rounded >> 1;
                adjusted = adjusted+12'sd1;
            end
            if (adjusted > 127) return {negative, 8'hff, 23'b0};
            if (rounded == 0) return {negative, 31'b0};
            if (adjusted == -126 && !rounded[23]) return {negative, 8'b0, rounded[22:0]};
            return {negative, 8'(adjusted+12'sd127), rounded[22:0]};
        end
    endfunction
endpackage
