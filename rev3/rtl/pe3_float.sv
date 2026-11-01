module pe3_shift (
    input logic clk, rst_n, in_valid,
    input logic [31:0] value,
    input logic signed [10:0] amount,
    output wire out_valid,
    output wire [31:0] result
);
    import pe3_pkg::*;
    logic valid_reg, negative_reg, special_reg;
    logic [23:0] magnitude;
    logic signed [11:0] exponent_reg;
    logic [31:0] exceptional_reg;
    always_ff @(posedge clk) begin
        if (!rst_n) valid_reg<=0;
        else begin
            valid_reg<=in_valid;
            if (in_valid) begin
                magnitude<={value[30:23] != 0,value[22:0]};
                exponent_reg<=(value[30:23] == 0 ? -12'sd149 : $signed({4'b0,value[30:23]})-12'sd150)+amount;
                negative_reg<=value[31];
                special_reg<=&value[30:23];
                exceptional_reg<=nan32(value) ? CANON_NAN : value;
            end
        end
    end
    pe3_round_pipe #(.WIDTH(24)) rounding(.clk(clk),.rst_n(rst_n),.in_valid(valid_reg),
        .magnitude(magnitude),.binary_exponent(exponent_reg),.negative(negative_reg),
        .special(special_reg),.exceptional(exceptional_reg),.out_valid(out_valid),.result(result),.commit_value());
endmodule

module pe3_mul (
    input logic clk, rst_n, in_valid, bypass,
    input logic [31:0] left_value, right_value,
    output wire out_valid,
    output wire [31:0] result
);
    import pe3_pkg::*;
    wire [23:0] left_sig=bypass ? 24'b0 : {left_value[30:23] != 0,left_value[22:0]};
    wire [23:0] right_sig=bypass ? 24'b0 : {right_value[30:23] != 0,right_value[22:0]};
    logic [23:0] product_ll, product_lh, product_hl, product_hh;
    wire [47:0] term_ll={24'b0,product_ll};
    wire [47:0] term_lh={12'b0,product_lh,12'b0};
    wire [47:0] term_hl={12'b0,product_hl,12'b0};
    wire [47:0] term_hh={product_hh,24'b0};
    wire [47:0] sum_first=term_ll ^ term_lh ^ term_hl;
    wire [47:0] carry_first=((term_ll & term_lh) | (term_ll & term_hl) | (term_lh & term_hl)) << 1;
    logic [47:0] sum_reg, carry_reg;
    wire [47:0] product;
    wire product_valid;
    logic [3:0] valid_pipe, negative_pipe, special_pipe;
    logic signed [11:0] exponent_pipe [0:3];
    logic [31:0] exceptional_pipe [0:3];
    always_ff @(posedge clk) begin
        if (!rst_n) valid_pipe<=0;
        else begin
            valid_pipe<={valid_pipe[2:0],in_valid};
            if (in_valid) begin
                product_ll<=left_sig[11:0]*right_sig[11:0];
                product_lh<=left_sig[11:0]*right_sig[23:12];
                product_hl<=left_sig[23:12]*right_sig[11:0];
                product_hh<=left_sig[23:12]*right_sig[23:12];
                exponent_pipe[0]<=(left_value[30:23] == 0 ? -12'sd149 : $signed({4'b0,left_value[30:23]})-12'sd150)+
                                  (right_value[30:23] == 0 ? -12'sd149 : $signed({4'b0,right_value[30:23]})-12'sd150);
                negative_pipe[0]<=left_value[31] ^ right_value[31];
                special_pipe[0]<=bypass || nan32(left_value) || nan32(right_value) || inf32(left_value) || inf32(right_value);
                if (bypass) exceptional_pipe[0]<=left_value;
                else if (nan32(left_value) || nan32(right_value) ||
                    (inf32(left_value) && right_sig == 0) || (inf32(right_value) && left_sig == 0)) exceptional_pipe[0]<=CANON_NAN;
                else exceptional_pipe[0]<={left_value[31] ^ right_value[31],8'hff,23'b0};
            end
            if (valid_pipe[0]) begin
                sum_reg<=sum_first ^ carry_first ^ term_hh;
                carry_reg<=((sum_first & carry_first) | (sum_first & term_hh) | (carry_first & term_hh)) << 1;
            end
            for (integer stage=1; stage<4; stage=stage+1)
                if (valid_pipe[stage-1]) begin
                    exponent_pipe[stage]<=exponent_pipe[stage-1];
                    negative_pipe[stage]<=negative_pipe[stage-1];
                    special_pipe[stage]<=special_pipe[stage-1];
                    exceptional_pipe[stage]<=exceptional_pipe[stage-1];
                end
        end
    end
    pe3_cpa2 #(.WIDTH(48),.CHUNK(24)) product_adder(clk,rst_n,valid_pipe[1],sum_reg,carry_reg,product_valid,product);
    pe3_round_pipe #(.WIDTH(48)) rounding(.clk(clk),.rst_n(rst_n),.in_valid(product_valid),
        .magnitude(product),.binary_exponent(exponent_pipe[3]),.negative(negative_pipe[3]),
        .special(special_pipe[3]),.exceptional(exceptional_pipe[3]),.out_valid(out_valid),.result(result),.commit_value());
