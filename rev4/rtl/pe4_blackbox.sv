// DC logic-check stubs. Never instantiated in simulation; only the guards
// under `ifdef PE4_MEM_BLACKBOX` (pe4_sram/pe4_rram/pe4_bus/pe4_act) bind
// these empty modules so Design Compiler treats every large memory and the
// sigmoid ROM as an unmapped macro. The mode is set by syn/run_dc.tcl
// (disable with DC_FULL_MEM=1, not recommended) and the resulting unmapped
// macros are listed in reports/unmapped_macros.rpt (docs/WIDTHS.md 1).
module pe4_bb_sram2 #(
    parameter int WIDTH = 1024, parameter int DEPTH = 72, parameter int LAT = 2
) (
    input  logic clk,
    input  logic we,
    input  logic [WIDTH/8-1:0] wbe,
    input  logic [$clog2(DEPTH)-1:0] waddr, raddr,
    input  logic [WIDTH-1:0] wdata,
    input  logic re,
    output logic [WIDTH-1:0] rdata,
    output logic rvalid
);
endmodule

module pe4_bb_rram #(
    parameter int WORDS = 8192
) (
    input  logic clk, rst_n,
    input  logic run_active,
    input  logic rd_req,
    output logic rd_ready,
    input  logic [20:0] rd_addr,
    output logic rd_valid,
    output logic [1023:0] rd_data,
    input  logic sim_load,
    input  logic [20:0] sim_addr,
    input  logic [1023:0] sim_data,
    output logic load_err
);
endmodule

module pe4_bb_dpr #(
    parameter int WIDTH = 533, parameter int DEPTH = 128
) (
    input  logic clk,
    input  logic we,
    input  logic [$clog2(DEPTH)-1:0] waddr, raddr,
    input  logic [WIDTH-1:0] wdata,
    output logic [WIDTH-1:0] rdata
);
endmodule

module pe4_bb_rom #(
    parameter int DEPTH = 65536, parameter int WIDTH = 32
) (
    input  logic clk,
    input  logic [$clog2(DEPTH)-1:0] code,
    output logic [WIDTH-1:0] value
);
endmodule
