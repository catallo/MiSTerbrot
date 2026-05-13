//============================================================================
// Iterator Quad — Five Mandelbrot/Julia iterators sharing
// seven truncated 64×64 multiplies via 5-context DSP time-multiplexing.
//
// Note: name retained for historical reasons; this version has 5 contexts
// (A..E) per instance, not 4.
//
// 6-stage pipeline (vs. 2-stage in iter_pair.v):
//   Stage 0   : operand input register (mux output -> DSP input reg packing)
//   Stage 1   : DSP partial products (registered)
//   Stage 2a1 : lower-half 32-bit adds + carry → registered
//   Stage 2a2 : upper-half 32-bit adds + assemble → registered
//                {zr_sq, zi_sq, zr_zi, ovf}
//   Stage 2b1 : mag_sq, escape, compares, phase_d3 4:1-style mux → registered
//   Stage 2b2 : final adds + state machine writeback at phase_d4
//
// Each context iterates every 6 clocks. Six-stage pipeline requires
// N_contexts ≥ N_stages to avoid the iteration loop hazard (same-cycle
// read while writeback for the same context is happening) — hence the
// 6 contexts. Total iterators per quad: 6 (was 5).
// NOTE: phase_d4 (the same gate name used in the OLD 5-context design)
// is correct here too — adding Stage 0 lengthens the phase delay chain
// by ONE cycle, so phase_d4 now lags phase by 5 cycles, exactly matching
// the data age in Stage 2b2's source registers.
//
// DSP usage per iter_quad: ~14 DSP blocks (7 multiply ops × ~2 DSPs each).
// Same multiplier count as iter_pair.v / earlier 4-context iter_quad,
// but serves 6 logical iterators instead.
// 12-bit iteration count supports max_iter up to 2048.
//
// Mandelbrot mode reuses the multiplier pipeline for an interior precheck
// before entering the main iteration loop:
//   1. Compute q = (cr − 0.25)^2 + ci^2
//   2. Test q · (q + (cr − 0.25)) < 0.25 · ci^2     (main cardioid)
//   3. Test (cr + 1)^2 + ci^2 < 1/16                (period-2 bulb)
// Points inside either region return done immediately with iter_count=max_iter.
//============================================================================

module iter_quad #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [11:0]             max_iter,

    // Context A
    input  wire                    start_a,
    input  wire signed [WIDTH-1:0] cr_a,
    input  wire signed [WIDTH-1:0] ci_a,
    output wire                    done_a,
    output wire [11:0]             iter_count_a,
    output wire                    escaped_a,
    output wire signed [WIDTH-1:0] final_mag_sq_a,

    // Context B
    input  wire                    start_b,
    input  wire signed [WIDTH-1:0] cr_b,
    input  wire signed [WIDTH-1:0] ci_b,
    output wire                    done_b,
    output wire [11:0]             iter_count_b,
    output wire                    escaped_b,
    output wire signed [WIDTH-1:0] final_mag_sq_b,

    // Context C
    input  wire                    start_c,
    input  wire signed [WIDTH-1:0] cr_c,
    input  wire signed [WIDTH-1:0] ci_c,
    output wire                    done_c,
    output wire [11:0]             iter_count_c,
    output wire                    escaped_c,
    output wire signed [WIDTH-1:0] final_mag_sq_c,

    // Context D
    input  wire                    start_d,
    input  wire signed [WIDTH-1:0] cr_d,
    input  wire signed [WIDTH-1:0] ci_d,
    output wire                    done_d,
    output wire [11:0]             iter_count_d,
    output wire                    escaped_d,
    output wire signed [WIDTH-1:0] final_mag_sq_d,

    // Context E
    input  wire                    start_e,
    input  wire signed [WIDTH-1:0] cr_e,
    input  wire signed [WIDTH-1:0] ci_e,
    output wire                    done_e,
    output wire [11:0]             iter_count_e,
    output wire                    escaped_e,
    output wire signed [WIDTH-1:0] final_mag_sq_e,

    // Context f (6th context, added to fill the new Stage 0 input-register
    // pipeline slot so the operand mux can pack into the DSP input registers
    // without throughput loss).
    input  wire                    start_f,
    input  wire signed [WIDTH-1:0] cr_f,
    input  wire signed [WIDTH-1:0] ci_f,
    output wire                    done_f,
    output wire [11:0]             iter_count_f,
    output wire                    escaped_f,
    output wire signed [WIDTH-1:0] final_mag_sq_f
);

