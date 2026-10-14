//============================================================================
// Iterator Quad — eight Mandelbrot iterators sharing one set of truncated
// 64x64 multiplies (27-bit limb split, 15 DSP blocks) by 8-context
// time-multiplexing.
//
// 2026-10-14 rewrite ("context store in MLAB"):
//   * Per-context 64-bit values (z, c, ci^2, the Brent snapshot) live in
//     small RAM arrays indexed by the phase counter instead of register
//     files selected by 6:1 muxes.  The operand mux that failed timing on
//     every 100 MHz seed since July is now an MLAB read.
//   * One shared writeback stage (S6) owns the single write port; the
//     per-context state machines are reduced to a few flag registers.
//   * A pixel load is performed in the context's own writeback slot from
//     the (stable) per-slot coordinate ports, so no pass is ever wasted on
//     "priming": the pass right after any writeback already sees the new
//     operands.  (The old design spent one full pass per state transition.)
//   * The evaluation stage is split: S4 = clamp + magnitude add, S5 =
//     compares + next-z adds, S6 = decision + writeback.  Every stage
//     carries at most one 64-bit adder/comparator.
//
// 2026-10-14 (b), for a 118 MHz iterator clock: one more stage in the
// multiplier limb combine (S2a0: the first-level sums straight off the
// DSP output registers, so S2a1 has a single adder level), cr-1/4 kept
// in its own context RAM (the cardioid operand is one add instead of
// two), the |ci|-P3_CY operand as a ternary add, and the per-context
// flag writeback registered one stage after the RAM writeback (S7).
//
// Pipeline (read at phase == k, RAM writeback at phase_d6 == k, flag
// writeback at phase_d7 == k; 8-cycle loop on the 8-cycle context period:
// the RAM write lands on the edge that starts the context's next S0 read,
// which is the ordinary MLAB write-then-read-next-cycle case):
//   S0  : RAM read z[phase] -> DSP input registers
//   S1  : DSP partial products (registered)
//   S2a0: first-level limb sums (one 33-bit adder level off the DSPs)
//   S2a1: lower-half 32-bit adds + carry
//   S2a2: upper-half 32-bit adds + assemble {zr_sq, zi_sq, zr_zi, ovf}
//   S4  : clamp, mag_sq / zr_diff adds, context reads (c, ci^2, snap, flags)
//   S5  : escape / precheck compares, z_next and precheck-operand adds
//   S6  : state decision, RAM writeback; decision registered
//   S7  : per-context flag writeback
//
// Results are bit-identical to the 6-context design: same multiplier
// split, same clamps, same escape and precheck arithmetic, same Brent
// periodicity schedule.
//============================================================================

// AUTO_SHIFT_REGISTER_RECOGNITION OFF: Quartus 17.0 folded a quad's delay
// chains into an M10K altshift_taps (despite preserve/dont_merge), whose
// read path missed 100 MHz.  Keep every pipeline delay register in logic.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module iter_quad #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56,
    parameter NCTX      = 8     // fixed: the phase counter is 3 bits wide
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [11:0]             max_iter,

    // A3 (period-3 bulb precheck) per-frame enable.  Slow-changing on
    // clk_sys; settling glitches harmless because view_changed forces a
    // frame restart that flushes all in-flight contexts.
    input  wire                    p3_precheck_enable,

    // P2 (Brent periodicity detection) enable.  Same CDC treatment.  A
    // 48-bit {zr[23:0], zi[23:0]} snapshot can never miss a true cycle;
    // a false positive (~2^-48 per compare) is invisible.
    input  wire                    periodicity_enable,

    // Per-context slot ports.  cr/ci are pixel_pipeline's per-slot
    // registers: written at dispatch, stable until the slot is collected,
    // and (CDC contract, see MiSTerbrot.sdc) stable >= 2 clk cycles
    // before the synchronized start pulse.  The quad samples them in the
    // context's own slot after the pulse.
    input  wire [NCTX-1:0]         start,
    input  wire [NCTX*WIDTH-1:0]   cr_flat,
    input  wire [NCTX*WIDTH-1:0]   ci_flat,
    output wire [NCTX-1:0]         done,
    output wire [NCTX*12-1:0]      iter_count_flat,
    output wire [NCTX-1:0]         escaped
);