endmodule

module pe3_add (
    input logic clk, rst_n, in_valid, bypass,
    input logic [31:0] left_value, right_value,
    output wire out_valid,
    output wire [31:0] result,
    output wire [31:0] commit_value
);
    import pe3_pkg::*;
    logic [2:0] valid_pipe, special, negative;
    logic [31:0] exceptional [0:2];
    logic [26:0] larger_sig, smaller_sig, aligned_larger, aligned_smaller;
    logic [7:0] distance;
    logic subtract_reg, subtract_next;
    logic signed [11:0] exponent_reg [0:2];
    logic [27:0] magnitude;
    logic [31:0] larger, smaller;
    logic [7:0] larger_exp, smaller_exp;
    always_comb begin
        larger = left_value[30:0] >= right_value[30:0] ? left_value : right_value;
        smaller = left_value[30:0] >= right_value[30:0] ? right_value : left_value;
        larger_exp = larger[30:23] == 0 ? 8'd1 : larger[30:23];
        smaller_exp = smaller[30:23] == 0 ? 8'd1 : smaller[30:23];
    end
    pe3_round_pipe #(.WIDTH(28)) rounding(clk,rst_n,valid_pipe[2],magnitude,exponent_reg[2],
        negative[2],special[2],exceptional[2],out_valid,result,commit_value);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe <= 0;
        end else begin
            valid_pipe <= {valid_pipe[1:0], in_valid};
            if (in_valid) begin
                larger_sig <= {larger[30:23] != 0, larger[22:0], 3'b0};
                smaller_sig <= {smaller[30:23] != 0, smaller[22:0], 3'b0};
                distance <= larger_exp-smaller_exp;
                subtract_reg <= larger[31] ^ smaller[31];
                exponent_reg[0] <= $signed({4'b0, larger_exp})-12'sd153;
                negative[0] <= larger[31];
                special[0] <= bypass || nan32(left_value) || nan32(right_value) || inf32(left_value) || inf32(right_value);
                if (bypass) exceptional[0] <= right_value;
                else if (nan32(left_value) || nan32(right_value) ||
                         (inf32(left_value) && inf32(right_value) && left_value[31] != right_value[31])) exceptional[0] <= CANON_NAN;
                else exceptional[0] <= inf32(left_value) ? left_value : right_value;
            end
            for (integer stage = 1; stage < 3; stage = stage+1) begin
                if (valid_pipe[stage-1]) begin
                    special[stage] <= special[stage-1];
                    exceptional[stage] <= exceptional[stage-1];
                    negative[stage] <= negative[stage-1];
                end
            end
            if (valid_pipe[0]) begin
                aligned_larger <= larger_sig;
                aligned_smaller <= jam27(smaller_sig, distance);
                subtract_next <= subtract_reg;
                exponent_reg[1] <= exponent_reg[0];
            end
            if (valid_pipe[1]) begin
                magnitude <= subtract_next ? {1'b0, aligned_larger}-{1'b0, aligned_smaller} :
                                             {1'b0, aligned_larger}+{1'b0, aligned_smaller};
                if (subtract_next && aligned_larger == aligned_smaller) negative[2] <= 0;
                exponent_reg[2] <= exponent_reg[1];
            end
        end
    end
endmodule

module pe3_scale (
    input logic clk, rst_n, in_valid,
    input logic [31:0] partial_value,
    input logic [2:0] fmt,
    input logic [7:0] activation_scale,
    input logic [31:0] weight_scale,
    output logic out_valid,
    output logic [31:0] result
);
    import pe3_pkg::*;
    logic signed [10:0] amount, activation_exp, weight_exp;
    logic [31:0] scale_pipe [0:SHIFT_STAGES-1];
    logic [SHIFT_STAGES-1:0] bypass_pipe;
    wire shift_valid;
    wire [31:0] shifted;
    always_comb begin
        activation_exp = activation_scale == 255 ? 11'sd0 : $signed({3'b0, activation_scale})-11'sd127;
        weight_exp = weight_scale[7:0] == 255 ? 11'sd0 : $signed({3'b0, weight_scale[7:0]})-11'sd127;
        amount = fmt == 0 || fmt == 1 ? activation_exp+weight_exp : activation_exp;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bypass_pipe <= 0;
            for (integer stage = 0; stage < SHIFT_STAGES; stage = stage+1) scale_pipe[stage] <= 0;
        end else begin
            if (in_valid) begin
                bypass_pipe[0] <= fmt == 0 || fmt == 1 || fmt == 5;
                scale_pipe[0] <= fmt == 2 ? weight_scale : {weight_scale[15:0], 16'b0};
            end
            for (integer stage=1; stage<SHIFT_STAGES; stage=stage+1) begin
                bypass_pipe[stage]<=bypass_pipe[stage-1];
                scale_pipe[stage]<=scale_pipe[stage-1];
            end
        end
    end
    pe3_shift shift_unit(clk, rst_n, in_valid, partial_value, amount, shift_valid, shifted);
    pe3_mul multiply_unit(clk, rst_n, shift_valid, bypass_pipe[SHIFT_STAGES-1], shifted, scale_pipe[SHIFT_STAGES-1], out_valid, result);
endmodule
