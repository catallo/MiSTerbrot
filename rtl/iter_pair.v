//============================================================================
// Iterator Pair — Two Mandelbrot/Julia iterators sharing
// three truncated 64×64 multiplies via DSP time-multiplexing.
//
// Truncated multiply: splits 64-bit operands into 32-bit halves, computes
// only partial products contributing to result bits [119:56]. Omits a_lo*b_lo
// (below extraction window). For squaring, a_hi*a_lo = a_lo*a_hi so we
// compute once and double — 2 DSP multiplies per square, 3 per cross product.
//
// DSP usage per iter_pair: ~14 DSP blocks (7 multiply ops × ~2 DSPs each)
// Four iter_pair instances: ~56 DSP blocks total
//
// Phase alternation: even clocks = context A, odd = context B.
// Each context gets one pipeline step per 2 clocks.
// 12-bit iteration count supports max_iter up to 2048.
//
// Mandelbrot mode uses the same multiplier pipeline for a short interior-point
// precheck before entering the main iteration loop:
//   1. Compute q = (cr - 0.25)^2 + ci^2
//   2. Test q * (q + (cr - 0.25)) < 0.25 * ci^2   (main cardioid)
//   3. Test (cr + 1)^2 + ci^2 < 1/16              (period-2 bulb)
// Points inside either region return done immediately with iter_count=max_iter.
//============================================================================

module iter_pair #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [1:0]              fractal_type,
    input  wire signed [WIDTH-1:0] julia_cr,
    input  wire signed [WIDTH-1:0] julia_ci,
    input  wire [11:0]             max_iter,

    // Iterator A
    input  wire                    start_a,
    input  wire signed [WIDTH-1:0] cr_a,
    input  wire signed [WIDTH-1:0] ci_a,
    output reg                     done_a,
    output reg  [11:0]             iter_count_a,
    output reg                     escaped_a,
    output reg  signed [WIDTH-1:0] final_mag_sq_a,

    // Iterator B
    input  wire                    start_b,
    input  wire signed [WIDTH-1:0] cr_b,
    input  wire signed [WIDTH-1:0] ci_b,
    output reg                     done_b,
    output reg  [11:0]             iter_count_b,
    output reg                     escaped_b,
    output reg  signed [WIDTH-1:0] final_mag_sq_b
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

reg [2:0]              state_a, state_b;
reg signed [WIDTH-1:0] zr_a, zi_a, c_real_a, c_imag_a;
reg signed [WIDTH-1:0] zr_b, zi_b, c_real_b, c_imag_b;
reg [11:0]             iter_a, iter_b;
reg                    primed_a, primed_b;
reg signed [WIDTH-1:0] cardioid_x_a, cardioid_x_b;
reg signed [WIDTH-1:0] cardioid_ci_sq_a, cardioid_ci_sq_b;

// ---- Phase alternation ----
reg phase;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) phase <= 1'b0;
    else        phase <= ~phase;
end

