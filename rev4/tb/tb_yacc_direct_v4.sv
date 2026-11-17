`timescale 1ns/1ps
// Explicit experimental top; production Tile keeps DIRECT_DRAIN=0.
module tb_yacc_direct_v4;
    tb_yacc_v4 #(.DIRECT_DRAIN(1)) probe();
endmodule
