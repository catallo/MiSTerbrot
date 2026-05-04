//============================================================================
// Pixel Pipeline — 16 iterators via 4 time-shared DSP quads
//
// Dual-clock design:
//   clk      (clk_sys, 50 MHz):   coord_generator, dispatch FSM, collect FSM,
//                                  output registers, per-iterator state regs
//   clk_iter (75 MHz):             iter_quad instances (math)
//
// CDC at iter_quad boundary:
//   start_x[i]: pulse on clk_sys → toggle synchronizer → 1-cycle pulse on clk_iter
//   done_x[i] : edge-detected pulse on clk_iter → toggle synchronizer →
//               1-cycle pulse on clk_sys
//   cr/ci buses (clk_sys → clk_iter): static for the duration of the iteration,
//               sampled by iter_quad when synchronized start fires (no sync needed)
//   iter_count, escaped buses (clk_iter → clk_sys): static when done fires,
//               sampled by collect logic on synchronized done pulse
//   max_iter, fractal_type, julia_*: 2-FF synchronizers (rare changes;
//               settling glitches harmless — view_changed forces a clean restart)
//
// Round-robin dispatch and collection in clk_sys. 12-bit iter count. 16 slots.
//============================================================================

module pixel_pipeline #(
    parameter N_ITERATORS = 16,
    parameter H_RES       = 320,
    parameter V_RES       = 240,
    parameter WIDTH       = 64,
    parameter FRAC_BITS   = 56
)(
    input  wire                    clk,        // clk_sys (50 MHz)
    input  wire                    clk_iter,   // clk_iter (75 MHz)
    input  wire                    rst_n,
    input  wire                    start_frame,
    output wire                    frame_done,
    input  wire [1:0]              fractal_type,
    input  wire signed [WIDTH-1:0] julia_cr,
    input  wire signed [WIDTH-1:0] julia_ci,
    input  wire [11:0]             max_iter,
    input  wire signed [WIDTH-1:0] center_x,
    input  wire signed [WIDTH-1:0] center_y,
    input  wire signed [WIDTH-1:0] step,
    output reg                     result_valid,
    output reg  [10:0]             result_x,
    output reg  [9:0]              result_y,
    output reg  [11:0]             result_iter,
    output reg                     result_escaped
);

localparam IDX_W = $clog2(N_ITERATORS);

// =====================================================================
// CDC: control inputs (clk_sys → clk_iter), 2-FF synchronizer.
// Slow-changing on clk_sys; iter_quad samples them at start; brief glitch
// during a transition is harmless because input_handler triggers a frame
// restart (start_frame) that clears all in-flight contexts.
// =====================================================================
reg [1:0] fractal_type_iter_meta, fractal_type_iter;
reg signed [WIDTH-1:0] julia_cr_iter_meta, julia_cr_iter;
reg signed [WIDTH-1:0] julia_ci_iter_meta, julia_ci_iter;
reg [11:0] max_iter_iter_meta, max_iter_iter;

