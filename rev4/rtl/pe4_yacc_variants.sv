// Matched synthesis shells: same ports and hierarchy, only parameter differs.
module pe4_yacc_baseline (
    input  logic clk, rst_n,
    input  logic load_valid,
    input  logic [6:0] load_base,          // column base 0..79 (any alignment)
    input  logic [7:0] load_cen,           // per-column enables (formats < 8 cols)
    input  logic [1023:0] load_data,       // (col*4+lane) x FP32
    input  logic commit_trigger,
    input  logic commit_bank,
    input  logic commit_bias_en,          // CMD first && CTX BIAS_EN
    input  logic [1279:0] commit_db,      // 80 x BF16 down bias
    input  logic [3:0] commit_mask,
    input  logic [5:0] commit_slots [0:3],
    input  logic [31:0] commit_weights [0:3],
    output logic commit_busy,
    output logic commit_rd_active,         // same-bank DRAIN yield hint
    output logic commit_bank_id,
    output logic drain_yield,
    input  logic drain_valid,
    input  logic drain_bank,
    input  logic [5:0] drain_slot,
    input  logic [7:0] drain_col_start,
    input  logic [7:0] drain_count,
    input  logic [1:0] drain_segment,
    input  logic drain_last_seg,
    output logic drain_illegal,
    output logic v0_drain,
    output logic yb_valid,
    input  logic yb_ready,
    output logic [127:0] yb_payload,
    output logic yb_last,
    output logic [1:0] yb_segment,
    output logic [7:0] yb_tag
);
    pe4_yacc #(.DIRECT_DRAIN(0)) core(.*);
endmodule

module pe4_yacc_direct (
    input  logic clk, rst_n,
    input  logic load_valid,
    input  logic [6:0] load_base,          // column base 0..79 (any alignment)
    input  logic [7:0] load_cen,           // per-column enables (formats < 8 cols)
    input  logic [1023:0] load_data,       // (col*4+lane) x FP32
    input  logic commit_trigger,
    input  logic commit_bank,
    input  logic commit_bias_en,          // CMD first && CTX BIAS_EN
    input  logic [1279:0] commit_db,      // 80 x BF16 down bias
    input  logic [3:0] commit_mask,
    input  logic [5:0] commit_slots [0:3],
    input  logic [31:0] commit_weights [0:3],
    output logic commit_busy,
    output logic commit_rd_active,         // same-bank DRAIN yield hint
    output logic commit_bank_id,
    output logic drain_yield,
    input  logic drain_valid,
    input  logic drain_bank,
    input  logic [5:0] drain_slot,
    input  logic [7:0] drain_col_start,
    input  logic [7:0] drain_count,
    input  logic [1:0] drain_segment,
    input  logic drain_last_seg,
    output logic drain_illegal,
    output logic v0_drain,
    output logic yb_valid,
    input  logic yb_ready,
    output logic [127:0] yb_payload,
    output logic yb_last,
    output logic [1:0] yb_segment,
    output logic [7:0] yb_tag
);
    pe4_yacc #(.DIRECT_DRAIN(1)) core(.*);
endmodule

