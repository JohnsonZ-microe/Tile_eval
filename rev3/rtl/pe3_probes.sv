module pe3_dot_wide (
    input logic clk,rst_n,in_valid,
    input logic [511:0] weights,
    input logic [255:0] activations,
    output wire out_valid,
    output wire [31:0] partial_value
);
    pe3_dot32 #(.WIDE(1)) dut(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),.weights(weights),
        .activations(activations),.out_valid(out_valid),.partial_value(partial_value),.exact_sum(),.exact_valid());
endmodule

module pe3_round_probe #(parameter int WIDTH=285) (
    input logic clk,rst_n,in_valid,negative,
    input logic [WIDTH-1:0] magnitude,
    input logic signed [11:0] binary_exponent,
    output wire out_valid,
    output wire [31:0] result
);
    pe3_round_pipe #(.WIDTH(WIDTH)) dut(.clk(clk),.rst_n(rst_n),.in_valid(in_valid),
        .magnitude(magnitude),.binary_exponent(binary_exponent),.negative(negative),
        .special(1'b0),.exceptional(32'b0),.out_valid(out_valid),.result(result),.commit_value());
endmodule