localparam signed [WIDTH-1:0] ESCAPE_THRESHOLD = {{(WIDTH-FRAC_BITS-3){1'b0}}, 1'b1, {(FRAC_BITS+2){1'b0}}};
localparam signed [WIDTH-1:0] ONE_FIXED        = {{(WIDTH-FRAC_BITS-1){1'b0}}, 1'b1, {FRAC_BITS{1'b0}}};
localparam signed [WIDTH-1:0] QUARTER_FIXED    = {{(WIDTH-FRAC_BITS+1){1'b0}}, 1'b1, {(FRAC_BITS-2){1'b0}}};
localparam signed [WIDTH-1:0] BULB_THRESHOLD   = {{(WIDTH-FRAC_BITS+3){1'b0}}, 1'b1, {(FRAC_BITS-4){1'b0}}};

// A3: period-3 bulb precheck constants (8.56 fixed-point).
//   Upper bulb center: (-0.1225611669, +0.7448617666); lower: conjugate (via |ci|).
//   Inscribed-circle radius r = 0.075 -> r^2 = 0.005625.
localparam signed [WIDTH-1:0] P3_CX_FIXED   = 64'shFFE09FD4D467A7AD;  // -0.1225611669
localparam signed [WIDTH-1:0] P3_CY_FIXED   = 64'sh00BEAF42BF967918;  // +0.7448617666
localparam signed [WIDTH-1:0] P3_R_SQ_FIXED = 64'sh000170A3D70A3D71;  //  0.0056250000

localparam [2:0] S_IDLE     = 3'd0,
                 S_LOAD     = 3'd1,  // start seen; load in the next own slot
                 S_PREP_Q   = 3'd2,
                 S_CARDIOID = 3'd3,
                 S_BULB     = 3'd4,
                 S_BULB3    = 3'd5,  // A3: period-3 bulb precheck
                 S_ITER     = 3'd6,
                 S_DONE     = 3'd7;

function range_ok;              // value in (-4, 4): bits [63:58] a pure sign extension
    input signed [WIDTH-1:0] v;
    range_ok = (v[WIDTH-1:58] == 6'b000000) || (v[WIDTH-1:58] == 6'b111111);
endfunction

// ---- Per-context flag registers (the only per-context state in FFs) ----
reg [2:0]  ctx_state      [0:NCTX-1];
reg        ctx_done       [0:NCTX-1];
reg        ctx_escaped    [0:NCTX-1];
reg [11:0] ctx_iter_count [0:NCTX-1];
reg [11:0] ctx_iter       [0:NCTX-1];
reg        ctx_zbig       [0:NCTX-1];  // current z/precheck operands outside (-4, 4)
reg        ctx_pre_bad    [0:NCTX-1];  // the (cr-1/4, ci) load was out of range: q invalid
reg        ctx_qok        [0:NCTX-1];  // cardioid product operands valid (q < 2, q itself valid)
reg        ctx_snap_ok    [0:NCTX-1];  // a Brent snapshot has been taken for this pixel
reg        ctx_phit       [0:NCTX-1];  // current z equals the snapshot (evaluated at writeback)

// ---- Per-context values in RAM (one shared write port, S6) ----
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_zr   [0:NCTX-1];
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_zi   [0:NCTX-1];
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_cr   [0:NCTX-1];  // c real
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_crq  [0:NCTX-1];  // c real - 1/4 (cardioid x operand)
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_ci   [0:NCTX-1];  // c imag
(* ramstyle = "MLAB" *) reg [WIDTH-1:0] mem_cisq [0:NCTX-1];  // ci^2 (clamped), cardioid rhs source
(* ramstyle = "MLAB" *) reg [47:0]      mem_snap [0:NCTX-1];  // Brent snapshot {zr[23:0], zi[23:0]}

// ---- Port fan-in / fan-out ----
wire signed [WIDTH-1:0] ctx_cr_in [0:NCTX-1];
wire signed [WIDTH-1:0] ctx_ci_in [0:NCTX-1];
genvar gp;
generate
for (gp = 0; gp < NCTX; gp = gp + 1) begin : ports
    assign ctx_cr_in[gp]                 = cr_flat[gp*WIDTH +: WIDTH];
    assign ctx_ci_in[gp]                 = ci_flat[gp*WIDTH +: WIDTH];
    assign done[gp]                      = ctx_done[gp];
    assign escaped[gp]                   = ctx_escaped[gp];
    assign iter_count_flat[gp*12 +: 12]  = ctx_iter_count[gp];
end
endgenerate

// ---- Phase counter and delay chain ----
// phase addresses the operand read (S0); phase_d4 the context reads in S4;
// phase_d6 the RAM writeback (S6); phase_d7 the flag writeback (S7).  preserve/dont_merge: these are the RAM
// address registers and the writeback decode — never let the fitter
// share them across quads (congested fits have routed one quad's phase
// into another quad's logic).
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d0;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d1;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d2;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d3;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d4;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d5;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d6;
(* preserve = "true", dont_merge = "true" *) reg [2:0] phase_d7;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase    <= 3'd0;
        phase_d0 <= 3'd0; phase_d1 <= 3'd0; phase_d2 <= 3'd0;
        phase_d3 <= 3'd0; phase_d4 <= 3'd0; phase_d5 <= 3'd0;
        phase_d6 <= 3'd0; phase_d7 <= 3'd0;
    end else begin
        phase    <= phase + 3'd1;   // NCTX == 8: wraps naturally
        phase_d0 <= phase;
        phase_d1 <= phase_d0;
        phase_d2 <= phase_d1;
        phase_d3 <= phase_d2;
        phase_d4 <= phase_d3;
        phase_d5 <= phase_d4;
        phase_d6 <= phase_d5;
        phase_d7 <= phase_d6;
    end
end

// Per-quad registered copy of max_iter: pixel_pipeline's single register
// fanned out to every context compare of five quads (82% interconnect on
// the worst path).  Quasi-static, already two-flop synced upstream.
(* preserve = "true", dont_merge = "true" *) reg [11:0] max_iter_q;
always @(posedge clk) max_iter_q <= max_iter;

// ============================================================
// S0: operand read.  The registered read of a phase-indexed array is
// the MLAB template; the registers pack into the DSP input stage.
// ============================================================
reg signed [WIDTH-1:0] mul_zr_r, mul_zi_r;
// Writeback signals (driven in S6 below).
reg                    wr_z_en;
reg signed [WIDTH-1:0] wr_zr, wr_zi;
always @(posedge clk) begin
    if (wr_z_en) mem_zr[phase_d6] <= wr_zr;
    mul_zr_r <= mem_zr[phase];
end
always @(posedge clk) begin
    if (wr_z_en) mem_zi[phase_d6] <= wr_zi;
    mul_zi_r <= mem_zi[phase];
end

// ---- Split registered operands: 27-bit signed high limb + 32-bit low limb ----
// The high limb is bits [58:32] (sign + 2 integer bits + 24 fraction bits),
// i.e. the operand must lie in (-4, 4).  Every value this pipeline multiplies
// does, by construction or by guard:
//   * iteration operands z_n: not escaped => |z_n|^2 <= 4;
//   * a freshly formed z_{n+1} outside (-4, 4) is flagged (ctx_zbig) and
//     treated as escaped on its pass — exactly what the full-width square
//     would have concluded (|z|^2 >= 16 > 4);
//   * precheck operands out of range mark the precheck "not inside", which
//     is what the true value gives too; the cardioid product q*(q+x) is
//     additionally gated on q < 2 (inside needs q < 1, and q < 2 bounds
//     |q+x| < 3.42).
// 27x27 signed = one Cyclone V DSP block, 27x33 = two: 15 blocks per quad.
wire signed [26:0] zr_hi = mul_zr_r[58:32];
wire        [31:0] zr_lo = mul_zr_r[31:0];
wire signed [26:0] zi_hi = mul_zi_r[58:32];
wire        [31:0] zi_lo = mul_zi_r[31:0];
wire signed [32:0] zr_lo_s = {1'b0, zr_lo};
wire signed [32:0] zi_lo_s = {1'b0, zi_lo};

// ============================================================
// S1: DSP partial products (registered)
// ============================================================
reg signed [63:0] zrsq_hh;     // zr_hi * zr_hi
reg signed [64:0] zrsq_cross;  // zr_hi * zr_lo_s (doubled in 2a1)
reg signed [63:0] zisq_hh;
reg signed [64:0] zisq_cross;
reg signed [63:0] zrzi_hh;
reg signed [64:0] zrzi_hl;
reg signed [64:0] zrzi_lh;

wire signed [53:0] zrsq_hh_p    = zr_hi   * zr_hi;    // 27x27 -> 1 DSP
wire signed [59:0] zrsq_cross_p = zr_hi   * zr_lo_s;  // 27x33 -> 2 DSP
wire signed [53:0] zisq_hh_p    = zi_hi   * zi_hi;
wire signed [59:0] zisq_cross_p = zi_hi   * zi_lo_s;
wire signed [53:0] zrzi_hh_p    = zr_hi   * zi_hi;
wire signed [59:0] zrzi_hl_p    = zr_hi   * zi_lo_s;
wire signed [59:0] zrzi_lh_p    = zr_lo_s * zi_hi;
always @(posedge clk) begin
    zrsq_hh    <= {{10{zrsq_hh_p[53]}},    zrsq_hh_p};
    zrsq_cross <= {{ 5{zrsq_cross_p[59]}}, zrsq_cross_p};
    zisq_hh    <= {{10{zisq_hh_p[53]}},    zisq_hh_p};
    zisq_cross <= {{ 5{zisq_cross_p[59]}}, zisq_cross_p};
    zrzi_hh    <= {{10{zrzi_hh_p[53]}},    zrzi_hh_p};
    zrzi_hl    <= {{ 5{zrzi_hl_p[59]}},    zrzi_hl_p};
    zrzi_lh    <= {{ 5{zrzi_lh_p[59]}},    zrzi_lh_p};
end

// ============================================================
// S2a0: first-level limb sums, one adder level off the DSP output
// registers.  (At 118 MHz the DSP -> LAB hop plus the two serial 33-bit
// adds of the old S2a1 was the longest cone in the quad.)
//   squares : lo word = hh[31:0] + cross_2[63:32]  (33-bit, with carry)
//   zr*zi   : the two cross terms' low words, hl[31:0] + lh[31:0]; the
//             word slices S2a1 still needs are re-registered here.
// ============================================================
wire signed [65:0] zrsq_cross_2_w = {zrsq_cross, 1'b0};
wire signed [65:0] zisq_cross_2_w = {zisq_cross, 1'b0};

reg [32:0]        a0_zrsq_lo_sum, a0_zisq_lo_sum;
reg signed [31:0] a0_zrsq_hh_hi,  a0_zisq_hh_hi;
reg [1:0]         a0_zrsq_cross_top, a0_zisq_cross_top;   // cross_2[65:64]; [1] = sign
reg [31:0]        a0_zrsq_pass,   a0_zisq_pass;
reg [32:0]        a0_zrzi_mid_lo_sum;                      // hl[31:0] + lh[31:0]
reg [32:0]        a0_zrzi_hl_hi,  a0_zrzi_lh_hi;           // [64:32] (bit 32 = sign)
reg [31:0]        a0_zrzi_hh_lo;
reg signed [31:0] a0_zrzi_hh_hi;

always @(posedge clk) begin
    a0_zrsq_lo_sum     <= {1'b0, zrsq_hh[31:0]} + {1'b0, zrsq_cross_2_w[63:32]};
    a0_zrsq_hh_hi      <= zrsq_hh[63:32];
    a0_zrsq_cross_top  <= zrsq_cross_2_w[65:64];
    a0_zrsq_pass       <= zrsq_cross_2_w[31:0];

    a0_zisq_lo_sum     <= {1'b0, zisq_hh[31:0]} + {1'b0, zisq_cross_2_w[63:32]};
    a0_zisq_hh_hi      <= zisq_hh[63:32];
    a0_zisq_cross_top  <= zisq_cross_2_w[65:64];
    a0_zisq_pass       <= zisq_cross_2_w[31:0];

    a0_zrzi_mid_lo_sum <= {1'b0, zrzi_hl[31:0]} + {1'b0, zrzi_lh[31:0]};
    a0_zrzi_hl_hi      <= zrzi_hl[64:32];
    a0_zrzi_lh_hi      <= zrzi_lh[64:32];
    a0_zrzi_hh_lo      <= zrzi_hh[31:0];
    a0_zrzi_hh_hi      <= zrzi_hh[63:32];
end

// ============================================================
// S2a1: lower-half 32-bit add of the 96-bit accumulation
//   bits [31:0]  = passthrough (cross_2[31:0]; hh has 0 here)
//   bits [95:32] = hh + sign_extended(cross_2[65:32]), split 32/32 with carry
// The squares' lower word is already summed (S2a0); zr*zi folds the
// mid-word carry from S2a0 into one adder level here.
// ============================================================
wire signed [33:0] zrzi_mid_hi_sum_w =
    $signed({a0_zrzi_hl_hi[32], a0_zrzi_hl_hi}) +
    $signed({a0_zrzi_lh_hi[32], a0_zrzi_lh_hi}) +
    $signed({33'd0, a0_zrzi_mid_lo_sum[32]});
wire [32:0] zrzi_mid_word_sum_w = {1'b0, a0_zrzi_hl_hi[31:0]} +
                                  {1'b0, a0_zrzi_lh_hi[31:0]} +
                                  {32'd0, a0_zrzi_mid_lo_sum[32]};
wire [31:0] zrzi_word_sum_w   = a0_zrzi_hh_lo ^ a0_zrzi_hl_hi[31:0] ^ a0_zrzi_lh_hi[31:0];
wire [32:0] zrzi_word_carry_w = {((a0_zrzi_hh_lo       & a0_zrzi_hl_hi[31:0]) |
                                  (a0_zrzi_hh_lo       & a0_zrzi_lh_hi[31:0]) |
                                  (a0_zrzi_hl_hi[31:0] & a0_zrzi_lh_hi[31:0])), 1'b0};
wire [32:0] zrzi_word_total_w = {1'b0, zrzi_word_sum_w} +
                                zrzi_word_carry_w +
                                {32'd0, a0_zrzi_mid_lo_sum[32]};
wire [32:0] zrzi_lo_sum_w = {zrzi_word_total_w[32] ^ zrzi_mid_word_sum_w[32],
                             zrzi_word_total_w[31:0]};

reg [31:0] zrsq_lo_r,    zisq_lo_r,    zrzi_lo_r;
reg        zrsq_carry_r, zisq_carry_r, zrzi_carry_r;
reg signed [31:0] zrsq_hh_hi_r, zisq_hh_hi_r, zrzi_hh_hi_r;
reg        zrsq_cross_sign_r, zisq_cross_sign_r, zrzi_mid_sign_r;
reg [1:0]  zrsq_cross_top_r, zisq_cross_top_r, zrzi_mid_top_r;
reg [31:0] zrsq_pass_r, zisq_pass_r, zrzi_pass_r;

always @(posedge clk) begin
    zrsq_lo_r         <= a0_zrsq_lo_sum[31:0];
    zrsq_carry_r      <= a0_zrsq_lo_sum[32];
    zrsq_hh_hi_r      <= a0_zrsq_hh_hi;
    zrsq_cross_sign_r <= a0_zrsq_cross_top[1];
    zrsq_cross_top_r  <= a0_zrsq_cross_top;
    zrsq_pass_r       <= a0_zrsq_pass;

    zisq_lo_r         <= a0_zisq_lo_sum[31:0];
    zisq_carry_r      <= a0_zisq_lo_sum[32];
    zisq_hh_hi_r      <= a0_zisq_hh_hi;
    zisq_cross_sign_r <= a0_zisq_cross_top[1];
    zisq_cross_top_r  <= a0_zisq_cross_top;
    zisq_pass_r       <= a0_zisq_pass;

    zrzi_lo_r         <= zrzi_lo_sum_w[31:0];
    zrzi_carry_r      <= zrzi_lo_sum_w[32];
    zrzi_hh_hi_r      <= a0_zrzi_hh_hi;
    zrzi_mid_sign_r   <= zrzi_mid_hi_sum_w[33];
    zrzi_mid_top_r    <= zrzi_mid_hi_sum_w[33:32];
    zrzi_pass_r       <= a0_zrzi_mid_lo_sum[31:0];
end

// ============================================================
// S2a2: upper-half 32-bit add (with carry) + slice assemble
// ============================================================
wire signed [31:0] zrsq_b_hi = $signed({{30{zrsq_cross_sign_r}}, zrsq_cross_top_r});
wire signed [31:0] zisq_b_hi = $signed({{30{zisq_cross_sign_r}}, zisq_cross_top_r});
wire signed [31:0] zrzi_b_hi = $signed({{30{zrzi_mid_sign_r}},   zrzi_mid_top_r});

wire [32:0] zrsq_hi_sum_w = {1'b0, zrsq_hh_hi_r} + {1'b0, zrsq_b_hi} + {32'd0, zrsq_carry_r};
wire [32:0] zisq_hi_sum_w = {1'b0, zisq_hh_hi_r} + {1'b0, zisq_b_hi} + {32'd0, zisq_carry_r};
wire [32:0] zrzi_hi_sum_w = {1'b0, zrzi_hh_hi_r} + {1'b0, zrzi_b_hi} + {32'd0, zrzi_carry_r};

wire [95:0] zrsq_sum_w = {zrsq_hi_sum_w[31:0], zrsq_lo_r, zrsq_pass_r};
wire [95:0] zisq_sum_w = {zisq_hi_sum_w[31:0], zisq_lo_r, zisq_pass_r};
wire [95:0] zrzi_sum_w = {zrzi_hi_sum_w[31:0], zrzi_lo_r, zrzi_pass_r};

reg signed [WIDTH-1:0] zr_sq, zi_sq, zr_zi;
reg [7:0]              zr_sq_ovf, zi_sq_ovf;
always @(posedge clk) begin
    zr_sq     <= zrsq_sum_w[87:24];
    zi_sq     <= zisq_sum_w[87:24];
    zr_zi     <= zrzi_sum_w[87:24];
    zr_sq_ovf <= zrsq_sum_w[95:88];
    zi_sq_ovf <= zisq_sum_w[95:88];
end

// ============================================================
// S4: clamp + magnitude adds; context reads for context phase_d4
// ============================================================
// The truncated multiplier can produce a tiny negative square; a negative
// square sign-extends through the overflow bits and would fire a spurious
// escape at iter 1..2 (pink cy=0 deep-zoom POIs).  Clamp to zero first.
wire signed [WIDTH-1:0] zr_sq_c     = zr_sq[WIDTH-1] ? {WIDTH{1'b0}} : zr_sq;
wire signed [WIDTH-1:0] zi_sq_c     = zi_sq[WIDTH-1] ? {WIDTH{1'b0}} : zi_sq;
wire [7:0]              zr_sq_ovf_c = zr_sq[WIDTH-1] ? 8'b0 : zr_sq_ovf;
wire [7:0]              zi_sq_ovf_c = zi_sq[WIDTH-1] ? 8'b0 : zi_sq_ovf;

reg signed [WIDTH-1:0] s4_mag_sq;      // zr_sq_c + zi_sq_c (bit 63 = sum overflow)
reg signed [WIDTH-1:0] s4_zr_diff;     // zr_sq_c - zi_sq_c
reg signed [WIDTH-1:0] s4_two_zr_zi;
reg signed [WIDTH-1:0] s4_zr_zi;
reg signed [WIDTH-1:0] s4_zi_sq_c;
reg                    s4_sq_ovf;      // either square overflowed its window
reg signed [WIDTH-1:0] s4_c_real, s4_crq, s4_c_imag, s4_ci_sq;
reg [47:0]             s4_snap;
reg signed [WIDTH-1:0] s4_ld_cr, s4_ld_ci;
reg [2:0]              s4_state;
reg                    s4_zbig, s4_qok, s4_pre_bad, s4_snap_ok, s4_phit;
reg [11:0]             s4_iter;

always @(posedge clk) begin
    s4_mag_sq    <= zr_sq_c + zi_sq_c;
    s4_zr_diff   <= zr_sq_c - zi_sq_c;
    s4_two_zr_zi <= {zr_zi[WIDTH-2:0], 1'b0};
    s4_zr_zi     <= zr_zi;
    s4_zi_sq_c   <= zi_sq_c;
    s4_sq_ovf    <= (|zr_sq_ovf_c) | (|zi_sq_ovf_c);
    s4_ld_cr     <= ctx_cr_in[phase_d4];
    s4_ld_ci     <= ctx_ci_in[phase_d4];
    s4_state     <= ctx_state[phase_d4];
    s4_zbig      <= ctx_zbig[phase_d4];
    s4_qok       <= ctx_qok[phase_d4];
    s4_pre_bad   <= ctx_pre_bad[phase_d4];
    s4_snap_ok   <= ctx_snap_ok[phase_d4];
    s4_phit      <= ctx_phit[phase_d4];
    s4_iter      <= ctx_iter[phase_d4];
end
// RAM reads (one always block per array, registered read = MLAB template).
reg                    wr_c_en, wr_cisq_en, wr_snap_en;
reg signed [WIDTH-1:0] wr_cr, wr_crq, wr_ci, wr_cisq;
reg [47:0]             wr_snap;
always @(posedge clk) begin
    if (wr_c_en) mem_cr[phase_d6] <= wr_cr;
    s4_c_real <= mem_cr[phase_d4];
end
always @(posedge clk) begin
    if (wr_c_en) mem_crq[phase_d6] <= wr_crq;
    s4_crq <= mem_crq[phase_d4];
end
always @(posedge clk) begin
    if (wr_c_en) mem_ci[phase_d6] <= wr_ci;
    s4_c_imag <= mem_ci[phase_d4];
end
always @(posedge clk) begin
    if (wr_cisq_en) mem_cisq[phase_d6] <= wr_cisq;
    s4_ci_sq <= mem_cisq[phase_d4];
end
always @(posedge clk) begin
    if (wr_snap_en) mem_snap[phase_d6] <= wr_snap;
    s4_snap <= mem_snap[phase_d4];
end

// ============================================================
// S5: compares and the adds whose results S6 may write back
// ============================================================
wire signed [WIDTH-1:0] s5_zr_next_w = s4_zr_diff   + s4_c_real;
wire signed [WIDTH-1:0] s5_zi_next_w = s4_two_zr_zi + s4_c_imag;
wire signed [WIDTH-1:0] s5_c_plus1_w = s4_c_real + ONE_FIXED;
wire signed [WIDTH-1:0] s5_p3_zr_w   = s4_c_real - P3_CX_FIXED;
// |ci| - P3_CY as one ternary add (bit-exact with the negate-then-subtract
// form: -a - b = ~a + ~b + 2, a - b = a + ~b + 1 in two's complement).
wire signed [WIDTH-1:0] s5_p3_zi_w   = (s4_c_imag[WIDTH-1] ? ~s4_c_imag : s4_c_imag) +
                                       ~P3_CY_FIXED +
                                       $signed({{(WIDTH-2){1'b0}}, s4_c_imag[WIDTH-1], ~s4_c_imag[WIDTH-1]});
wire signed [WIDTH-1:0] s5_ld_zr_w   = s4_ld_cr - QUARTER_FIXED;

reg                    s5_escape, s5_cardioid, s5_bulb, s5_p3;
reg signed [WIDTH-1:0] s5_zr_next, s5_zi_next;
reg signed [WIDTH-1:0] s5_q, s5_q_plus_x;
reg                    s5_q_small;     // q < 2: cardioid product operands valid
reg signed [WIDTH-1:0] s5_zi_sq_c;
reg signed [WIDTH-1:0] s5_c_plus1, s5_c_imag, s5_p3_zr, s5_p3_zi;
reg                    s5_bulb_bad, s5_p3_bad;
reg signed [WIDTH-1:0] s5_ld_zr, s5_ld_cr, s5_ld_ci;
reg                    s5_ld_bad;
reg [2:0]              s5_state;
reg                    s5_pre_bad, s5_snap_ok, s5_phit, s5_limit, s5_snap_sched;
reg [11:0]             s5_iter, s5_iter_inc;
reg [47:0]             s5_snap;

always @(posedge clk) begin
    // ctx_zbig: this pass's operands were outside (-4, 4) => products are
    // meaningless, but |z| >= 4 has certainly escaped.
    s5_escape     <= s4_zbig | s4_sq_ovf | s4_mag_sq[WIDTH-1] |
                     ($signed(s4_mag_sq) > ESCAPE_THRESHOLD);
    s5_cardioid   <= s4_qok && ($signed(s4_zr_zi) < $signed(s4_ci_sq >>> 2));
    s5_bulb       <= !s4_zbig && ($signed(s4_mag_sq) < $signed(BULB_THRESHOLD));
    s5_p3         <= !s4_zbig && ($signed(s4_mag_sq) < $signed(P3_R_SQ_FIXED));
    s5_zr_next    <= s5_zr_next_w;
    s5_zi_next    <= s5_zi_next_w;
    s5_q          <= s4_mag_sq;
    s5_q_small    <= (s4_mag_sq[WIDTH-1:57] == 7'd0);
    s5_q_plus_x   <= s4_mag_sq + s4_crq;    // q + (cr - 1/4); cr - 1/4 precomputed at load
    s5_zi_sq_c    <= s4_zi_sq_c;
    s5_c_plus1    <= s5_c_plus1_w;
    s5_c_imag     <= s4_c_imag;
    s5_bulb_bad   <= !(range_ok(s5_c_plus1_w) && range_ok(s4_c_imag));
    s5_p3_zr      <= s5_p3_zr_w;
    s5_p3_zi      <= s5_p3_zi_w;
    s5_p3_bad     <= !(range_ok(s5_p3_zr_w) && range_ok(s5_p3_zi_w));
    s5_ld_zr      <= s5_ld_zr_w;
    s5_ld_cr      <= s4_ld_cr;
    s5_ld_ci      <= s4_ld_ci;
    s5_ld_bad     <= !(range_ok(s5_ld_zr_w) && range_ok(s4_ld_ci));
    s5_state      <= s4_state;
    s5_pre_bad    <= s4_pre_bad;
    s5_snap_ok    <= s4_snap_ok;
    s5_phit       <= s4_phit;
    s5_limit      <= (s4_iter >= max_iter_q);
    s5_iter       <= s4_iter;
    s5_iter_inc   <= s4_iter + 12'd1;
    // Brent schedule: re-capture when the NEW count (iter+1) is a power
    // of two: (x+1) & x == 0.
    s5_snap_sched <= periodicity_enable && (((s4_iter + 12'd1) & s4_iter) == 12'd0);
    s5_snap       <= s4_snap;
end

// ============================================================
// S6: decision + RAM writeback for context phase_d6 (shared logic);
//     the flag decision is registered and applied in S7
// ============================================================
wire       s6_next_bad = !(range_ok(s5_zr_next) && range_ok(s5_zi_next));
wire [47:0] s6_snap_new = {s5_zr_next[23:0], s5_zi_next[23:0]};

// Decision outputs (combinational, consumed by the RAM ports and the
// per-context flag registers below).
reg        wb_act;          // this slot's state is active: apply the writeback
reg [2:0]  wb_state;
reg        wb_done, wb_escaped;
reg [11:0] wb_iter_count, wb_iter;
reg        wb_zbig, wb_pre_bad, wb_qok, wb_snap_ok, wb_phit;

always @(*) begin
    // defaults: keep flags, no RAM writes
    wb_act        = 1'b0;
    wb_state      = s5_state;
    wb_done       = 1'b0;
    wb_escaped    = 1'b0;
    wb_iter_count = 12'd0;
    wb_iter       = s5_iter;
    wb_zbig       = 1'b0;
    wb_pre_bad    = s5_pre_bad;
    wb_qok        = 1'b0;
    wb_snap_ok    = s5_snap_ok;
    wb_phit       = 1'b0;
    wr_z_en    = 1'b0; wr_zr = s5_zr_next; wr_zi = s5_zi_next;
    wr_c_en    = 1'b0; wr_cr = s5_ld_cr;   wr_crq = s5_ld_zr;   wr_ci = s5_ld_ci;
    wr_cisq_en = 1'b0; wr_cisq = s5_zi_sq_c;
    wr_snap_en = 1'b0; wr_snap = s6_snap_new;

    case (s5_state)
    S_LOAD: begin
        // Load the pixel: z = (cr - 1/4, ci) for the q pass.  q is only
        // meaningful if both operands fit the 27-bit high limb; otherwise
        // every precheck is skipped (the point is far outside).
        wb_act     = 1'b1;
        wb_state   = S_PREP_Q;
        wb_iter    = 12'd0;
        wb_pre_bad = s5_ld_bad;
        wb_zbig    = s5_ld_bad;
        wb_qok     = 1'b0;
        wb_snap_ok = 1'b0;
        wr_z_en    = 1'b1; wr_zr = s5_ld_zr; wr_zi = s5_ld_ci;
        wr_c_en    = 1'b1;
    end
    S_PREP_Q: begin
        // q = (cr-1/4)^2 + ci^2 (= mag_sq); next pass multiplies q*(q+x).
        wb_act     = 1'b1;
        wb_state   = S_CARDIOID;
        wb_qok     = !s5_pre_bad && s5_q_small;
        wb_zbig    = s5_pre_bad || !s5_q_small;
        wr_z_en    = 1'b1; wr_zr = s5_q; wr_zi = s5_q_plus_x;
        wr_cisq_en = 1'b1;              // ci^2, clamped (cardioid rhs = ci^2/4)
    end
    S_CARDIOID: begin
        wb_act = 1'b1;
        if (s5_cardioid) begin
            wb_state = S_DONE; wb_done = 1'b1; wb_iter_count = max_iter_q;
        end else begin
            wb_state = S_BULB;
            wb_zbig  = s5_bulb_bad;
            wr_z_en  = 1'b1; wr_zr = s5_c_plus1; wr_zi = s5_c_imag;
        end
    end
    S_BULB: begin
        wb_act = 1'b1;
        if (s5_bulb) begin
            wb_state = S_DONE; wb_done = 1'b1; wb_iter_count = max_iter_q;
        end else if (p3_precheck_enable) begin
            // A3: next pass computes (cr - P3_CX)^2 + (|ci| - P3_CY)^2.
            wb_state = S_BULB3;
            wb_zbig  = s5_p3_bad;
            wr_z_en  = 1'b1; wr_zr = s5_p3_zr; wr_zi = s5_p3_zi;
        end else begin
            wb_state = S_ITER;
            wb_iter  = 12'd0;
            wr_z_en  = 1'b1; wr_zr = {WIDTH{1'b0}}; wr_zi = {WIDTH{1'b0}};
        end
    end
    S_BULB3: begin
        wb_act = 1'b1;
        if (s5_p3) begin
            wb_state = S_DONE; wb_done = 1'b1; wb_iter_count = max_iter_q;
        end else begin
            wb_state = S_ITER;
            wb_iter  = 12'd0;
            wr_z_en  = 1'b1; wr_zr = {WIDTH{1'b0}}; wr_zi = {WIDTH{1'b0}};
        end
    end
    S_ITER: begin
        wb_act = 1'b1;
        if (s5_escape || s5_limit) begin
            wb_state = S_DONE; wb_done = 1'b1;
            wb_escaped = s5_escape; wb_iter_count = s5_iter;
        end else if (s5_phit) begin
            // P2: the orbit revisited the Brent snapshot exactly — periodic,
            // therefore interior (same classification as the prechecks).
            wb_state = S_DONE; wb_done = 1'b1; wb_iter_count = max_iter_q;
        end else begin
            wb_state = S_ITER;
            wb_iter  = s5_iter_inc;
            wb_zbig  = s6_next_bad;
            wr_z_en  = 1'b1;            // wr_zr/zi default to z_next
            if (s5_snap_sched) begin
                wr_snap_en = 1'b1;
                wb_snap_ok = 1'b1;
            end
            // Periodicity flag for the NEXT pass: the z being written equals
            // the snapshot.  A snapshot taken this pass would match itself,
            // so it is excluded (the old design's ctx_snap_new suppression).
            wb_phit = periodicity_enable & s5_snap_ok & ~s5_snap_sched &
                      (s5_snap == s6_snap_new);
        end
    end
    default: ;   // S_IDLE, S_DONE: nothing in flight for this slot
    endcase
end

// ============================================================
// S7: registered flag decision -> per-context flag registers
// ============================================================
reg        wb7_act;
reg [2:0]  wb7_state;
reg        wb7_done, wb7_escaped;
reg [11:0] wb7_iter_count, wb7_iter;
reg        wb7_zbig, wb7_pre_bad, wb7_qok, wb7_snap_ok, wb7_phit;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb7_act <= 1'b0;
    else        wb7_act <= wb_act;
end
always @(posedge clk) begin
    wb7_state      <= wb_state;
    wb7_done       <= wb_done;
    wb7_escaped    <= wb_escaped;
    wb7_iter_count <= wb_iter_count;
    wb7_iter       <= wb_iter;
    wb7_zbig       <= wb_zbig;
    wb7_pre_bad    <= wb_pre_bad;
    wb7_qok        <= wb_qok;
    wb7_snap_ok    <= wb_snap_ok;
    wb7_phit       <= wb_phit;
end

// ---- Per-context flag registers ----
// The start pulse (any cycle) moves IDLE/DONE -> LOAD; the shared
// writeback updates the slot's flags when its state is active.  The two
// never collide: the writeback acts only on active states and the pulse
// only on IDLE/DONE, and a slot's state changes only through one of them.
// The flags land one cycle after the RAM writeback (phase_d7); the next
// read of this slot's flags is its S4 read, five cycles later.
genvar k;
generate
for (k = 0; k < NCTX; k = k + 1) begin : ctx_sm
    localparam [2:0] CTX_K = k[2:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_state[k]      <= S_IDLE;
            ctx_done[k]       <= 1'b0;
            ctx_escaped[k]    <= 1'b0;
            ctx_iter_count[k] <= 12'd0;
            ctx_iter[k]       <= 12'd0;
            ctx_zbig[k]       <= 1'b0;
            ctx_pre_bad[k]    <= 1'b0;
            ctx_qok[k]        <= 1'b0;
            ctx_snap_ok[k]    <= 1'b0;
            ctx_phit[k]       <= 1'b0;
        end else if (wb7_act && (phase_d7 == CTX_K)) begin
            ctx_state[k]      <= wb7_state;
            ctx_done[k]       <= wb7_done;
            ctx_escaped[k]    <= wb7_escaped;
            ctx_iter_count[k] <= wb7_iter_count;
            ctx_iter[k]       <= wb7_iter;
            ctx_zbig[k]       <= wb7_zbig;
            ctx_pre_bad[k]    <= wb7_pre_bad;
            ctx_qok[k]        <= wb7_qok;
            ctx_snap_ok[k]    <= wb7_snap_ok;
            ctx_phit[k]       <= wb7_phit;
        end else if (start[k] && (ctx_state[k] == S_IDLE || ctx_state[k] == S_DONE)) begin
            ctx_state[k]      <= S_LOAD;
            ctx_done[k]       <= 1'b0;
            ctx_escaped[k]    <= 1'b0;
            ctx_iter_count[k] <= 12'd0;
        end
    end
end
endgenerate

endmodule