localparam signed [WIDTH-1:0] ESCAPE_THRESHOLD = {{(WIDTH-FRAC_BITS-3){1'b0}}, 1'b1, {(FRAC_BITS+2){1'b0}}};
localparam signed [WIDTH-1:0] ONE_FIXED        = {{(WIDTH-FRAC_BITS-1){1'b0}}, 1'b1, {FRAC_BITS{1'b0}}};
localparam signed [WIDTH-1:0] QUARTER_FIXED    = {{(WIDTH-FRAC_BITS+1){1'b0}}, 1'b1, {(FRAC_BITS-2){1'b0}}};
localparam signed [WIDTH-1:0] BULB_THRESHOLD   = {{(WIDTH-FRAC_BITS+3){1'b0}}, 1'b1, {(FRAC_BITS-4){1'b0}}};
localparam [2:0] S_IDLE     = 3'd0,
                 S_PREP_Q   = 3'd1,
                 S_CARDIOID = 3'd2,
                 S_BULB     = 3'd3,
                 S_ITER     = 3'd4,
                 S_DONE     = 3'd5;

localparam [2:0] PHASE_MAX = 3'd5;  // 6 contexts: phase counts 0..5

// ---- Per-context state arrays ----
reg [2:0]              ctx_state          [0:5];
reg signed [WIDTH-1:0] ctx_zr             [0:5];
reg signed [WIDTH-1:0] ctx_zi             [0:5];
reg signed [WIDTH-1:0] ctx_c_real         [0:5];
reg signed [WIDTH-1:0] ctx_c_imag         [0:5];
reg [11:0]             ctx_iter           [0:5];
reg                    ctx_primed         [0:5];
reg signed [WIDTH-1:0] ctx_cardioid_x     [0:5];
reg signed [WIDTH-1:0] ctx_cardioid_ci_sq [0:5];
reg                    ctx_done           [0:5];
reg [11:0]             ctx_iter_count     [0:5];
reg                    ctx_escaped        [0:5];
reg signed [WIDTH-1:0] ctx_final_mag_sq   [0:5];

// ---- Connect output ports ----
assign done_a         = ctx_done[0];
assign iter_count_a   = ctx_iter_count[0];
assign escaped_a      = ctx_escaped[0];
assign final_mag_sq_a = ctx_final_mag_sq[0];
assign done_b         = ctx_done[1];
assign iter_count_b   = ctx_iter_count[1];
assign escaped_b      = ctx_escaped[1];
assign final_mag_sq_b = ctx_final_mag_sq[1];
assign done_c         = ctx_done[2];
assign iter_count_c   = ctx_iter_count[2];
assign escaped_c      = ctx_escaped[2];
assign final_mag_sq_c = ctx_final_mag_sq[2];
assign done_d         = ctx_done[3];
assign iter_count_d   = ctx_iter_count[3];
assign escaped_d      = ctx_escaped[3];
assign final_mag_sq_d = ctx_final_mag_sq[3];
assign done_e         = ctx_done[4];
assign iter_count_e   = ctx_iter_count[4];
assign escaped_e      = ctx_escaped[4];
assign final_mag_sq_e = ctx_final_mag_sq[4];
assign done_f         = ctx_done[5];
assign iter_count_f   = ctx_iter_count[5];
assign escaped_f      = ctx_escaped[5];
assign final_mag_sq_f = ctx_final_mag_sq[5];

// ---- Per-context input fan-in ----
wire                    ctx_start [0:5];
assign ctx_start[0] = start_a;
assign ctx_start[1] = start_b;
assign ctx_start[2] = start_c;
assign ctx_start[3] = start_d;
assign ctx_start[4] = start_e;
assign ctx_start[5] = start_f;
wire signed [WIDTH-1:0] ctx_cr_in [0:5];
assign ctx_cr_in[0] = cr_a;
assign ctx_cr_in[1] = cr_b;
assign ctx_cr_in[2] = cr_c;
assign ctx_cr_in[3] = cr_d;
assign ctx_cr_in[4] = cr_e;
assign ctx_cr_in[5] = cr_f;
wire signed [WIDTH-1:0] ctx_ci_in [0:5];
assign ctx_ci_in[0] = ci_a;
assign ctx_ci_in[1] = ci_b;
assign ctx_ci_in[2] = ci_c;
assign ctx_ci_in[3] = ci_d;
assign ctx_ci_in[4] = ci_e;
assign ctx_ci_in[5] = ci_f;

// ---- 3-bit phase counter (5 contexts; wraps at 5) ----
// Replicate per operand mux. Quartus auto-DUPLICATEs `phase` to relieve fanout
// across the seven DSPs, but after the benchmarking refactor changed nearby
// placement, the auto-duplicates ended up far from the operand muxes and the
// `phase[1] -> mux -> DSP -> zrsq_cross` path crossed 10 ns at 100 MHz. By
// giving each of the two operand muxes its own preserved+dont_merge counter,
// the placer is free to put each adjacent to its 5:1 mux LUT cluster. The
// original `phase` is kept as the source for downstream `phase_d1` tracking.
reg [2:0] phase;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_zr;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_zi;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase    <= 3'd0;
        phase_zr <= 3'd0;
        phase_zi <= 3'd0;
    end else begin
        phase    <= (phase    == PHASE_MAX) ? 3'd0 : phase    + 3'd1;
        phase_zr <= (phase_zr == PHASE_MAX) ? 3'd0 : phase_zr + 3'd1;
        phase_zi <= (phase_zi == PHASE_MAX) ? 3'd0 : phase_zi + 3'd1;
    end
end

// ---- Multiplier input mux (selects active context's z based on phase) ----
// Use the dedicated counter replicas so each mux can be placed near its DSPs.
wire signed [WIDTH-1:0] mul_zr_w = ctx_zr[phase_zr];
wire signed [WIDTH-1:0] mul_zi_w = ctx_zi[phase_zi];

// ============================================================
// Stage 0: register the muxed operands so Quartus can pack these regs into
// the DSP's clk0/clk1 INPUT registers. Splits the long mux->DSP combinational
// path into two pipeline stages, giving the critical `phase[1] -> Mux6 -> Mult1
// -> zrsq_cross` path several ns of slack. The total pipeline depth grows
// from 5 to 6 stages; the context count was grown from 5 to 6 in tandem so
// the pipeline still fires one iter per cycle per quad.
// ============================================================
reg signed [WIDTH-1:0] mul_zr_r, mul_zi_r;
reg [2:0]              phase_d0;
always @(posedge clk) begin
    mul_zr_r <= mul_zr_w;
    mul_zi_r <= mul_zi_w;
    phase_d0 <= phase;
end

// ---- Split registered operands into 32-bit halves ----
wire signed [31:0] zr_hi = mul_zr_r[63:32];
wire        [31:0] zr_lo = mul_zr_r[31:0];
wire signed [31:0] zi_hi = mul_zi_r[63:32];
wire        [31:0] zi_lo = mul_zi_r[31:0];
wire signed [32:0] zr_lo_s = {1'b0, zr_lo};
wire signed [32:0] zi_lo_s = {1'b0, zi_lo};

// ============================================================
// Stage 1: DSP partial products (registered)
// ============================================================
reg signed [63:0] zrsq_hh;     // zr_hi * zr_hi
reg signed [64:0] zrsq_cross;  // zr_hi * zr_lo_s (doubled in 2a1)
reg signed [63:0] zisq_hh;
reg signed [64:0] zisq_cross;
reg signed [63:0] zrzi_hh;
reg signed [64:0] zrzi_hl;
reg signed [64:0] zrzi_lh;
reg [2:0] phase_d1;

always @(posedge clk) begin
    zrsq_hh    <= zr_hi * zr_hi;
    zrsq_cross <= zr_hi * zr_lo_s;
    zisq_hh    <= zi_hi * zi_hi;
    zisq_cross <= zi_hi * zi_lo_s;
    zrzi_hh    <= zr_hi * zi_hi;
    zrzi_hl    <= zr_hi * zi_lo_s;
    zrzi_lh    <= zr_lo_s * zi_hi;
    phase_d1   <= phase_d0;  // was `<= phase`; new Stage 0 input-register sits between
end

// ============================================================
// Stage 2a1: Lower-half 32-bit add of the (formerly 96-bit) accumulation
//
// The accumulation slice [95:0] for each square or cross product is
// effectively split as:
//   bits [31:0] = passthrough (zrsq_cross_2_w[31:0] etc.; zrsq_hh has 0 here)
//   bits [95:32] = zrsq_hh + sign_extended(zrsq_cross_2_w[65:32])
//
// We split that 64-bit upper-half add into two 32-bit halves with carry.
// Stage 2a1 computes the lower 32-bit add (slice bits [63:32]) and
// registers the result, the carry-out, and the upper-32-bit operands for
// Stage 2a2 to finish.
// ============================================================
wire signed [65:0] zrsq_cross_2_w = {zrsq_cross, 1'b0};
wire signed [65:0] zisq_cross_2_w = {zisq_cross, 1'b0};

// zr*zi has two cross terms. Keep the lower-word accumulation out of the
// top-word carry chain so Stage 2a1 does not become two serial 32-bit adders.
wire [32:0] zrzi_mid_lo_sum_w = {1'b0, zrzi_hl[31:0]} + {1'b0, zrzi_lh[31:0]};
wire signed [33:0] zrzi_mid_hi_sum_w =
    $signed({zrzi_hl[64], zrzi_hl[64:32]}) +
    $signed({zrzi_lh[64], zrzi_lh[64:32]}) +
    $signed({33'd0, zrzi_mid_lo_sum_w[32]});
wire [32:0] zrzi_mid_word_sum_w = {1'b0, zrzi_hl[63:32]} +
                                  {1'b0, zrzi_lh[63:32]} +
                                  {32'd0, zrzi_mid_lo_sum_w[32]};
wire [31:0] zrzi_word_sum_w   = zrzi_hh[31:0] ^ zrzi_hl[63:32] ^ zrzi_lh[63:32];
wire [32:0] zrzi_word_carry_w = {((zrzi_hh[31:0] & zrzi_hl[63:32]) |
                                  (zrzi_hh[31:0] & zrzi_lh[63:32]) |
                                  (zrzi_hl[63:32] & zrzi_lh[63:32])), 1'b0};
wire [32:0] zrzi_word_total_w = {1'b0, zrzi_word_sum_w} +
                                zrzi_word_carry_w +
                                {32'd0, zrzi_mid_lo_sum_w[32]};

// Lower-half adds: 32-bit + 32-bit → 33-bit (low result + carry)
wire [32:0] zrsq_lo_sum_w = {1'b0, zrsq_hh[31:0]} + {1'b0, zrsq_cross_2_w[63:32]};
wire [32:0] zisq_lo_sum_w = {1'b0, zisq_hh[31:0]} + {1'b0, zisq_cross_2_w[63:32]};
wire [32:0] zrzi_lo_sum_w = {zrzi_word_total_w[32] ^ zrzi_mid_word_sum_w[32],
                             zrzi_word_total_w[31:0]};

reg [31:0] zrsq_lo_r,    zisq_lo_r,    zrzi_lo_r;     // lower 32 bits of upper-half sum (slice [63:32])
reg        zrsq_carry_r, zisq_carry_r, zrzi_carry_r;  // carry into upper-half (slice bit 64)
reg signed [31:0] zrsq_hh_hi_r, zisq_hh_hi_r, zrzi_hh_hi_r;  // zrsq_hh[63:32] etc, queued for 2a2
// Sign-extension source for the upper add: bit 65 of the original cross
reg        zrsq_cross_sign_r, zisq_cross_sign_r, zrzi_mid_sign_r;
// Actual cross-bits feeding into the upper-half add: bits [65:64] of cross_2 (only 2 actual bits)
reg [1:0]  zrsq_cross_top_r, zisq_cross_top_r, zrzi_mid_top_r;
// Passthrough: bits [31:0] of slice
reg [31:0] zrsq_pass_r, zisq_pass_r, zrzi_pass_r;
reg [2:0]  phase_d2;

always @(posedge clk) begin
    zrsq_lo_r         <= zrsq_lo_sum_w[31:0];
    zrsq_carry_r      <= zrsq_lo_sum_w[32];
    zrsq_hh_hi_r      <= zrsq_hh[63:32];
    zrsq_cross_sign_r <= zrsq_cross_2_w[65];
    zrsq_cross_top_r  <= zrsq_cross_2_w[65:64];
    zrsq_pass_r       <= zrsq_cross_2_w[31:0];

    zisq_lo_r         <= zisq_lo_sum_w[31:0];
    zisq_carry_r      <= zisq_lo_sum_w[32];
    zisq_hh_hi_r      <= zisq_hh[63:32];
    zisq_cross_sign_r <= zisq_cross_2_w[65];
    zisq_cross_top_r  <= zisq_cross_2_w[65:64];
    zisq_pass_r       <= zisq_cross_2_w[31:0];

    zrzi_lo_r         <= zrzi_lo_sum_w[31:0];
    zrzi_carry_r      <= zrzi_lo_sum_w[32];
    zrzi_hh_hi_r      <= zrzi_hh[63:32];
    zrzi_mid_sign_r   <= zrzi_mid_hi_sum_w[33];
    zrzi_mid_top_r    <= zrzi_mid_hi_sum_w[33:32];
    zrzi_pass_r       <= zrzi_mid_lo_sum_w[31:0];

    phase_d2          <= phase_d1;
end

// ============================================================
// Stage 2a2: Upper-half 32-bit add (with carry from 2a1) + slice assemble
// → registered {zr_sq, zi_sq, zr_zi, ovf}
// ============================================================
// Reconstruct upper-half operand B (32 bits): top 30 bits are sign-extension
// from cross_sign, bottom 2 bits are cross_top.
wire signed [31:0] zrsq_b_hi = $signed({{30{zrsq_cross_sign_r}}, zrsq_cross_top_r});
wire signed [31:0] zisq_b_hi = $signed({{30{zisq_cross_sign_r}}, zisq_cross_top_r});
wire signed [31:0] zrzi_b_hi = $signed({{30{zrzi_mid_sign_r}},   zrzi_mid_top_r});

wire [32:0] zrsq_hi_sum_w = {1'b0, zrsq_hh_hi_r} + {1'b0, zrsq_b_hi} + {32'd0, zrsq_carry_r};
wire [32:0] zisq_hi_sum_w = {1'b0, zisq_hh_hi_r} + {1'b0, zisq_b_hi} + {32'd0, zisq_carry_r};
wire [32:0] zrzi_hi_sum_w = {1'b0, zrzi_hh_hi_r} + {1'b0, zrzi_b_hi} + {32'd0, zrzi_carry_r};

// Reassemble full 96-bit slice: {hi_sum[31:0], lo_r[31:0], pass_r[31:0]}
wire [95:0] zrsq_sum_w = {zrsq_hi_sum_w[31:0], zrsq_lo_r, zrsq_pass_r};
wire [95:0] zisq_sum_w = {zisq_hi_sum_w[31:0], zisq_lo_r, zisq_pass_r};
wire [95:0] zrzi_sum_w = {zrzi_hi_sum_w[31:0], zrzi_lo_r, zrzi_pass_r};

wire signed [WIDTH-1:0] zr_sq_w   = zrsq_sum_w[87:24];
wire        [7:0]       zr_sq_ovf_w = zrsq_sum_w[95:88];
wire signed [WIDTH-1:0] zi_sq_w   = zisq_sum_w[87:24];
wire        [7:0]       zi_sq_ovf_w = zisq_sum_w[95:88];
wire signed [WIDTH-1:0] zr_zi_w   = zrzi_sum_w[87:24];

reg signed [WIDTH-1:0] zr_sq, zi_sq, zr_zi;
reg [7:0]              zr_sq_ovf, zi_sq_ovf;
reg [2:0]              phase_d3;

always @(posedge clk) begin
    zr_sq     <= zr_sq_w;
    zi_sq     <= zi_sq_w;
    zr_zi     <= zr_zi_w;
    zr_sq_ovf <= zr_sq_ovf_w;
    zi_sq_ovf <= zi_sq_ovf_w;
    phase_d3  <= phase_d2;
end

// ============================================================
// Stage 2b1: pre-decision combinational + per-context mux, registered
//
// Now keyed on phase_d3 (since we inserted Stage 2a1, phase_d3 is the
// new "the partials are for context k"-aligned signal).
// ============================================================
wire signed [WIDTH-1:0] mag_sq_w    = zr_sq + zi_sq;
wire signed [WIDTH-1:0] two_zr_zi_w = {zr_zi[WIDTH-2:0], 1'b0};
wire signed [WIDTH-1:0] zr_diff_w   = zr_sq - zi_sq;

wire zr_sq_overflow_w = |zr_sq_ovf | zr_sq[WIDTH-1];
wire zi_sq_overflow_w = |zi_sq_ovf | zi_sq[WIDTH-1];
wire sum_overflow_w   = ~zr_sq[WIDTH-1] & ~zi_sq[WIDTH-1] & mag_sq_w[WIDTH-1];
wire escape_w = zr_sq_overflow_w | zi_sq_overflow_w | sum_overflow_w |
                ($signed(mag_sq_w) > ESCAPE_THRESHOLD);

wire signed [WIDTH-1:0] s2b1_c_real_w         = ctx_c_real        [phase_d3];
wire signed [WIDTH-1:0] s2b1_c_imag_w         = ctx_c_imag        [phase_d3];
wire signed [WIDTH-1:0] s2b1_cardioid_x_w     = ctx_cardioid_x    [phase_d3];
wire signed [WIDTH-1:0] s2b1_cardioid_ci_sq_w = ctx_cardioid_ci_sq[phase_d3];

wire signed [WIDTH-1:0] s2b1_cardioid_rhs_w = s2b1_cardioid_ci_sq_w >>> 2;
wire cardioid_check_w = $signed(zr_zi)    < $signed(s2b1_cardioid_rhs_w);
wire bulb_check_w     = $signed(mag_sq_w) < $signed(BULB_THRESHOLD);

reg signed [WIDTH-1:0] mag_sq_r;
reg signed [WIDTH-1:0] two_zr_zi_r;
reg signed [WIDTH-1:0] zr_zi_pl;
reg signed [WIDTH-1:0] zi_sq_pl;
reg signed [WIDTH-1:0] zr_diff_r;
reg                    escape_pl;
reg                    cardioid_check_pl;
reg                    bulb_check_pl;
reg signed [WIDTH-1:0] s2_c_real;
reg signed [WIDTH-1:0] s2_c_imag;
reg signed [WIDTH-1:0] s2_cardioid_x;
reg signed [WIDTH-1:0] s2_cardioid_ci_sq;
reg [2:0]              phase_d4;
// The Stage 0 operand-input register adds a stage at the START of the pipe.
// phase_d4 (4 chained registers from `phase`) is now 5 cycles behind phase,
// which matches the data age in Stage 2b2 (Stage 0 -> Stage 2b1 = 5 stages).
// No phase_d5 needed — the writeback gating stays on phase_d4.

always @(posedge clk) begin
    mag_sq_r          <= mag_sq_w;
    two_zr_zi_r       <= two_zr_zi_w;
    zr_zi_pl          <= zr_zi;
    zi_sq_pl          <= zi_sq;
    zr_diff_r         <= zr_diff_w;
    escape_pl         <= escape_w;
    cardioid_check_pl <= cardioid_check_w;
    bulb_check_pl     <= bulb_check_w;
    s2_c_real         <= s2b1_c_real_w;
    s2_c_imag         <= s2b1_c_imag_w;
    s2_cardioid_x     <= s2b1_cardioid_x_w;
    s2_cardioid_ci_sq <= s2b1_cardioid_ci_sq_w;
    phase_d4          <= phase_d3;
end

// ============================================================
// Stage 2b2: Decision and writeback (final adds + state machine)
// Operates on Stage 2b1 registered outputs at phase_d4.
// ============================================================
wire signed [WIDTH-1:0] mag_sq_eff = mag_sq_r;
wire signed [WIDTH-1:0] two_zr_zi  = two_zr_zi_r;
wire signed [WIDTH-1:0] zr_zi_eff  = zr_zi_pl;
wire signed [WIDTH-1:0] zi_sq_eff  = zi_sq_pl;
wire                    escape_eff = escape_pl;

wire signed [WIDTH-1:0] zr_next_std = zr_diff_r + s2_c_real;
wire signed [WIDTH-1:0] zi_next_std = two_zr_zi  + s2_c_imag;
wire signed [WIDTH-1:0] zi_next     = zi_next_std;

// ============================================================
// Per-context state machines (replicated via generate, 6 contexts)
// ============================================================
genvar k;
generate
for (k = 0; k < 6; k = k + 1) begin : ctx_sm
    localparam [2:0] CTX_K = k[2:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_state[k]          <= S_IDLE;
            ctx_done[k]           <= 1'b0;
            ctx_escaped[k]        <= 1'b0;
            ctx_iter_count[k]     <= 12'd0;
            ctx_final_mag_sq[k]   <= {WIDTH{1'b0}};
            ctx_zr[k]             <= {WIDTH{1'b0}};
            ctx_zi[k]             <= {WIDTH{1'b0}};
            ctx_c_real[k]         <= {WIDTH{1'b0}};
            ctx_c_imag[k]         <= {WIDTH{1'b0}};
            ctx_iter[k]           <= 12'd0;
            ctx_primed[k]         <= 1'b0;
            ctx_cardioid_x[k]     <= {WIDTH{1'b0}};
            ctx_cardioid_ci_sq[k] <= {WIDTH{1'b0}};
        end else begin
            case (ctx_state[k])

            S_IDLE: if (ctx_start[k]) begin
                ctx_done[k]         <= 1'b0;
                ctx_escaped[k]      <= 1'b0;
                ctx_iter_count[k]   <= 12'd0;
                ctx_final_mag_sq[k] <= {WIDTH{1'b0}};
                ctx_iter[k]         <= 12'd0;
                ctx_primed[k]       <= 1'b0;
                ctx_c_real[k]         <= ctx_cr_in[k];
                ctx_c_imag[k]         <= ctx_ci_in[k];
                ctx_cardioid_x[k]     <= ctx_cr_in[k] - QUARTER_FIXED;
                ctx_cardioid_ci_sq[k] <= {WIDTH{1'b0}};
                ctx_zr[k]             <= ctx_cr_in[k] - QUARTER_FIXED;
                ctx_zi[k]             <= ctx_ci_in[k];
                ctx_state[k]          <= S_PREP_Q;
            end

            S_PREP_Q: if (phase_d4 == CTX_K) begin
                if (!ctx_primed[k]) begin
                    ctx_primed[k] <= 1'b1;
                end else begin
                    ctx_cardioid_ci_sq[k] <= zi_sq_eff;
                    ctx_zr[k]             <= mag_sq_eff;
                    ctx_zi[k]             <= mag_sq_eff + ctx_cardioid_x[k];
                    ctx_primed[k]         <= 1'b0;
                    ctx_state[k]          <= S_CARDIOID;
                end
            end

            S_CARDIOID: if (phase_d4 == CTX_K) begin
                if (!ctx_primed[k]) begin
                    ctx_primed[k] <= 1'b1;
                end else begin
                    if (cardioid_check_pl) begin
                        ctx_escaped[k]      <= 1'b0;
                        ctx_iter_count[k]   <= max_iter;
                        ctx_final_mag_sq[k] <= {WIDTH{1'b0}};
                        ctx_done[k]         <= 1'b1;
                        ctx_state[k]        <= S_DONE;
                    end else begin
                        ctx_zr[k]     <= ctx_c_real[k] + ONE_FIXED;
                        ctx_zi[k]     <= ctx_c_imag[k];
                        ctx_primed[k] <= 1'b0;
                        ctx_state[k]  <= S_BULB;
                    end
                end
            end

            S_BULB: if (phase_d4 == CTX_K) begin
                if (!ctx_primed[k]) begin
                    ctx_primed[k] <= 1'b1;
                end else begin
                    if (bulb_check_pl) begin
                        ctx_escaped[k]      <= 1'b0;
                        ctx_iter_count[k]   <= max_iter;
                        ctx_final_mag_sq[k] <= {WIDTH{1'b0}};
                        ctx_done[k]         <= 1'b1;
                        ctx_state[k]        <= S_DONE;
                    end else begin
                        ctx_zr[k]     <= {WIDTH{1'b0}};
                        ctx_zi[k]     <= {WIDTH{1'b0}};
                        ctx_iter[k]   <= 12'd0;
                        ctx_primed[k] <= 1'b0;
                        ctx_state[k]  <= S_ITER;
                    end
                end
            end

            S_ITER: if (phase_d4 == CTX_K) begin
                if (!ctx_primed[k]) begin
                    ctx_primed[k] <= 1'b1;
                end else begin
                    if (escape_eff || (ctx_iter[k] >= max_iter)) begin
                        ctx_escaped[k]      <= escape_eff;
                        ctx_iter_count[k]   <= ctx_iter[k];
                        ctx_final_mag_sq[k] <= mag_sq_eff;
                        ctx_done[k]         <= 1'b1;
                        ctx_state[k]        <= S_DONE;
                    end else begin
                        ctx_zr[k]   <= zr_next_std;
                        ctx_zi[k]   <= zi_next;
                        ctx_iter[k] <= ctx_iter[k] + 12'd1;
                    end
                end
            end

            S_DONE: if (ctx_start[k]) begin
                ctx_done[k]         <= 1'b0;
                ctx_escaped[k]      <= 1'b0;
                ctx_iter_count[k]   <= 12'd0;
                ctx_final_mag_sq[k] <= {WIDTH{1'b0}};
                ctx_iter[k]         <= 12'd0;
                ctx_primed[k]       <= 1'b0;
                ctx_c_real[k]         <= ctx_cr_in[k];
                ctx_c_imag[k]         <= ctx_ci_in[k];
                ctx_cardioid_x[k]     <= ctx_cr_in[k] - QUARTER_FIXED;
                ctx_cardioid_ci_sq[k] <= {WIDTH{1'b0}};
                ctx_zr[k]             <= ctx_cr_in[k] - QUARTER_FIXED;
                ctx_zi[k]             <= ctx_ci_in[k];
                ctx_state[k]          <= S_PREP_Q;
            end

            default: ctx_state[k] <= S_IDLE;
            endcase
        end
    end
end
endgenerate

endmodule
