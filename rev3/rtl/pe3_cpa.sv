module pe3_cpa2 #(parameter int WIDTH=285, parameter int CHUNK=32,
                  parameter int BLOCKS=(WIDTH+CHUNK-1)/CHUNK, parameter int PAD=BLOCKS*CHUNK) (
    input logic clk, rst_n, in_valid,
    input logic [WIDTH-1:0] left_value, right_value,
    output logic out_valid,
    output logic [WIDTH-1:0] result
);
    wire [PAD-1:0] left_extended={{(PAD-WIDTH){1'b0}},left_value};
    wire [PAD-1:0] right_extended={{(PAD-WIDTH){1'b0}},right_value};
    logic valid_reg;
    logic [CHUNK-1:0] sum_zero [0:BLOCKS-1], sum_one [0:BLOCKS-1];
    logic [BLOCKS-1:0] generate_reg, propagate_reg;
    wire [BLOCKS:0] carry;
    wire [PAD-1:0] selected;
    assign carry[0]=0;
    for (genvar block_index=0; block_index<BLOCKS; block_index=block_index+1) begin : blocks
        wire [CHUNK:0] zero_sum={1'b0,left_extended[block_index*CHUNK +: CHUNK]}+
                                    {1'b0,right_extended[block_index*CHUNK +: CHUNK]};
        wire [CHUNK:0] one_sum={1'b0,left_extended[block_index*CHUNK +: CHUNK]}+
                                   {1'b0,right_extended[block_index*CHUNK +: CHUNK]}+{{CHUNK{1'b0}},1'b1};
        wire [block_index:0] terms;
        for (genvar origin=0; origin<=block_index; origin=origin+1) begin : prefix
            if (origin == block_index) assign terms[origin]=generate_reg[origin];
            else assign terms[origin]=generate_reg[origin] && (&propagate_reg[block_index:origin+1]);
        end
        assign carry[block_index+1]=|terms;
        assign selected[block_index*CHUNK +: CHUNK]=carry[block_index] ? sum_one[block_index] : sum_zero[block_index];
        always_ff @(posedge clk)
            if (rst_n && in_valid) begin
                sum_zero[block_index]<=zero_sum[CHUNK-1:0];
                sum_one[block_index]<=one_sum[CHUNK-1:0];
                generate_reg[block_index]<=zero_sum[CHUNK];
                propagate_reg[block_index]<=&zero_sum[CHUNK-1:0];
            end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_reg<=0;
            out_valid<=0;
        end else begin
            valid_reg<=in_valid;
            out_valid<=valid_reg;
            if (valid_reg) result<=selected[WIDTH-1:0];
        end
    end
endmodule
