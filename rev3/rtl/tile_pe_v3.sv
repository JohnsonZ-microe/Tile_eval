module tile_pe_v3 (
    input logic clk, rst_n, in_valid,
    output logic in_ready,
    input logic [2:0] in_wfmt,
    input logic [1023:0] in_weights, in_activations,
    input logic [31:0] in_activation_scales,
    input logic [255:0] in_weight_scales,
    input logic [3:0] in_token_mask,
    input logic [6:0] in_col_base,
    input logic in_first, in_last,
    input logic [31:0] in_tag,
    output logic busy, out_valid, out_done,
    output logic [31:0] out_tag,
    output logic [3:0] out_token_mask,
    output logic [7:0] out_col_mask,
    output logic [6:0] out_col_base,
    output logic [1023:0] out_results,
    output logic [1:0] out_error, error_sticky,
    input logic [6:0] rd_col,
    input logic [1:0] rd_lane,
    output logic rd_valid,
    output logic [31:0] rd_data
);
    import pe3_pkg::*;
    localparam int DOT_INDEX = INPUT_STAGES+DOT_STAGES-1;
    localparam int SCALE_INDEX = DOT_INDEX+SCALE_STAGES;
    localparam int RF_INDEX = SCALE_INDEX+RF_READ_STAGES;
    meta_t incoming, decode_meta;
    meta_t metadata [0:COMMIT_DELAY-1];
    logic [1023:0] weight_capture, activation_capture, activation_reg;
    logic [511:0] decoded [0:7];
    wire [511:0] decoded_next [0:7];
    wire [255:0] weight_bad;
    logic [319:0] occupied, claim, release_mask;
    wire accept = in_valid && in_ready;
    logic [31:0] rf [0:79][0:3];
    wire [31:0] partials [0:7][0:3], scaled [0:7][0:3], committed [0:7][0:3];
    wire dot_valid [0:7][0:3], scale_valid [0:7][0:3];
    always_comb begin
        incoming = '0;
        incoming.valid = in_valid;
        incoming.fmt = in_wfmt;
        incoming.ncols = in_wfmt == 0 || in_wfmt == 4 ? 8 : (in_wfmt == 5 ? 2 : 4);
        incoming.mask = in_token_mask;
        incoming.base = in_col_base;
        incoming.first_block = in_first;
        incoming.last_block = in_last;
        incoming.tag = in_tag;
        incoming.ascales = in_activation_scales;
        incoming.wscales = in_weight_scales;
        incoming.errors[1] = in_wfmt > 5 || int'(in_col_base)+int'(incoming.ncols) > 80 || in_token_mask == 0;
        claim = 0;
        release_mask = 0;
        for (integer column = 0; column < 80; column = column+1) begin
            if (!incoming.errors[1] && column >= int'(in_col_base) && column < int'(in_col_base)+int'(incoming.ncols))
                claim[column*4 +: 4] = in_token_mask;
            if (metadata[COMMIT_DELAY-1].valid && !metadata[COMMIT_DELAY-1].errors[1] &&
                column >= int'(metadata[COMMIT_DELAY-1].base) &&
                column < int'(metadata[COMMIT_DELAY-1].base)+int'(metadata[COMMIT_DELAY-1].ncols))
                release_mask[column*4 +: 4] = metadata[COMMIT_DELAY-1].mask;
        end
        in_ready = rst_n && !(|(occupied & claim));
        busy = 0;
        for (integer stage = 0; stage < COMMIT_DELAY; stage = stage+1) busy |= metadata[stage].valid;
        rd_valid = rst_n && !busy && rd_col < 80;
        rd_data = rd_valid ? rf[rd_col][rd_lane] : 32'b0;
    end
    for (genvar column = 0; column < 8; column = column+1) begin : columns
        for (genvar element = 0; element < 32; element = element+1) begin : unpack_weights
            wire [15:0] code4 = {12'b0, weight_capture[(column*32+element)*4 +: 4]};
            wire [15:0] code8;
            wire [15:0] code16;
            if (column < 4) assign code8 = {8'b0, weight_capture[(column*32+element)*8 +: 8]};
            else assign code8 = 0;
            if (column < 2) assign code16 = weight_capture[(column*32+element)*16 +: 16];
            else assign code16 = 0;
            wire [15:0] code = metadata[0].fmt == 0 || metadata[0].fmt == 4 ? code4 : (metadata[0].fmt == 5 ? code16 : code8);
            wire enabled = metadata[0].valid && !metadata[0].errors[1] && column < metadata[0].ncols;
            assign decoded_next[column][element*16 +: 16] = enabled ? decode_weight(code, metadata[0].fmt) : 16'b0;
            assign weight_bad[column*32+element] = enabled && metadata[0].fmt >= 1 && metadata[0].fmt <= 3 && code[6:0] == 127;
        end
        for (genvar lane = 0; lane < 4; lane = lane+1) begin : lanes
            wire enabled = metadata[1].valid && !metadata[1].errors[1] && metadata[1].mask[lane] && column < metadata[1].ncols;
            logic [31:0] rf_operand;
            always_comb begin
                rf_operand = 0;
                if (metadata[SCALE_INDEX].valid && !metadata[SCALE_INDEX].errors[1] && !metadata[SCALE_INDEX].first_block &&
                    metadata[SCALE_INDEX].mask[lane] && column < metadata[SCALE_INDEX].ncols)
                    rf_operand = rf[int'(metadata[SCALE_INDEX].base)+column][lane];
            end
            pe3_dot32 #(.WIDE(column < 2)) dot(
                .clk(clk), .rst_n(rst_n), .in_valid(enabled), .weights(decoded[column]),
                .activations(activation_reg[lane*256 +: 256]), .out_valid(dot_valid[column][lane]),
                .partial_value(partials[column][lane]), .exact_sum(), .exact_valid());
            pe3_scale scale_unit(clk, rst_n, dot_valid[column][lane], partials[column][lane],
                metadata[DOT_INDEX].fmt, metadata[DOT_INDEX].ascales[lane*8 +: 8],
                metadata[DOT_INDEX].wscales[column*32 +: 32], scale_valid[column][lane], scaled[column][lane]);
            logic [31:0] rf_read_reg, scaled_reg;
            logic rf_read_valid;
            always_ff @(posedge clk) begin
                if (!rst_n) rf_read_valid<=0;
                else begin
                    rf_read_valid<=scale_valid[column][lane];
                    if (scale_valid[column][lane]) begin
                        rf_read_reg<=rf_operand;
                        scaled_reg<=scaled[column][lane];
                    end
                end
            end
            pe3_add add_unit(.clk(clk), .rst_n(rst_n), .in_valid(rf_read_valid),
                .bypass(metadata[RF_INDEX].first_block), .left_value(rf_read_reg),
                .right_value(scaled_reg), .out_valid(), .result(), .commit_value(committed[column][lane]));
        end
    end
    always_comb begin
        decode_meta = metadata[0];
        if (metadata[0].valid && !metadata[0].errors[1]) begin
            decode_meta.errors[0] = |weight_bad;
            for (integer column = 0; column < 8; column = column+1)
                if (column < metadata[0].ncols && (metadata[0].fmt == 0 || metadata[0].fmt == 1) &&
                    metadata[0].wscales[column*32 +: 8] == 255) decode_meta.errors[0] = 1;
            for (integer lane = 0; lane < 4; lane = lane+1) begin
                if (metadata[0].mask[lane]) begin
                    if (metadata[0].ascales[lane*8 +: 8] == 255) decode_meta.errors[0] = 1;
                    for (integer element = 0; element < 32; element = element+1)
                        if (activation_capture[lane*256+element*8 +: 7] == 127) decode_meta.errors[0] = 1;
                end
            end
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            occupied <= 0;
            for (integer stage = 0; stage < COMMIT_DELAY; stage = stage+1) metadata[stage] <= '0;
            for (integer column = 0; column < 80; column = column+1)
                for (integer lane = 0; lane < 4; lane = lane+1) rf[column][lane] <= 0;
            out_valid <= 0;
            out_done <= 0;
            out_tag <= 0;
            out_col_base <= 0;
            out_col_mask <= 0;
            out_token_mask <= 0;
            out_results <= 0;
            out_error <= 0;
            error_sticky <= 0;
        end else begin
            occupied <= (occupied & ~release_mask) | (accept ? claim : 320'b0);
            metadata[0] <= accept ? incoming : '0;
            metadata[1] <= decode_meta;
            for (integer stage = 2; stage < COMMIT_DELAY; stage = stage+1) begin
                metadata[stage] <= metadata[stage-1];
                if (stage > DOT_INDEX) begin
                    metadata[stage].ascales <= 0;
                    metadata[stage].wscales <= 0;
                    metadata[stage].fmt <= 0;
                end
                if (stage > RF_INDEX) metadata[stage].first_block <= 0;
            end
            if (accept && !incoming.errors[1]) begin
                weight_capture <= in_weights;
                activation_capture <= in_activations;
            end
            if (metadata[0].valid && !metadata[0].errors[1]) begin
                for (integer column = 0; column < 8; column = column+1) decoded[column] <= decoded_next[column];
                for (integer lane = 0; lane < 4; lane = lane+1)
                    activation_reg[lane*256 +: 256] <= metadata[0].mask[lane] ? activation_capture[lane*256 +: 256] : 256'b0;
            end
            out_valid <= metadata[COMMIT_DELAY-1].valid;
            out_done <= metadata[COMMIT_DELAY-1].valid && metadata[COMMIT_DELAY-1].last_block && !metadata[COMMIT_DELAY-1].errors[1];
            if (metadata[COMMIT_DELAY-1].valid) begin
                out_tag <= metadata[COMMIT_DELAY-1].tag;
                out_col_base <= metadata[COMMIT_DELAY-1].base;
                out_error <= metadata[COMMIT_DELAY-1].errors;
                error_sticky <= error_sticky | metadata[COMMIT_DELAY-1].errors;
                out_token_mask <= metadata[COMMIT_DELAY-1].errors[1] ? 4'b0 : metadata[COMMIT_DELAY-1].mask;
                out_col_mask <= metadata[COMMIT_DELAY-1].errors[1] ? 8'b0 : 8'((1 << metadata[COMMIT_DELAY-1].ncols)-1);
                for (integer column = 0; column < 8; column = column+1) begin
                    for (integer lane = 0; lane < 4; lane = lane+1) begin
                        out_results[(column*4+lane)*32 +: 32] <= 0;
                        if (!metadata[COMMIT_DELAY-1].errors[1] && column < metadata[COMMIT_DELAY-1].ncols && metadata[COMMIT_DELAY-1].mask[lane]) begin
                            out_results[(column*4+lane)*32 +: 32] <= committed[column][lane];
                            rf[int'(metadata[COMMIT_DELAY-1].base)+column][lane] <= committed[column][lane];
                        end
                    end
                end
            end
        end
    end
endmodule