always @(posedge clk_iter or negedge rst_n) begin
    if (!rst_n) begin
        fractal_type_iter_meta <= 2'd0;
        fractal_type_iter      <= 2'd0;
        julia_cr_iter_meta     <= {WIDTH{1'b0}};
        julia_cr_iter          <= {WIDTH{1'b0}};
        julia_ci_iter_meta     <= {WIDTH{1'b0}};
        julia_ci_iter          <= {WIDTH{1'b0}};
        max_iter_iter_meta     <= 12'd0;
        max_iter_iter          <= 12'd0;
    end else begin
        fractal_type_iter_meta <= fractal_type;
        fractal_type_iter      <= fractal_type_iter_meta;
        julia_cr_iter_meta     <= julia_cr;
        julia_cr_iter          <= julia_cr_iter_meta;
        julia_ci_iter_meta     <= julia_ci;
        julia_ci_iter          <= julia_ci_iter_meta;
        max_iter_iter_meta     <= max_iter;
        max_iter_iter          <= max_iter_iter_meta;
    end
end

// =====================================================================
// Coordinate generator (clk_sys)
// =====================================================================
wire                    coord_valid, coord_ready;
wire [10:0]             coord_px;
wire [9:0]              coord_py;
wire signed [WIDTH-1:0] coord_cr, coord_ci;
wire                    coord_frame_done;

coord_generator #(
    .H_RES(H_RES), .V_RES(V_RES), .WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)
) u_coord_gen (
    .clk(clk), .rst_n(rst_n), .start_frame(start_frame),
    .center_x(center_x), .center_y(center_y), .step(step),
    .ready(coord_ready), .valid(coord_valid),
    .pixel_x(coord_px), .pixel_y(coord_py),
    .cr(coord_cr), .ci(coord_ci), .frame_done(coord_frame_done)
);

// =====================================================================
// Per-slot state (clk_sys)
// =====================================================================
reg                     iter_busy    [0:N_ITERATORS-1];
reg                     iter_start_q [0:N_ITERATORS-1]; // toggle in clk_sys
reg  [10:0]             iter_px      [0:N_ITERATORS-1];
reg  [9:0]              iter_py      [0:N_ITERATORS-1];
reg  signed [WIDTH-1:0] iter_cr      [0:N_ITERATORS-1];
reg  signed [WIDTH-1:0] iter_ci      [0:N_ITERATORS-1];

// =====================================================================
// CDC: per-slot start (clk_sys → clk_iter) via toggle synchronizer
// =====================================================================
reg [2:0] iter_start_sync [0:N_ITERATORS-1]; // 3-FF chain in clk_iter
wire      iter_start_pulse_iter [0:N_ITERATORS-1]; // 1-cycle pulse on clk_iter

genvar gs;
generate
    for (gs = 0; gs < N_ITERATORS; gs = gs + 1) begin : gen_start_sync
        always @(posedge clk_iter or negedge rst_n) begin
            if (!rst_n) iter_start_sync[gs] <= 3'b0;
            else        iter_start_sync[gs] <= {iter_start_sync[gs][1:0], iter_start_q[gs]};
        end
        assign iter_start_pulse_iter[gs] = iter_start_sync[gs][2] ^ iter_start_sync[gs][1];
    end
endgenerate

// =====================================================================
// Per-slot done (clk_iter → clk_sys)
//   1) iter_quad's done is a level (high in S_DONE state).
//   2) Edge-detect rising in clk_iter to make a 1-cycle pulse there.
//   3) Toggle on each pulse, sync to clk_sys, edge-detect → 1-cycle pulse.
// =====================================================================
wire                    iter_done_level [0:N_ITERATORS-1]; // from iter_quad (clk_iter)
wire [11:0]             iter_count_level [0:N_ITERATORS-1];
wire                    iter_escaped_level [0:N_ITERATORS-1];
wire signed [WIDTH-1:0] iter_mag_sq_level [0:N_ITERATORS-1];

reg                     iter_done_prev_iter [0:N_ITERATORS-1]; // edge detect (clk_iter)
reg                     iter_done_toggle    [0:N_ITERATORS-1]; // toggle in clk_iter
reg [2:0]               iter_done_sync      [0:N_ITERATORS-1]; // 3-FF chain in clk_sys
wire                    iter_done_pulse_sys [0:N_ITERATORS-1]; // 1-cycle pulse in clk_sys

genvar gd;
generate
    for (gd = 0; gd < N_ITERATORS; gd = gd + 1) begin : gen_done_sync
        // Edge-detect done in clk_iter
        always @(posedge clk_iter or negedge rst_n) begin
            if (!rst_n) begin
                iter_done_prev_iter[gd] <= 1'b0;
                iter_done_toggle[gd]    <= 1'b0;
            end else begin
                iter_done_prev_iter[gd] <= iter_done_level[gd];
                if (iter_done_level[gd] & ~iter_done_prev_iter[gd])
                    iter_done_toggle[gd] <= ~iter_done_toggle[gd];
            end
        end
        // Sync toggle into clk_sys
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) iter_done_sync[gd] <= 3'b0;
            else        iter_done_sync[gd] <= {iter_done_sync[gd][1:0], iter_done_toggle[gd]};
        end
        assign iter_done_pulse_sys[gd] = iter_done_sync[gd][2] ^ iter_done_sync[gd][1];
    end
endgenerate

// =====================================================================
// iter_quad instances (clk_iter)
// =====================================================================
genvar gq;
generate
    for (gq = 0; gq < N_ITERATORS/4; gq = gq + 1) begin : gen_quad
        iter_quad #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_quad (
            .clk(clk_iter), .rst_n(rst_n),
            .fractal_type(fractal_type_iter),
            .julia_cr(julia_cr_iter),
            .julia_ci(julia_ci_iter),
            .max_iter(max_iter_iter),

            .start_a       (iter_start_pulse_iter [4*gq+0]),
            .cr_a          (iter_cr               [4*gq+0]),
            .ci_a          (iter_ci               [4*gq+0]),
            .done_a        (iter_done_level       [4*gq+0]),
            .iter_count_a  (iter_count_level      [4*gq+0]),
            .escaped_a     (iter_escaped_level    [4*gq+0]),
            .final_mag_sq_a(iter_mag_sq_level     [4*gq+0]),

            .start_b       (iter_start_pulse_iter [4*gq+1]),
            .cr_b          (iter_cr               [4*gq+1]),
            .ci_b          (iter_ci               [4*gq+1]),
            .done_b        (iter_done_level       [4*gq+1]),
            .iter_count_b  (iter_count_level      [4*gq+1]),
            .escaped_b     (iter_escaped_level    [4*gq+1]),
            .final_mag_sq_b(iter_mag_sq_level     [4*gq+1]),

            .start_c       (iter_start_pulse_iter [4*gq+2]),
            .cr_c          (iter_cr               [4*gq+2]),
            .ci_c          (iter_ci               [4*gq+2]),
            .done_c        (iter_done_level       [4*gq+2]),
            .iter_count_c  (iter_count_level      [4*gq+2]),
            .escaped_c     (iter_escaped_level    [4*gq+2]),
            .final_mag_sq_c(iter_mag_sq_level     [4*gq+2]),

            .start_d       (iter_start_pulse_iter [4*gq+3]),
            .cr_d          (iter_cr               [4*gq+3]),
            .ci_d          (iter_ci               [4*gq+3]),
            .done_d        (iter_done_level       [4*gq+3]),
            .iter_count_d  (iter_count_level      [4*gq+3]),
            .escaped_d     (iter_escaped_level    [4*gq+3]),
            .final_mag_sq_d(iter_mag_sq_level     [4*gq+3])
        );
    end
endgenerate

// =====================================================================
// Frame-done logic (clk_sys)
// =====================================================================
wire any_busy;
reg [N_ITERATORS-1:0] busy_flat;
integer ib;
always @(*) begin
    busy_flat = {N_ITERATORS{1'b0}};
    for (ib = 0; ib < N_ITERATORS; ib = ib + 1)
        busy_flat[ib] = iter_busy[ib];
end
assign any_busy   = |busy_flat;
assign frame_done = coord_frame_done & ~any_busy;

// =====================================================================
// Dispatch + collect FSMs (clk_sys)
//
// Per-slot done_pending flag latches the synchronized done pulse, so
// the collect FSM can pick it up whenever collect_idx wraps around to it.
// Without this, pulses arriving while collect_idx is elsewhere would be lost.
// =====================================================================
reg [IDX_W-1:0] dispatch_idx, collect_idx;
reg             iter_done_pending [0:N_ITERATORS-1];
wire dispatch_slot_free = !iter_busy[dispatch_idx];
assign coord_ready = dispatch_slot_free;

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dispatch_idx <= {IDX_W{1'b0}};
        collect_idx  <= {IDX_W{1'b0}};
        result_valid <= 1'b0;
        result_x <= 11'd0; result_y <= 10'd0;
        result_iter <= 12'd0; result_escaped <= 1'b0;
        for (i = 0; i < N_ITERATORS; i = i + 1) begin
            iter_busy[i]         <= 1'b0;
            iter_start_q[i]      <= 1'b0;
            iter_done_pending[i] <= 1'b0;
            iter_px[i]           <= 11'd0;
            iter_py[i]           <= 10'd0;
            iter_cr[i]           <= {WIDTH{1'b0}};
            iter_ci[i]           <= {WIDTH{1'b0}};
        end
    end else begin
        result_valid <= 1'b0;

        // ---- Latch synchronized done pulses into per-slot pending flags ----
        for (i = 0; i < N_ITERATORS; i = i + 1) begin
            if (iter_done_pulse_sys[i])
                iter_done_pending[i] <= 1'b1;
        end

        // ---- Dispatch ----
        if (coord_valid && coord_ready) begin
            // Toggle the slot's start bit; CDC pulse-syncs into clk_iter.
            iter_start_q[dispatch_idx] <= ~iter_start_q[dispatch_idx];
            iter_busy[dispatch_idx]    <= 1'b1;
            iter_px[dispatch_idx]      <= coord_px;
            iter_py[dispatch_idx]      <= coord_py;
            iter_cr[dispatch_idx]      <= coord_cr;
            iter_ci[dispatch_idx]      <= coord_ci;
            dispatch_idx <= (dispatch_idx == N_ITERATORS[IDX_W-1:0] - 1'b1)
                            ? {IDX_W{1'b0}} : dispatch_idx + 1'b1;
        end

        // ---- Collect ----
        // Walk collect_idx round-robin; consume a pending flag whenever found.
        // iter_count/escaped buses are stable in clk_iter from done assertion
        // until next dispatch — safe to sample combinationally here.
        if (iter_done_pending[collect_idx] && iter_busy[collect_idx]) begin
            result_valid                  <= 1'b1;
            result_x                      <= iter_px[collect_idx];
            result_y                      <= iter_py[collect_idx];
            result_iter                   <= iter_count_level[collect_idx];
            result_escaped                <= iter_escaped_level[collect_idx];
            iter_busy[collect_idx]        <= 1'b0;
            iter_done_pending[collect_idx]<= 1'b0;
        end
        collect_idx <= (collect_idx == N_ITERATORS[IDX_W-1:0] - 1'b1)
                       ? {IDX_W{1'b0}} : collect_idx + 1'b1;
    end
end

endmodule
