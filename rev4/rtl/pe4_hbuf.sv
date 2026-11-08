// h buffers: 2 banks x 9,216 B data SRAM (72 rows x 1024 b = 4 lanes x 32
// FP8) + per-bank UE8M0 scale flops (72 x 4 x 8 b) with per-(row,lane)
// written flags. The quantizer writes one lane-block per cycle (byte enables
// cover only that lane's 256 b of the row); D reads one full row (all lanes)
// per k-block with LAT=2. Ownership and the full fence live here: a bank is
// ready for D only when it is owned and every row has all expected lanes.
// A write to an unowned bank, a lane >= n_tok, or a duplicate (row,lane)
// raises wr_err (routed to ERR_H_ORDER / ERR_H_BANK at the top).
module pe4_hbuf (
    input  logic clk, rst_n,
    input  logic wr_valid,
    input  logic wr_bank,
    input  logic [2:0] wr_lane,
    input  logic [6:0] wr_idx,
    input  logic [255:0] wr_q,
    input  logic [7:0] wr_se,
    output logic wr_err,
    input  logic rd_req,
    input  logic rd_bank,
    input  logic [6:0] rd_idx,
    output logic [1023:0] rd_data,
    output logic [31:0] rd_scales,
    output logic rd_valid,
    input  logic own_take,
    input  logic own_release,
    input  logic own_bank,
    input  logic [7:0] own_pass,
    input  logic [2:0] own_ntok,
    output logic [1:0] owner_valid,
    output logic [1:0] bank_ready,
    output logic [7:0] owner_pass0,
    output logic [7:0] owner_pass1
);
    logic [7:0] hscale [0:1][0:71][0:3];
    logic lane_seen [0:1][0:71][0:3];
    logic owner_v [0:1];
    logic [7:0] owner_p [0:1];
    logic [2:0] exp_ntok [0:1];
    logic take_illegal;
    logic ready_c [0:1];
    always_comb begin
        for (int b = 0; b < 2; b++) begin
            ready_c[b] = owner_v[b];
            for (int r = 0; r < 72; r++)
                for (int l = 0; l < 4; l++)
                    if (l < int'(exp_ntok[b]) && !lane_seen[b][r][l])
                        ready_c[b] = 1'b0;
        end
    end
    logic wr_bad;
    always_comb begin
        wr_bad = 1'b0;
        if (wr_valid) begin
            if (!owner_v[wr_bank]) wr_bad = 1'b1;
            else if (wr_idx >= 72 || wr_lane >= 4 ||
                     wr_lane >= exp_ntok[wr_bank]) wr_bad = 1'b1;
            else if (lane_seen[wr_bank][wr_idx][wr_lane]) wr_bad = 1'b1;
        end
        take_illegal = own_take && owner_v[own_bank];
    end
    logic [127:0] wbe_c;
    logic [1023:0] wdata_c;
    always_comb begin
        // variable-base +: selects; constant loop init/bounds (DC ELAB-800)
        wbe_c = '0;
        wbe_c[32*wr_lane +: 32] = ~32'b0;
        wdata_c = '0;
        wdata_c[256*wr_lane +: 256] = wr_q;
    end
    logic [1023:0] q0, q1;
    logic unused_v0, unused_v1;
    pe4_sram #(.WIDTH(1024), .DEPTH(72), .LAT(2)) bank0 (
        .clk(clk), .we(wr_valid && !wr_bank && !wr_bad), .wbe(wbe_c),
        .waddr(wr_idx), .wdata(wdata_c),
        .re(rd_req && !rd_bank), .raddr(rd_idx),
        .rdata(q0), .rvalid(unused_v0));
    pe4_sram #(.WIDTH(1024), .DEPTH(72), .LAT(2)) bank1 (
        .clk(clk), .we(wr_valid && wr_bank && !wr_bad), .wbe(wbe_c),
        .waddr(wr_idx), .wdata(wdata_c),
        .re(rd_req && rd_bank), .raddr(rd_idx),
        .rdata(q1), .rvalid(unused_v1));
    logic vq, vqq, bankq, bankqq;
    logic [6:0] idxq, idxqq;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vq <= 0; vqq <= 0;
            bankq <= 0; bankqq <= 0;
            idxq <= 0; idxqq <= 0;
        end else begin
            vq <= rd_req;    vqq <= vq;
            bankq <= rd_bank; bankqq <= bankq;
            idxq <= rd_idx;  idxqq <= idxq;
        end
    end
    always_comb begin
        rd_data = bankqq ? q1 : q0;
        rd_scales = '0;
        for (int l = 0; l < 4; l++)
            rd_scales[8*l +: 8] = hscale[bankqq][idxqq][l];
    end
    assign rd_valid = vqq;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            owner_v <= '{0, 0};
            owner_p <= '{0, 0};
            exp_ntok <= '{0, 0};
            wr_err <= 0;
            for (int b = 0; b < 2; b++)
                for (int r = 0; r < 72; r++)
                    for (int l = 0; l < 4; l++) begin
                        lane_seen[b][r][l] <= 0;
                        hscale[b][r][l] <= 0;
                    end
        end else begin
            wr_err <= wr_bad || take_illegal;
            if (own_take && !owner_v[own_bank]) begin
                owner_v[own_bank] <= 1;
                owner_p[own_bank] <= own_pass;
                exp_ntok[own_bank] <= own_ntok;
                for (int r = 0; r < 72; r++)
                    for (int l = 0; l < 4; l++)
                        lane_seen[own_bank][r][l] <= 0;
            end
            if (own_release) owner_v[own_bank] <= 0;
            if (wr_valid && !wr_bad) begin
                lane_seen[wr_bank][wr_idx][wr_lane] <= 1;
                hscale[wr_bank][wr_idx][wr_lane] <= wr_se;
            end
        end
    end
    assign owner_valid = {owner_v[1], owner_v[0]};
    assign bank_ready = {ready_c[1], ready_c[0]};
    assign owner_pass0 = owner_p[0];
    assign owner_pass1 = owner_p[1];
endmodule
