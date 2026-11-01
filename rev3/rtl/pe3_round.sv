module pe3_lod #(parameter int WIDTH = 48, parameter int PAD = 2**$clog2(WIDTH)) (
    input logic [WIDTH-1:0] magnitude,
    output logic [8:0] leading
);
    wire present [1:2*PAD-1];
    wire [8:0] position [1:2*PAD-1];
    for (genvar leaf = 0; leaf < PAD; leaf = leaf+1) begin : leaves
        if (leaf < WIDTH) assign present[PAD+leaf] = magnitude[leaf];
        else assign present[PAD+leaf] = 1'b0;
        assign position[PAD+leaf] = 9'(leaf);
    end
    for (genvar node = 1; node < PAD; node = node+1) begin : nodes
        assign present[node] = present[2*node] | present[2*node+1];
        assign position[node] = present[2*node+1] ? position[2*node+1] : position[2*node];
    end
    assign leading = present[1] ? position[1] : 9'b0;
endmodule

module pe3_round_pipe #(parameter int WIDTH=48, parameter int WORK_W=WIDTH < 27 ? 27 : WIDTH) (
    input logic clk, rst_n, in_valid,
    input logic [WIDTH-1:0] magnitude,
    input logic signed [11:0] binary_exponent,
    input logic negative, special,
    input logic [31:0] exceptional,
    output logic out_valid,
    output logic [31:0] result,
    output wire [31:0] commit_value
);
    import pe3_pkg::*;
    localparam int LEVELS=$clog2(WORK_W);
    logic [2:0] valid_pipe, negative_pipe, special_pipe;
    logic [31:0] exceptional_pipe [0:2];
    logic [WIDTH-1:0] magnitude_reg;
    logic [WORK_W-1:0] extended_reg;
    wire [8:0] leading;
    logic [8:0] leading_reg;
    logic signed [11:0] quantum_reg, exponent_reg, rounded_exp;
    logic signed [12:0] top_exp, distance;
    logic [12:0] amount_reg;
    logic right_reg;
    logic [26:0] normalized, rounded_sig;
    wire [WORK_W-1:0] shifted [0:LEVELS];
    wire [LEVELS-1:0] discarded;
    pe3_lod #(.WIDTH(WIDTH)) lod(magnitude, leading);
    assign shifted[0]=extended_reg;
    for (genvar level=0; level<LEVELS; level=level+1) begin : barrel
        assign shifted[level+1]=amount_reg[level] ? shifted[level] >> (1 << level) : shifted[level];
        assign discarded[level]=amount_reg[level] && (|shifted[level][(1 << level)-1:0]);
    end
    always_comb begin
        top_exp=$signed({4'b0,leading_reg})+quantum_reg;
        distance=top_exp < -126 ? -13'sd152-quantum_reg : $signed({4'b0,leading_reg})-13'sd26;
        if (!right_reg) normalized=27'(extended_reg << amount_reg);
        else if (amount_reg >= WORK_W) normalized={26'b0,|extended_reg};
        else normalized={shifted[LEVELS][26:1],shifted[LEVELS][0] | (|discarded)};
    end
    assign commit_value=special_pipe[2] ? exceptional_pipe[2] : pack_round(negative_pipe[2],rounded_sig,rounded_exp);
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_pipe<=0;
            out_valid<=0;
            result<=0;
        end else begin
            valid_pipe<={valid_pipe[1:0],in_valid};
            out_valid<=valid_pipe[2];
            if (in_valid) begin
                magnitude_reg<=magnitude;
                leading_reg<=leading;
                quantum_reg<=binary_exponent;
                negative_pipe[0]<=negative;
                special_pipe[0]<=special;
                exceptional_pipe[0]<=exceptional;
            end
            for (integer stage=1; stage<3; stage=stage+1)
                if (valid_pipe[stage-1]) begin
                    negative_pipe[stage]<=negative_pipe[stage-1];
                    special_pipe[stage]<=special_pipe[stage-1];
                    exceptional_pipe[stage]<=exceptional_pipe[stage-1];
                end
            if (valid_pipe[0]) begin
                extended_reg<={{(WORK_W-WIDTH){1'b0}},magnitude_reg};
                amount_reg<=distance < 0 ? 13'(-distance) : 13'(distance);
                right_reg<=distance > 0;
                exponent_reg<=magnitude_reg == 0 || top_exp < -126 ? -12'sd126 : 12'(top_exp);
            end
            if (valid_pipe[1]) begin
                rounded_sig<=normalized;
                rounded_exp<=exponent_reg;
            end
            if (valid_pipe[2]) result<=commit_value;
        end
    end
endmodule
