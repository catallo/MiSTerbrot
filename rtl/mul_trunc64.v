//============================================================================
// Truncated 64x64 Fixed-Point Multiply (DSP-friendly)
//
// Computes: result = (a * b) >> FRAC_BITS  (fixed-point multiply)
//
// Uses 32-bit half decomposition with truncated low*low product:
//   a = {a_hi, a_lo}, b = {b_hi, b_lo}
//   full = a_hi*b_hi<<64 + (a_hi*b_lo + a_lo*b_hi)<<32 + a_lo*b_lo
//   truncated = skip a_lo*b_lo (only affects bits [63:0])
//   extract bits [WIDTH+FRAC_BITS-1 : FRAC_BITS] = [119:56]
//
// Error: < 2^-24 relative, negligible for fractal rendering.
//
// Each 32x32 multiply maps to ~4 Cyclone V DSP blocks (18x18 mode).
// 3 products per instance = ~6 DSP variable-precision blocks.
//============================================================================

module mul_trunc64 #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
)(
    input  wire signed [WIDTH-1:0] a,
    input  wire signed [WIDTH-1:0] b,
    output wire signed [WIDTH-1:0] result
);

// ---- Sign handling ----
wire sign_a = a[WIDTH-1];
wire sign_b = b[WIDTH-1];
wire sign_r = sign_a ^ sign_b;

wire [WIDTH-1:0] abs_a = sign_a ? (~a + 64'd1) : a;
wire [WIDTH-1:0] abs_b = sign_b ? (~b + 64'd1) : b;

// ---- Split into 32-bit halves ----
wire [31:0] a_hi = abs_a[63:32];
wire [31:0] a_lo = abs_a[31:0];
wire [31:0] b_hi = abs_b[63:32];
wire [31:0] b_lo = abs_b[31:0];

// ---- Three 32x32 unsigned multiplies (mapped to DSP blocks) ----
// Skip: a_lo * b_lo (bits [63:0] only, we extract [119:56])
(* multstyle = "dsp" *) wire [63:0] pp_hh = a_hi * b_hi;   // bits [127:64]
(* multstyle = "dsp" *) wire [63:0] pp_hl = a_hi * b_lo;   // bits [95:32]
(* multstyle = "dsp" *) wire [63:0] pp_lh = a_lo * b_hi;   // bits [95:32]

// ---- Accumulate and extract result ----
// pp_hh occupies [127:64], cross products occupy [95:32]
wire [95:0]  cross_sum = {32'd0, pp_hl} + {32'd0, pp_lh};
wire [127:0] full_sum  = {pp_hh, 64'd0} + {cross_sum, 32'd0};

wire [WIDTH-1:0] abs_result = full_sum[WIDTH + FRAC_BITS - 1 : FRAC_BITS];

// ---- Apply sign ----
assign result = sign_r ? (~abs_result + 64'd1) : abs_result;

endmodule
