// X/XS operand staging: 2 banks x R tokens x 64 B for X and for XS
// (1,024 B data budget, token-banked macros with independent ports).
// One 64 B X/XS flit is written per cycle; one read returns the operands of
// all four tokens for one k-block. Data is not reset; ownership and the
// expected X/XS order live in pe4_sched. X flit idx covers k-blocks 2*idx and
// 2*idx+1 with bank idx%2; XS flit idx covers k-blocks 64*idx.. with bank
// idx%2. Returns follow the LAT=2 rule: rd_req during E0 -> x_data/xs_data
// stable during E2 (rd_valid high); the scheduler samples them into its
// operand-holding register at the E2 edge.
module pe4_staging (
    input  logic clk, rst_n,
    input  logic wr_x, wr_xs,
    input  logic [2:0] wr_lane,
    input  logic [9:0] wr_idx,
    input  logic [511:0] wr_data,
    input  logic rd_req,
    input  logic [7:0] rd_kb,
    output logic [1023:0] x_data,
    output logic [31:0] xs_data,
    output logic rd_valid
);
    logic [2047:0] xq;    // 4 tokens x 512 b registered macro outputs
    logic [2047:0] xsq;
    logic xbank_r, xbank_rr, xsbank_r, xsbank_rr;
    logic [7:0] kb_q, kb_qq;
    logic req_q, req_qq;
    for (genvar t = 0; t < 4; t++) begin : xtok
        pe4_sram #(.WIDTH(512), .DEPTH(2), .LAT(2)) xm (
            .clk(clk), .we(wr_x && 3'(t) == wr_lane), .wbe('1),
            .waddr(wr_idx[0]), .wdata(wr_data),
            .re(rd_req), .raddr(rd_kb[1]),
            .rdata(xq[512*t +: 512]), .rvalid());
    end
    for (genvar t = 0; t < 4; t++) begin : xstok
        pe4_sram #(.WIDTH(512), .DEPTH(2), .LAT(2)) xs (
            .clk(clk), .we(wr_xs && 3'(t) == wr_lane), .wbe('1),
            .waddr(wr_idx[0]), .wdata(wr_data),
            .re(rd_req), .raddr(rd_kb[6]),
            .rdata(xsq[512*t +: 512]), .rvalid());
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_q <= 0; req_qq <= 0;
            kb_q <= 0; kb_qq <= 0;
        end else begin
            req_q <= rd_req;  req_qq <= req_q;
            kb_q <= rd_kb;    kb_qq <= kb_q;
        end
    end
    // VER-260 fix: DC requires genvar for variable part-select bases
    genvar mt;
    generate
        for (mt = 0; mt < 4; mt++) begin : stg_mux
            assign x_data[256*mt +: 256] = kb_qq[0] ? xq[512*mt+511:512*mt+256]
                                                     : xq[512*mt +: 256];
            assign xs_data[8*mt +: 8] = xsq[512*mt + 8*kb_qq[5:0] +: 8];
        end
    endgenerate
    assign rd_valid = req_qq;
endmodule

