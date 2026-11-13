// Down-link demultiplexer, 128 x 516 b x FIFO, SYNC generation and the
// up-link launcher with credits (frozen data_bus v0.12 subset).
// Down: 512 b payload + 32 b sideband {type[2:0], pass_id[7:0], lane[2:0],
// idx[9:0], last, rsvd[7]}; types CMD/X/XS/H/CTRL decoded combinationally;
// PGM and reserved types raise errors and are dropped (rev4 subset).
// X/XS enter the shared 128 x 516 b FIFO (payload + {kind,lane,idx[8:0]});
// overflow is a credit violation (X_FIFO_OVF). One pop per cycle by the
// scheduler produces one registered sync[0] pulse.
// Up: one 128 b phit + 24 b sideband per beat; credits reset to 6 (tile->L1),
// up_credit returns 0-2 per cycle, cap 6, over-return sets UP_CREDIT.
// Launcher priority: H_UP (dedicated slot), Y_UP, STATUS; a started packet
// holds the link through its last beat; credits only delay, never reorder.
module pe4_bus #(parameter logic [6:0] TILE_ID = 7'd16) (
    input  logic clk, rst_n,
    input  logic dn_valid,
    input  logic [511:0] dn_payload,
    input  logic [31:0] dn_sideband,
    output logic cmd_valid,
    output logic [511:0] cmd_payload,
    output logic [7:0] cmd_pass,
    output logic xfifo_push, xfifo_kind, xfifo_ovf,
    output logic [2:0] xfifo_in_lane,
    output logic [9:0] xfifo_in_idx,
    output logic [511:0] xfifo_in_data,
    output logic h_valid,
    output logic [2:0] h_lane,
    output logic [9:0] h_idx,
    output logic [7:0] h_pass,
    output logic [511:0] h_data,
    output logic ctrl_valid,
    output logic [3:0] ctrl_op,
    output logic [6:0] ctrl_target,
    output logic [11:0] ctrl_addr,
    output logic [31:0] ctrl_data,
    output logic [7:0] ctrl_tag,
    output logic dn_reserved,           // type 6/7 seen this cycle
    input  logic xfifo_pop,
    output logic xfifo_out_kind,
    output logic [2:0] xfifo_out_lane,
    output logic [9:0] xfifo_out_idx,
    output logic [511:0] xfifo_out_data,
    output logic [7:0] xfifo_out_pass,
    output logic xfifo_empty,
    output logic [7:0] xfifo_level,
    output logic sync0,
    input  logic [1:0] up_credit,
    output logic up_valid,
    output logic [127:0] up_payload,
    output logic [23:0] up_sideband,
    output logic up_credit_err,
    output logic credit_stall,
    input  logic hup_valid,
    output logic hup_ready,
    input  logic [127:0] hup_payload,
    input  logic hup_last,
    input  logic [7:0] hup_src,
    input  logic [7:0] hup_tag,
    input  logic ysrc_valid,
    output logic ysrc_ready,
    input  logic [127:0] ysrc_payload,
    input  logic ysrc_last,
    input  logic [1:0] ysrc_segment,
    input  logic [7:0] ysrc_tag,
    input  logic [7:0] ysrc_src,
    input  logic st_valid,
    output logic st_ready,
    input  logic [127:0] st_payload,
    input  logic [7:0] st_tag,
    input  logic [7:0] st_src
);
    import pe4_pkg::*;
    // ---- down decode ----
    wire [2:0] dtype = dn_sideband[2:0];
    assign cmd_valid   = dn_valid && dtype == FT_CMD;
    assign cmd_payload = dn_payload;
    assign cmd_pass    = dn_sideband[10:3];
    assign xfifo_push  = dn_valid && (dtype == FT_X || dtype == FT_XS);
    assign xfifo_kind  = dtype == FT_XS;
    assign xfifo_in_lane = dn_sideband[13:11];
    assign xfifo_in_idx  = dn_sideband[23:14];
    assign xfifo_in_data = dn_payload;
    assign h_valid = dn_valid && dtype == FT_H;
    assign h_lane  = dn_sideband[13:11];
    assign h_idx   = dn_sideband[23:14];
    assign h_pass  = dn_sideband[10:3];
    assign h_data  = dn_payload;
    assign ctrl_valid  = dn_valid && dtype == FT_CTRL &&
                        (ctrl_target == TILE_ID || ctrl_target == 7'h7f);
    assign ctrl_op     = dn_payload[3:0];
    assign ctrl_target = dn_payload[10:4];
    assign ctrl_addr   = dn_payload[22:11];
    assign ctrl_data   = dn_payload[54:23];
    assign ctrl_tag    = dn_sideband[10:3];
    assign dn_reserved = dn_valid && (dtype == 3'd6 || dtype == 3'd7);
    // ---- x FIFO: rev4 entry = 533 b {pass[7:0], lane[2:0], idx[9:0], kind,
    // payload[511:0]} (the frozen 516 b entry cannot carry the arrival
    // metadata needed for the X_ORDER check; +272 B/tile, docs/WIDTHS.md) ----
    logic [6:0] fhead, ftail;
    logic [7:0] fcount;
    wire fifo_we = xfifo_push && (fcount != XFIFO_DEPTH);
    wire [533:0] fifo_wd = {dn_sideband[10:3], dn_sideband[13:11],
                            dn_sideband[23:14], dtype == FT_XS, dn_payload};
`ifdef PE4_MEM_BLACKBOX
    logic [533:0] fmem_q;
    pe4_bb_dpr #(.WIDTH(534), .DEPTH(XFIFO_DEPTH)) fmem_i (
        .clk(clk), .we(fifo_we), .waddr(fhead), .wdata(fifo_wd),
        .raddr(ftail), .rdata(fmem_q));
    wire [533:0] fmem_head_v = fmem_q;
`else
    logic [533:0] fmem [0:XFIFO_DEPTH-1];
    wire [533:0] fmem_head_v = fmem[ftail];
`endif
    assign xfifo_empty = (fcount == 0);
    assign xfifo_level = fcount;
    assign xfifo_out_kind = fmem_head_v[512];
    assign xfifo_out_lane = fmem_head_v[525:523];
    assign xfifo_out_idx  = fmem_head_v[522:513];
    assign xfifo_out_pass = fmem_head_v[533:526];
    assign xfifo_out_data = fmem_head_v[511:0];
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fhead <= 0; ftail <= 0; fcount <= 0;
            xfifo_ovf <= 0;
            sync0 <= 0;
        end else begin
            xfifo_ovf <= 0;
            sync0 <= xfifo_pop && fcount != 0;
            // R4-006: single next-state update for simultaneous push+pop
            if (xfifo_push && fcount == XFIFO_DEPTH) begin
                xfifo_ovf <= 1;
            end
            begin
                if (fifo_we) begin
`ifndef PE4_MEM_BLACKBOX
                    fmem[fhead] <= fifo_wd;
`endif
                    fhead <= fhead + 1;
                end
                if (xfifo_pop && fcount != 0)
                    ftail <= ftail + 1;
                case ({fifo_we, xfifo_pop && fcount != 0})
                    2'b10: fcount <= fcount + 1;
                    2'b01: fcount <= fcount - 1;
                    default: ;
                endcase
            end
        end
    end
    // ---- up launcher ----
    logic [2:0] credit;
    logic [1:0] grant;         // 0 none, 1 H, 2 Y, 3 STATUS
    logic active_valid;
    logic [1:0] active_src;
    logic beat_fire;
    // credit counter: reset 6, +up_credit (0-2), -1 per sent beat, cap 6
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            credit <= 3'(UP_CREDITS);
            up_credit_err <= 0;
        end else begin
            up_credit_err <= 0;
            if (int'(credit) + int'(up_credit) > UP_CREDITS)
                up_credit_err <= 1;
            credit <= 3'(int'(credit) - int'(beat_fire) +
                          (int'(credit) + int'(up_credit) > UP_CREDITS
                           ? 0 : int'(up_credit)));
        end
    end
    // arbiter: H first (dedicated slot, M22), then Y, then STATUS; a packet
    // that started keeps the link through its accepted last beat
    always_comb begin
        grant = 0;
        if (active_valid) grant = active_src;
        else if (hup_valid) grant = 2'd1;
        else if (ysrc_valid) grant = 2'd2;
        else if (st_valid) grant = 2'd3;
    end
    assign beat_fire = (credit != 0) &&
        ((grant == 2'd1 && hup_valid) ||
         (grant == 2'd2 && ysrc_valid) ||
         (grant == 2'd3 && st_valid));
    assign credit_stall = (credit == 0) &&
        ((grant == 2'd1 && hup_valid) ||
         (grant == 2'd2 && ysrc_valid) ||
         (grant == 2'd3 && st_valid));
    assign hup_ready = beat_fire && (grant == 2'd1);
    assign ysrc_ready = beat_fire && (grant == 2'd2);
    assign st_ready  = beat_fire && (grant == 2'd3);
    logic hup_last_q, ysrc_last_q;
    logic [1:0] ysrc_seg_q;
    logic [7:0] ysrc_tag_q, st_tag_q, hup_tag_q;
    logic [6:0] hsrc_q, ysrc_src_q, stsrc_q;   // src is 7-bit (R4-020)
    logic [127:0] pay_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            up_valid <= 0;
            up_payload <= 0;
            up_sideband <= 0;
            active_valid <= 0;
            active_src <= 0;
            hup_last_q <= 0; ysrc_last_q <= 0; ysrc_seg_q <= 0;
            ysrc_tag_q <= 0; hsrc_q <= 0; ysrc_src_q <= 0; stsrc_q <= 0;
            st_tag_q <= 0; pay_q <= 0;
        end else begin
            up_valid <= beat_fire;
            if (beat_fire) begin
                case (grant)
                    2'd1: begin
                        up_payload <= hup_payload;
                        // UP_SB (LSB-first): type@1:0 src@8:2 tag@16:9
                        // last@17 nphit@19:18 rsvd@23:20
                        up_sideband <= {4'b0, 2'd0, hup_last,
                                        hup_tag, hup_src[6:0], 2'(UP_H)};
                        pay_q <= hup_payload;
                        hup_last_q <= hup_last;
                        active_src <= 2'd1;
                        active_valid <= !hup_last;
                    end
                    2'd2: begin
                        up_payload <= ysrc_payload;
                        // UP_SB_Y (LSB-first): type@1:0 src@8:2 tag@16:9
                        // last@17 nphit@19:18 segment@21:20 rsvd@23:22
                        up_sideband <= {2'b0, ysrc_segment, 2'd0,
                                        ysrc_last, ysrc_tag, ysrc_src[6:0],
                                        2'(UP_Y)};
                        ysrc_last_q <= ysrc_last;
                        ysrc_seg_q <= ysrc_segment;
                        active_src <= 2'd2;
                        active_valid <= !ysrc_last;
                    end
                    default: begin
                        up_payload <= st_payload;
                        // single-phit STATUS/ALARM (P3-3): nphit=0, last=1
                        up_sideband <= {4'b0, 2'd0, 1'b1,
                                        st_tag, st_src[6:0], 2'(UP_STATUS)};
                        active_src <= 2'd3;
                        active_valid <= 1'b0;
                    end
                endcase
            end
            // capture source addresses and tags on the FIRST beat of each
            // packet (grant cycle), not every valid cycle (R4-020)
            if (beat_fire && grant == 2'd1) begin
                hsrc_q <= hup_src[6:0];
                hup_tag_q <= hup_tag;
            end
            if (beat_fire && grant == 2'd2) begin
                ysrc_src_q <= ysrc_src[6:0];
                ysrc_tag_q <= ysrc_tag;
                ysrc_seg_q <= ysrc_segment;
            end
            if (beat_fire && grant == 2'd3) begin
                stsrc_q <= st_src[6:0];
                st_tag_q <= st_tag;
            end
        end
    end
endmodule

