// Unified synchronous storage wrapper (rev4). Two behaviours:
//   LAT=2: request presented during E0 -> rdata stable during E2
//          (operand staging; downstream samples at the E2 edge).
//   LAT=3: request presented during E0 -> rdata stable during E3 (RRAM model).
// One read request per cycle, fixed return latency, never stalls.
// Data is NOT cleared by reset; only controller-side valid/ownership state
// resets. Same-address read-during-write is prevented by controllers.
// The default array is behavioural: it is NOT physical SRAM area. Bind compiled
// macros via PE4_SRAM_MACRO before any area statement (docs/WIDTHS.md).
module pe4_sram #(
    parameter int WIDTH = 1024,
    parameter int DEPTH = 72,
    parameter int LAT = 2
) (
    input  logic clk,
    input  logic we,
    input  logic [WIDTH/8-1:0] wbe,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0] wdata,
    input  logic re,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0] rdata,
    output logic rvalid
);
`ifdef PE4_MEM_BLACKBOX
    // DC logic-check mode: unmapped macro stub (reports/unmapped_macros.rpt)
    pe4_bb_sram2 #(.WIDTH(WIDTH), .DEPTH(DEPTH), .LAT(LAT)) bb_i (
        .clk(clk), .we(we), .wbe(wbe), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata), .rvalid(rvalid));
`else
    localparam int AW = $clog2(DEPTH);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [LAT-2:0] pipe_v;
    logic [AW-1:0] pipe_a [0:LAT-2];
`ifdef PE4_SRAM_MACRO
    // Vendor macro substitution point. The behavioural model below must be
    // replaced by the compiled instance before any area or timing claim.
    $error("PE4_SRAM_MACRO binding not supplied");
`else
    always_ff @(posedge clk) begin
        if (we)
            for (int i = 0; i < WIDTH/8; i++)
                if (wbe[i]) mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
        if (re) begin
            pipe_v[0] <= 1'b1;
            pipe_a[0] <= raddr;
        end else pipe_v[0] <= 1'b0;
        for (int s = 1; s < LAT-1; s++) begin
            pipe_v[s] <= pipe_v[s-1];
            pipe_a[s] <= pipe_a[s-1];
        end
    end
    // generate-time selection: a procedural (LAT == 2) branch would still
    // statically evaluate pipe_a[LAT-3] for LAT=2 and trip SIOB (VCS)
    if (LAT == 2) begin : lat2
        always_ff @(posedge clk) begin
            rdata  <= mem[pipe_a[0]];      // mem@E1, out reg end of E1
            rvalid <= pipe_v[0];
        end
    end else begin : lat3plus
        logic [WIDTH-1:0] mem_q;
        always_ff @(posedge clk) begin
            mem_q  <= mem[pipe_a[LAT-3]];  // extra internal stage for LAT>=3
            rdata  <= mem_q;
            rvalid <= pipe_v[LAT-2];
        end
    end
`endif
`endif
endmodule

// RRAM SRAM model: 1024-bit words, parameterised capacity (tests allocate
// only the window they use), LAT=3 return, 3-entry logical prefetch credit
// budget covering in-flight requests plus unconsumed returns, and a load
// port that is refused (load_err) while any phase is active.
module pe4_rram #(
    parameter int WORDS = 4096
) (
    input  logic clk, rst_n,
    input  logic run_active,
    input  logic rd_req,
    output logic rd_ready,
    input  logic [20:0] rd_addr,
    output logic rd_valid,          // high during E3; consumer captures then
    output logic [1023:0] rd_data,
    input  logic sim_load,
    input  logic [20:0] sim_addr,
    input  logic [1023:0] sim_data,
    output logic load_err
);
    import pe4_pkg::*;
`ifdef PE4_MEM_BLACKBOX
    // DC logic-check mode: unmapped macro stub (reports/unmapped_macros.rpt)
    pe4_bb_rram #(.WORDS(WORDS)) bb_i (
        .clk(clk), .rst_n(rst_n), .run_active(run_active),
        .rd_req(rd_req), .rd_ready(rd_ready), .rd_addr(rd_addr),
        .rd_valid(rd_valid), .rd_data(rd_data),
        .sim_load(sim_load), .sim_addr(sim_addr), .sim_data(sim_data),
        .load_err(load_err));
`else
    logic [1023:0] mem [0:WORDS-1];
    logic pipe_v0, pipe_v1;
    logic [20:0] pipe_a0, pipe_a1;
    logic [1023:0] mem_q;
    logic [1:0] outstanding;
    int delta;
    assign rd_ready = (outstanding < 2'(RRAM_CREDITS));
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pipe_v0 <= 0; pipe_v1 <= 0;
            pipe_a0 <= 0; pipe_a1 <= 0;
            mem_q <= 0;
            rd_valid <= 0;
            rd_data <= 0;
            outstanding <= 0;
            load_err <= 0;
        end else begin
            load_err <= 0;
            if (sim_load) begin
                if (run_active) load_err <= 1;
                else if (sim_addr < WORDS) mem[sim_addr] <= sim_data;
            end
            pipe_v0 <= rd_req && rd_ready;
            pipe_a0 <= rd_addr;
            pipe_v1 <= pipe_v0;
            pipe_a1 <= pipe_a0;
            mem_q   <= mem[pipe_a0];
            rd_valid <= pipe_v1;
            rd_data  <= mem_q;
            // +1 per accepted request, -1 when the consumer captures a return
            delta = 0;
            if (rd_req && rd_ready) delta = delta + 1;
            if (rd_valid) delta = delta - 1;
            outstanding <= 2'(int'(outstanding) + delta);
        end
    end
`endif
endmodule

