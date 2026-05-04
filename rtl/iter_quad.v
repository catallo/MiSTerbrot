//============================================================================
// Iterator Quad — Four Mandelbrot/Julia iterators sharing
// seven truncated 64×64 multiplies via 4-context DSP time-multiplexing.
//
// 4-stage pipeline (vs. 2-stage in iter_pair.v):
//   Stage 1   : DSP partial products (registered)
//   Stage 2a  : 96-bit accumulation → registered {zr_sq, zi_sq, zr_zi, ovf}
//   Stage 2b1 : combinational mag_sq, escape, mux on phase_d2 → registered
//   Stage 2b2 : final adds + state machine writeback
//
// Each context iterates every 4 clocks. Contexts share the seven multipliers
// in round-robin via a 2-bit phase counter.
//
// DSP usage per iter_quad: ~14 DSP blocks (7 multiply ops × ~2 DSPs each).
// Same as iter_pair, but serves twice as many logical iterators.
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

    input  wire [1:0]              fractal_type,
    input  wire signed [WIDTH-1:0] julia_cr,
    input  wire signed [WIDTH-1:0] julia_ci,
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
    output wire signed [WIDTH-1:0] final_mag_sq_d
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

// ---- Per-context state arrays ----
reg [2:0]              ctx_state          [0:3];
reg signed [WIDTH-1:0] ctx_zr             [0:3];
reg signed [WIDTH-1:0] ctx_zi             [0:3];
reg signed [WIDTH-1:0] ctx_c_real         [0:3];
reg signed [WIDTH-1:0] ctx_c_imag         [0:3];
reg [11:0]             ctx_iter           [0:3];
reg                    ctx_primed         [0:3];
reg signed [WIDTH-1:0] ctx_cardioid_x     [0:3];
reg signed [WIDTH-1:0] ctx_cardioid_ci_sq [0:3];
reg                    ctx_done           [0:3];
reg [11:0]             ctx_iter_count     [0:3];
reg                    ctx_escaped        [0:3];
reg signed [WIDTH-1:0] ctx_final_mag_sq   [0:3];

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

// ---- Per-context input fan-in (for indexing in generate) ----
wire                    ctx_start [0:3];
assign ctx_start[0] = start_a;
assign ctx_start[1] = start_b;
assign ctx_start[2] = start_c;
assign ctx_start[3] = start_d;
wire signed [WIDTH-1:0] ctx_cr_in [0:3];
assign ctx_cr_in[0] = cr_a;
assign ctx_cr_in[1] = cr_b;
assign ctx_cr_in[2] = cr_c;
assign ctx_cr_in[3] = cr_d;
wire signed [WIDTH-1:0] ctx_ci_in [0:3];
assign ctx_ci_in[0] = ci_a;
assign ctx_ci_in[1] = ci_b;
assign ctx_ci_in[2] = ci_c;
assign ctx_ci_in[3] = ci_d;

// ---- 2-bit phase counter (4 contexts) ----
reg [1:0] phase;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) phase <= 2'd0;
    else        phase <= phase + 2'd1;
end

// ---- Multiplier input mux (selects active context's z based on phase) ----
wire signed [WIDTH-1:0] mul_zr = ctx_zr[phase];
wire signed [WIDTH-1:0] mul_zi = ctx_zi[phase];