// ---- Multiplier input mux ----
wire signed [WIDTH-1:0] mul_zr = phase ? zr_b : zr_a;
wire signed [WIDTH-1:0] mul_zi = phase ? zi_b : zi_a;

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
reg signed [64:0] zrsq_cross;  // zr_hi * zr_lo_s (doubled for squaring)
reg signed [63:0] zisq_hh;
reg signed [64:0] zisq_cross;
reg signed [63:0] zrzi_hh;     // zr_hi * zi_hi
reg signed [64:0] zrzi_hl;     // zr_hi * zi_lo_s
reg signed [64:0] zrzi_lh;     // zr_lo_s * zi_hi
reg phase_d1;

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
// Stage 2: Accumulate + adds + escape (combinational)
// ============================================================
wire signed [65:0] zrsq_cross_2 = {zrsq_cross, 1'b0};
wire signed [95:0] zrsq_sum = {zrsq_hh, 32'd0} + {{30{zrsq_cross_2[65]}}, zrsq_cross_2};
wire signed [WIDTH-1:0] zr_sq = zrsq_sum[87:24];
wire [7:0] zr_sq_ovf = zrsq_sum[95:88];

wire signed [65:0] zisq_cross_2 = {zisq_cross, 1'b0};
wire signed [95:0] zisq_sum = {zisq_hh, 32'd0} + {{30{zisq_cross_2[65]}}, zisq_cross_2};
wire signed [WIDTH-1:0] zi_sq = zisq_sum[87:24];
wire [7:0] zi_sq_ovf = zisq_sum[95:88];

wire signed [65:0] zrzi_mid = {zrzi_hl[64], zrzi_hl} + {zrzi_lh[64], zrzi_lh};
wire signed [95:0] zrzi_sum = {zrzi_hh, 32'd0} + {{30{zrzi_mid[65]}}, zrzi_mid};
wire signed [WIDTH-1:0] zr_zi = zrzi_sum[87:24];

wire signed [WIDTH-1:0] two_zr_zi = {zr_zi[WIDTH-2:0], 1'b0};
wire signed [WIDTH-1:0] mag_sq = zr_sq + zi_sq;

wire zr_sq_overflow = |zr_sq_ovf | zr_sq[WIDTH-1];
wire zi_sq_overflow = |zi_sq_ovf | zi_sq[WIDTH-1];
wire sum_overflow   = ~zr_sq[WIDTH-1] & ~zi_sq[WIDTH-1] & mag_sq[WIDTH-1];
wire escape = zr_sq_overflow | zi_sq_overflow | sum_overflow |
              ($signed(mag_sq) > ESCAPE_THRESHOLD);

wire signed [WIDTH-1:0] s2_c_real = phase_d1 ? c_real_b : c_real_a;
wire signed [WIDTH-1:0] s2_c_imag = phase_d1 ? c_imag_b : c_imag_a;
wire signed [WIDTH-1:0] zr_next_std  = zr_sq - zi_sq + s2_c_real;
wire signed [WIDTH-1:0] zi_next_std  = two_zr_zi + s2_c_imag;
wire signed [WIDTH-1:0] zi_next = zi_next_std;

wire signed [WIDTH-1:0] cardioid_rhs_a = cardioid_ci_sq_a >>> 2;
wire signed [WIDTH-1:0] cardioid_rhs_b = cardioid_ci_sq_b >>> 2;

task automatic mandelbrot_start_a;
    input signed [WIDTH-1:0] cr_in;
    input signed [WIDTH-1:0] ci_in;
    begin
        done_a <= 1'b0;
        escaped_a <= 1'b0;
        iter_count_a <= 12'd0;
        final_mag_sq_a <= {WIDTH{1'b0}};
        iter_a <= 12'd0;
        primed_a <= 1'b0;
        c_real_a <= cr_in;
        c_imag_a <= ci_in;
        cardioid_x_a <= cr_in - QUARTER_FIXED;
        cardioid_ci_sq_a <= {WIDTH{1'b0}};
        zr_a <= cr_in - QUARTER_FIXED;
        zi_a <= ci_in;
        state_a <= S_PREP_Q;
    end
endtask

task automatic julia_start_a;
    input signed [WIDTH-1:0] cr_in;
    input signed [WIDTH-1:0] ci_in;
    begin
        done_a <= 1'b0;
        escaped_a <= 1'b0;
        iter_count_a <= 12'd0;
        final_mag_sq_a <= {WIDTH{1'b0}};
        iter_a <= 12'd0;
        primed_a <= 1'b0;
        zr_a <= cr_in;
        zi_a <= ci_in;
        c_real_a <= julia_cr;
        c_imag_a <= julia_ci;
        state_a <= S_ITER;
    end
endtask

task automatic mandelbrot_start_b;
    input signed [WIDTH-1:0] cr_in;
    input signed [WIDTH-1:0] ci_in;
    begin
        done_b <= 1'b0;
        escaped_b <= 1'b0;
        iter_count_b <= 12'd0;
        final_mag_sq_b <= {WIDTH{1'b0}};
        iter_b <= 12'd0;
        primed_b <= 1'b0;
        c_real_b <= cr_in;
        c_imag_b <= ci_in;
        cardioid_x_b <= cr_in - QUARTER_FIXED;
        cardioid_ci_sq_b <= {WIDTH{1'b0}};
        zr_b <= cr_in - QUARTER_FIXED;
        zi_b <= ci_in;
        state_b <= S_PREP_Q;
    end
endtask

task automatic julia_start_b;
    input signed [WIDTH-1:0] cr_in;
    input signed [WIDTH-1:0] ci_in;
    begin
        done_b <= 1'b0;
        escaped_b <= 1'b0;
        iter_count_b <= 12'd0;
        final_mag_sq_b <= {WIDTH{1'b0}};
        iter_b <= 12'd0;
        primed_b <= 1'b0;
        zr_b <= cr_in;
        zi_b <= ci_in;
        c_real_b <= julia_cr;
        c_imag_b <= julia_ci;
        state_b <= S_ITER;
    end
endtask

// ---- Context A state machine ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_a <= S_IDLE; done_a <= 1'b0; escaped_a <= 1'b0;
        iter_count_a <= 12'd0; final_mag_sq_a <= {WIDTH{1'b0}};
        zr_a <= {WIDTH{1'b0}}; zi_a <= {WIDTH{1'b0}};
        c_real_a <= {WIDTH{1'b0}}; c_imag_a <= {WIDTH{1'b0}}; iter_a <= 12'd0;
        primed_a <= 1'b0;
        cardioid_x_a <= {WIDTH{1'b0}};
        cardioid_ci_sq_a <= {WIDTH{1'b0}};
    end else begin
        case (state_a)
        S_IDLE: if (start_a) begin
            case (fractal_type)
                2'd0: mandelbrot_start_a(cr_a, ci_a);
                2'd1: julia_start_a(cr_a, ci_a);
                default: mandelbrot_start_a(cr_a, ci_a);
            endcase
        end
        S_PREP_Q: if (phase_d1 == 1'b0) begin
            if (!primed_a) begin
                primed_a <= 1'b1;
            end else begin
                cardioid_ci_sq_a <= zi_sq;
                zr_a <= mag_sq;
                zi_a <= mag_sq + cardioid_x_a;
                primed_a <= 1'b0;
                state_a <= S_CARDIOID;
            end
        end
        S_CARDIOID: if (phase_d1 == 1'b0) begin
            if (!primed_a) begin
                primed_a <= 1'b1;
            end else begin
                if ($signed(zr_zi) < $signed(cardioid_rhs_a)) begin
                    escaped_a <= 1'b0;
                    iter_count_a <= max_iter;
                    final_mag_sq_a <= {WIDTH{1'b0}};
                    done_a <= 1'b1;
                    state_a <= S_DONE;
                end else begin
                    zr_a <= c_real_a + ONE_FIXED;
                    zi_a <= c_imag_a;
                    primed_a <= 1'b0;
                    state_a <= S_BULB;
                end
            end
        end
        S_BULB: if (phase_d1 == 1'b0) begin
            if (!primed_a) begin
                primed_a <= 1'b1;
            end else begin
                if ($signed(mag_sq) < $signed(BULB_THRESHOLD)) begin
                    escaped_a <= 1'b0;
                    iter_count_a <= max_iter;
                    final_mag_sq_a <= {WIDTH{1'b0}};
                    done_a <= 1'b1;
                    state_a <= S_DONE;
                end else begin
                    zr_a <= {WIDTH{1'b0}};
                    zi_a <= {WIDTH{1'b0}};
                    iter_a <= 12'd0;
                    primed_a <= 1'b0;
                    state_a <= S_ITER;
                end
            end
        end
        S_ITER: if (phase_d1 == 1'b0) begin
            if (!primed_a) begin
                primed_a <= 1'b1;
            end else begin
                if (escape || (iter_a >= max_iter)) begin
                    escaped_a<=escape; iter_count_a<=iter_a; final_mag_sq_a<=mag_sq;
                    done_a<=1'b1; state_a<=S_DONE;
                end else begin
                    zr_a<=zr_next_std; zi_a<=zi_next; iter_a<=iter_a+12'd1;
                end
            end
        end
        S_DONE: if (start_a) begin
            case (fractal_type)
                2'd0: mandelbrot_start_a(cr_a, ci_a);
                2'd1: julia_start_a(cr_a, ci_a);
                default: mandelbrot_start_a(cr_a, ci_a);
            endcase
        end
        default: state_a <= S_IDLE;
        endcase
    end
end

// ---- Context B state machine ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state_b <= S_IDLE; done_b <= 1'b0; escaped_b <= 1'b0;
        iter_count_b <= 12'd0; final_mag_sq_b <= {WIDTH{1'b0}};
        zr_b <= {WIDTH{1'b0}}; zi_b <= {WIDTH{1'b0}};
        c_real_b <= {WIDTH{1'b0}}; c_imag_b <= {WIDTH{1'b0}}; iter_b <= 12'd0;
        primed_b <= 1'b0;
        cardioid_x_b <= {WIDTH{1'b0}};
        cardioid_ci_sq_b <= {WIDTH{1'b0}};
    end else begin
        case (state_b)
        S_IDLE: if (start_b) begin
            case (fractal_type)
                2'd0: mandelbrot_start_b(cr_b, ci_b);
                2'd1: julia_start_b(cr_b, ci_b);
                default: mandelbrot_start_b(cr_b, ci_b);
            endcase
        end
        S_PREP_Q: if (phase_d1 == 1'b1) begin
            if (!primed_b) begin
                primed_b <= 1'b1;
            end else begin
                cardioid_ci_sq_b <= zi_sq;
                zr_b <= mag_sq;
                zi_b <= mag_sq + cardioid_x_b;
                primed_b <= 1'b0;
                state_b <= S_CARDIOID;
            end
        end
        S_CARDIOID: if (phase_d1 == 1'b1) begin
            if (!primed_b) begin
                primed_b <= 1'b1;
            end else begin
                if ($signed(zr_zi) < $signed(cardioid_rhs_b)) begin
                    escaped_b <= 1'b0;
                    iter_count_b <= max_iter;
                    final_mag_sq_b <= {WIDTH{1'b0}};
                    done_b <= 1'b1;
                    state_b <= S_DONE;
                end else begin
                    zr_b <= c_real_b + ONE_FIXED;
                    zi_b <= c_imag_b;
                    primed_b <= 1'b0;
                    state_b <= S_BULB;
                end
            end
        end
        S_BULB: if (phase_d1 == 1'b1) begin
            if (!primed_b) begin
                primed_b <= 1'b1;
            end else begin
                if ($signed(mag_sq) < $signed(BULB_THRESHOLD)) begin
                    escaped_b <= 1'b0;
                    iter_count_b <= max_iter;
                    final_mag_sq_b <= {WIDTH{1'b0}};
                    done_b <= 1'b1;
                    state_b <= S_DONE;
                end else begin
                    zr_b <= {WIDTH{1'b0}};
                    zi_b <= {WIDTH{1'b0}};
                    iter_b <= 12'd0;
                    primed_b <= 1'b0;
                    state_b <= S_ITER;
                end
            end
        end
        S_ITER: if (phase_d1 == 1'b1) begin
            if (!primed_b) begin
                primed_b <= 1'b1;
            end else begin
                if (escape || (iter_b >= max_iter)) begin
                    escaped_b<=escape; iter_count_b<=iter_b; final_mag_sq_b<=mag_sq;
                    done_b<=1'b1; state_b<=S_DONE;
                end else begin
                    zr_b<=zr_next_std; zi_b<=zi_next; iter_b<=iter_b+12'd1;
                end
            end
        end
        S_DONE: if (start_b) begin
            case (fractal_type)
                2'd0: mandelbrot_start_b(cr_b, ci_b);
                2'd1: julia_start_b(cr_b, ci_b);
                default: mandelbrot_start_b(cr_b, ci_b);
            endcase
        end
        default: state_b <= S_IDLE;
        endcase
    end
end

endmodule
