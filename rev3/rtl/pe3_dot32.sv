module pe3_compress #(parameter int WIDTH = 42, parameter int COUNT = 32,
                     parameter int OUTPUTS = 2*(COUNT/3)+COUNT%3) (
    input wire [WIDTH-1:0] operands [0:COUNT-1],
    output wire [WIDTH-1:0] compressed [0:OUTPUTS-1]
);
    for (genvar group_index = 0; group_index < COUNT/3; group_index = group_index+1) begin : compressors
        wire [WIDTH-1:0] first_value = operands[3*group_index];
        wire [WIDTH-1:0] second_value = operands[3*group_index+1];
        wire [WIDTH-1:0] third_value = operands[3*group_index+2];
        assign compressed[2*group_index] = first_value ^ second_value ^ third_value;
        assign compressed[2*group_index+1] = ((first_value & second_value) |
            (first_value & third_value) | (second_value & third_value)) << 1;
    end
    for (genvar leftover = 0; leftover < COUNT%3; leftover = leftover+1) begin : leftovers
        assign compressed[2*(COUNT/3)+leftover] = operands[3*(COUNT/3)+leftover];
    end
endmodule

module pe3_dot32 #(parameter bit WIDE = 0, parameter int SUM_W = WIDE ? 285 : 42) (
    input logic clk, rst_n, in_valid,
    input logic [511:0] weights,
    input logic [255:0] activations,
    output logic out_valid,
    output logic [31:0] partial_value,
    output wire signed [SUM_W-1:0] exact_sum,
    output wire exact_valid
);
    import pe3_pkg::*;
    localparam int QUANTUM = WIDE ? -142 : -18;
    logic [8:0] valid_pipe;
    logic [11:0] products [0:31];
    logic signed [10:0] shifts [0:31];
    logic [31:0] signs;
    wire [2:0] input_special [0:62];
    logic [2:0] specials [0:8];
    logic [SUM_W-1:0] leaves [0:31];
    wire [SUM_W-1:0] level22 [0:21], level15 [0:14], level10 [0:9], level7 [0:6];
    wire [SUM_W-1:0] level5 [0:4], level4 [0:3], level3 [0:2], level2 [0:1];
    logic [SUM_W-1:0] reg15 [0:14], reg7 [0:6], reg2 [0:1];
    wire [SUM_W-1:0] sum_reg;
    wire sum_valid, magnitude_valid;
    wire [SUM_W-1:0] magnitude;
    logic [1:0] negative_pipe;
    logic [5:0] correction;
    wire [5:0] sign_count [0:62];
    wire [SUM_W-1:0] signed_operands [0:32];
    for (genvar element = 0; element < 32; element = element+1) begin : product_units
        wire [15:0] weight_code = in_valid ? weights[element*16 +: 16] : 16'b0;
        wire [7:0] raw_activation = activations[element*8 +: 8];
        wire [7:0] activation_code = in_valid && raw_activation[6:0] != 127 ? raw_activation : 8'b0;
        wire [7:0] weight_sig = {weight_code[14:7] != 0, weight_code[6:0]};
        wire [3:0] activation_sig = {activation_code[6:3] != 0, activation_code[2:0]};
        wire negative = weight_code[15] ^ activation_code[7];
        wire special = &weight_code[14:7];
        wire signed [10:0] weight_exp = weight_code[14:7] == 0 ? -11'sd133 : $signed({3'b0, weight_code[14:7]})-11'sd134;
        wire signed [10:0] activation_exp = activation_code[6:3] == 0 ? -11'sd9 : $signed({7'b0, activation_code[6:3]})-11'sd10;
        wire [SUM_W-1:0] extended = {{(SUM_W-12){1'b0}}, products[element]};
        wire [SUM_W-1:0] aligned = shifts[element] < 0 ? extended >> (-shifts[element]) : extended << shifts[element];
        assign input_special[31+element] = !special ? 3'b0 :
            ((|weight_code[6:0]) || activation_sig == 0 ? 3'b100 : (negative ? 3'b010 : 3'b001));
        always_ff @(posedge clk) begin
            if (rst_n && in_valid) begin
                products[element] <= special ? 12'b0 : weight_sig * activation_sig;
                shifts[element] <= weight_exp+activation_exp-11'(QUANTUM);
                signs[element] <= negative;
            end
            if (rst_n && valid_pipe[0]) leaves[element] <= signs[element] ? ~aligned : aligned;
        end
    end
    for (genvar element=0; element<32; element=element+1) begin : correction_leaves
        assign sign_count[31+element]={5'b0,signs[element]};
        assign signed_operands[element]=leaves[element];
    end
    for (genvar node=0; node<31; node=node+1) begin : correction_tree
        assign sign_count[node]=sign_count[2*node+1]+sign_count[2*node+2];
    end
    assign signed_operands[32]={{(SUM_W-6){1'b0}},correction};
    for (genvar node = 0; node < 31; node = node+1) begin : special_tree
        assign input_special[node] = input_special[2*node+1] | input_special[2*node+2];
    end
    pe3_compress #(.WIDTH(SUM_W), .COUNT(33)) compress33(signed_operands, level22);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(22)) compress22(level22, level15);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(15)) compress15(reg15, level10);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(10)) compress10(level10, level7);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(7)) compress7(reg7, level5);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(5)) compress5(level5, level4);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(4)) compress4(level4, level3);
    pe3_compress #(.WIDTH(SUM_W), .COUNT(3)) compress3(level3, level2);
    pe3_cpa2 #(.WIDTH(SUM_W)) sum_adder(clk,rst_n,valid_pipe[4],reg2[0],reg2[1],sum_valid,sum_reg);
    wire [SUM_W-1:0] absolute_left=sum_reg[SUM_W-1] ? ~sum_reg : sum_reg;
    wire [SUM_W-1:0] absolute_right={{(SUM_W-1){1'b0}},sum_reg[SUM_W-1]};
    pe3_cpa2 #(.WIDTH(SUM_W)) magnitude_adder(clk,rst_n,sum_valid,absolute_left,absolute_right,magnitude_valid,magnitude);
    wire exceptional=(|specials[8]);
    wire [31:0] exceptional_value=specials[8][2] || (&specials[8][1:0]) ? CANON_NAN :
        {specials[8][1],8'hff,23'b0};
    pe3_round_pipe #(.WIDTH(SUM_W)) rounding(.clk(clk),.rst_n(rst_n),.in_valid(magnitude_valid),
        .magnitude(magnitude),.binary_exponent(12'(QUANTUM)),.negative(negative_pipe[1]),
        .special(exceptional),.exceptional(exceptional_value),.out_valid(out_valid),
        .result(partial_value),.commit_value());
    assign exact_sum=$signed(sum_reg);
    assign exact_valid=sum_valid;
    always_ff @(posedge clk) begin
        if (!rst_n) valid_pipe<=0;
        else begin
            valid_pipe<={valid_pipe[7:0],in_valid};
            if (in_valid) specials[0]<=input_special[0];
            for (integer stage=1; stage<9; stage=stage+1)
                if (valid_pipe[stage-1]) specials[stage]<=specials[stage-1];
            if (valid_pipe[0]) correction<=sign_count[0];
            if (valid_pipe[1])
                for (integer index=0; index<15; index=index+1) reg15[index]<=level15[index];
            if (valid_pipe[2])
                for (integer index=0; index<7; index=index+1) reg7[index]<=level7[index];
            if (valid_pipe[3])
                for (integer index=0; index<2; index=index+1) reg2[index]<=level2[index];
            if (sum_valid) negative_pipe[0]<=sum_reg[SUM_W-1];
            if (valid_pipe[7]) negative_pipe[1]<=negative_pipe[0];
        end
    end
endmodule