// ---- Split operands into 32-bit halves ----
wire signed [31:0] zr_hi = mul_zr[63:32];
wire        [31:0] zr_lo = mul_zr[31:0];
wire signed [31:0] zi_hi = mul_zi[63:32];
wire        [31:0] zi_lo = mul_zi[31:0];
wire signed [32:0] zr_lo_s = {1'b0, zr_lo};
wire signed [32:0] zi_lo_s = {1'b0, zi_lo};

// ============================================================
// Stage 1: DSP partial products (registered)
// ============================================================
reg signed [63:0] zrsq_hh;     // zr_hi * zr_hi
reg signed [64:0] zrsq_cross;  // zr_hi * zr_lo_s (doubled in stage 2a)
reg signed [63:0] zisq_hh;
reg signed [64:0] zisq_cross;
reg signed [63:0] zrzi_hh;
reg signed [64:0] zrzi_hl;
reg signed [64:0] zrzi_lh;
reg [1:0] phase_d1;

always @(posedge clk) begin
    zrsq_hh    <= zr_hi * zr_hi;
    zrsq_cross <= zr_hi * zr_lo_s;
    zisq_hh    <= zi_hi * zi_hi;
    zisq_cross <= zi_hi * zi_lo_s;
    zrzi_hh    <= zr_hi * zi_hi;
    zrzi_hl    <= zr_hi * zi_lo_s;
    zrzi_lh    <= zr_lo_s * zi_hi;
    phase_d1   <= phase;
end

// ============================================================
// Stage 2a: 96-bit accumulation (combinational), registered output
// ============================================================
wire signed [65:0] zrsq_cross_2_w = {zrsq_cross, 1'b0};
wire signed [95:0] zrsq_sum_w = {zrsq_hh, 32'd0} + {{30{zrsq_cross_2_w[65]}}, zrsq_cross_2_w};
wire signed [WIDTH-1:0] zr_sq_w = zrsq_sum_w[87:24];
wire [7:0] zr_sq_ovf_w = zrsq_sum_w[95:88];

wire signed [65:0] zisq_cross_2_w = {zisq_cross, 1'b0};
wire signed [95:0] zisq_sum_w = {zisq_hh, 32'd0} + {{30{zisq_cross_2_w[65]}}, zisq_cross_2_w};
wire signed [WIDTH-1:0] zi_sq_w = zisq_sum_w[87:24];
wire [7:0] zi_sq_ovf_w = zisq_sum_w[95:88];

wire signed [65:0] zrzi_mid_w = {zrzi_hl[64], zrzi_hl} + {zrzi_lh[64], zrzi_lh};
wire signed [95:0] zrzi_sum_w = {zrzi_hh, 32'd0} + {{30{zrzi_mid_w[65]}}, zrzi_mid_w};
wire signed [WIDTH-1:0] zr_zi_w = zrzi_sum_w[87:24];

reg signed [WIDTH-1:0] zr_sq, zi_sq, zr_zi;
reg [7:0]              zr_sq_ovf, zi_sq_ovf;
reg [1:0]              phase_d2;

always @(posedge clk) begin
    zr_sq     <= zr_sq_w;
    zi_sq     <= zi_sq_w;
    zr_zi     <= zr_zi_w;
    zr_sq_ovf <= zr_sq_ovf_w;
    zi_sq_ovf <= zi_sq_ovf_w;
    phase_d2  <= phase_d1;
end

// ============================================================
// Stage 2b1: pre-decision combinational + per-context mux, registered
//
// What moves out of the writeback critical path here:
//   - 64-bit mag_sq add
//   - 4-way mux on phase_d2 (selects c_real/c_imag/cardioid_x/cardioid_ci_sq
//     of the active context for use in writeback one cycle later)
//   - 64-bit zr_diff = zr_sq − zi_sq subtract (precomputes half of zr_next)
//   - escape detection (overflow flags + threshold compare)
// ============================================================
wire signed [WIDTH-1:0] mag_sq_w    = zr_sq + zi_sq;
wire signed [WIDTH-1:0] two_zr_zi_w = {zr_zi[WIDTH-2:0], 1'b0};
wire signed [WIDTH-1:0] zr_diff_w   = zr_sq - zi_sq;

wire zr_sq_overflow_w = |zr_sq_ovf | zr_sq[WIDTH-1];
wire zi_sq_overflow_w = |zi_sq_ovf | zi_sq[WIDTH-1];
wire sum_overflow_w   = ~zr_sq[WIDTH-1] & ~zi_sq[WIDTH-1] & mag_sq_w[WIDTH-1];
wire escape_w = zr_sq_overflow_w | zi_sq_overflow_w | sum_overflow_w |
                ($signed(mag_sq_w) > ESCAPE_THRESHOLD);

wire signed [WIDTH-1:0] s2b1_c_real_w         = ctx_c_real        [phase_d2];
wire signed [WIDTH-1:0] s2b1_c_imag_w         = ctx_c_imag        [phase_d2];
wire signed [WIDTH-1:0] s2b1_cardioid_x_w     = ctx_cardioid_x    [phase_d2];
wire signed [WIDTH-1:0] s2b1_cardioid_ci_sq_w = ctx_cardioid_ci_sq[phase_d2];

// Pre-compute the S_CARDIOID and S_BULB comparator results in Stage 2b1.
// These were the 64-bit signed compares living on the Stage 2b2 critical
// path (4 LUT levels, ~3 ns). Registering the boolean result moves them
// off the writeback path entirely.
wire signed [WIDTH-1:0] s2b1_cardioid_rhs_w = s2b1_cardioid_ci_sq_w >>> 2;
wire cardioid_check_w = $signed(zr_zi)    < $signed(s2b1_cardioid_rhs_w);
wire bulb_check_w     = $signed(mag_sq_w) < $signed(BULB_THRESHOLD);

reg signed [WIDTH-1:0] mag_sq_r;
reg signed [WIDTH-1:0] two_zr_zi_r;
reg signed [WIDTH-1:0] zr_zi_pl;       // pipelined zr_zi for state machine view
reg signed [WIDTH-1:0] zi_sq_pl;       // pipelined zi_sq for S_PREP_Q write
reg signed [WIDTH-1:0] zr_diff_r;
reg                    escape_pl;
reg                    cardioid_check_pl;
reg                    bulb_check_pl;
reg signed [WIDTH-1:0] s2_c_real;
reg signed [WIDTH-1:0] s2_c_imag;
reg signed [WIDTH-1:0] s2_cardioid_x;
reg signed [WIDTH-1:0] s2_cardioid_ci_sq;
reg [1:0]              phase_d3;

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
    phase_d3          <= phase_d2;
end

// ============================================================
// Stage 2b2: Decision and writeback (final adds + state machine)
// Operates on Stage 2b1 registered outputs at phase_d3.
// Aliases below let the state machine code reference the original names
// (mag_sq, zr_zi, zi_sq, escape) while actually consuming the
// pipelined-through values.
// ============================================================
wire signed [WIDTH-1:0] mag_sq_eff      = mag_sq_r;
wire signed [WIDTH-1:0] two_zr_zi       = two_zr_zi_r;
wire signed [WIDTH-1:0] zr_zi_eff       = zr_zi_pl;
wire signed [WIDTH-1:0] zi_sq_eff       = zi_sq_pl;
wire                    escape_eff      = escape_pl;
wire signed [WIDTH-1:0] s2_cardioid_rhs = s2_cardioid_ci_sq >>> 2;

wire signed [WIDTH-1:0] zr_next_std = zr_diff_r + s2_c_real;
wire signed [WIDTH-1:0] zi_next_std = two_zr_zi  + s2_c_imag;
wire signed [WIDTH-1:0] zi_next     = zi_next_std;

// ============================================================
// Per-context state machines (replicated via generate)
// ============================================================
genvar k;
generate
for (k = 0; k < 4; k = k + 1) begin : ctx_sm
    localparam [1:0] CTX_K = k[1:0];

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
                case (fractal_type)
                    2'd1: begin // Julia
                        ctx_zr[k]     <= ctx_cr_in[k];
                        ctx_zi[k]     <= ctx_ci_in[k];
                        ctx_c_real[k] <= julia_cr;
                        ctx_c_imag[k] <= julia_ci;
                        ctx_state[k]  <= S_ITER;
                    end
                    default: begin // Mandelbrot (and unused codes)
                        ctx_c_real[k]         <= ctx_cr_in[k];
                        ctx_c_imag[k]         <= ctx_ci_in[k];
                        ctx_cardioid_x[k]     <= ctx_cr_in[k] - QUARTER_FIXED;
                        ctx_cardioid_ci_sq[k] <= {WIDTH{1'b0}};
                        ctx_zr[k]             <= ctx_cr_in[k] - QUARTER_FIXED;
                        ctx_zi[k]             <= ctx_ci_in[k];
                        ctx_state[k]          <= S_PREP_Q;
                    end
                endcase
            end

            S_PREP_Q: if (phase_d3 == CTX_K) begin
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

            S_CARDIOID: if (phase_d3 == CTX_K) begin
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

            S_BULB: if (phase_d3 == CTX_K) begin
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

            S_ITER: if (phase_d3 == CTX_K) begin
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
                case (fractal_type)
                    2'd1: begin
                        ctx_zr[k]     <= ctx_cr_in[k];
                        ctx_zi[k]     <= ctx_ci_in[k];
                        ctx_c_real[k] <= julia_cr;
                        ctx_c_imag[k] <= julia_ci;
                        ctx_state[k]  <= S_ITER;
                    end
                    default: begin
                        ctx_c_real[k]         <= ctx_cr_in[k];
                        ctx_c_imag[k]         <= ctx_ci_in[k];
                        ctx_cardioid_x[k]     <= ctx_cr_in[k] - QUARTER_FIXED;
                        ctx_cardioid_ci_sq[k] <= {WIDTH{1'b0}};
                        ctx_zr[k]             <= ctx_cr_in[k] - QUARTER_FIXED;
                        ctx_zi[k]             <= ctx_ci_in[k];
                        ctx_state[k]          <= S_PREP_Q;
                    end
                endcase
            end

            default: ctx_state[k] <= S_IDLE;
            endcase
        end
    end
end
endgenerate

endmodule
