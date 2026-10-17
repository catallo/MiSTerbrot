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
//   cr/ci (clk_sys → clk_iter): written into the quad's dual-clock slot RAM
//               at dispatch; iter_quad reads the slot after the synchronized
//               start fires (>= 3 clk_iter edges later, 4-FF chain)
//   iter_count, escaped buses (clk_iter → clk_sys): static when done fires,
//               sampled by collect logic on synchronized done pulse
//   max_iter: 2-FF synchronizer (rare changes;
//               settling glitches harmless — view_changed forces a clean restart)
//
// Round-robin dispatch and collection in clk_sys. 12-bit iter count. 16 slots.
//============================================================================

module pixel_pipeline #(
    parameter N_ITERATORS = 96,  // quads x 8 contexts/quad (fractal_top passes 96 = 12 quads since 2026-10-17)
    parameter WIDTH       = 64,
    parameter FRAC_BITS   = 56,
    parameter RID_W       = 2    // region_id tag width (Mariani-Silver v2)
)(
    input  wire                    clk,        // clk_sys (50 MHz)
    input  wire                    clk_iter,   // clk_iter (100 MHz)
    input  wire                    rst_n,
    output wire                    frame_done,
    input  wire [11:0]             max_iter,
    // A3 per-frame enable — passthrough to all iter_quad instances.
    // CDC handled the same way as max_iter (2-FF sync).
    input  wire                    p3_precheck_enable,
    // P2 (Brent periodicity) enable — same passthrough + CDC treatment.
    input  wire                    periodicity_enable,

    // External coordinate source (coord_generator or region_manager).
    // coord_region_id is the Mariani-Silver-v2 tag; with v1 / coord_generator
    // it can be tied to 0.
    input  wire                    coord_valid,
    output wire                    coord_ready,
    input  wire [10:0]             coord_px,
    input  wire [10:0]             coord_py,
    input  wire signed [WIDTH-1:0] coord_cr,
    input  wire signed [WIDTH-1:0] coord_ci,
    input  wire [RID_W-1:0]        coord_region_id,
    input  wire                    coord_frame_done,

    output reg                     result_valid,
    output reg  [10:0]             result_x,
    output reg  [10:0]             result_y,
    output reg  [11:0]             result_iter,
    output reg                     result_escaped,
    output reg  [RID_W-1:0]        result_region_id
);

localparam IDX_W = $clog2(N_ITERATORS);

// =====================================================================
// CDC: control inputs (clk_sys → clk_iter), 2-FF synchronizer.
// Slow-changing on clk_sys; iter_quad samples them at start; brief glitch
// during a transition is harmless because input_handler triggers a frame
// restart (start_frame) that clears all in-flight contexts.
// =====================================================================
reg [11:0] max_iter_iter_meta, max_iter_iter;
reg        p3_precheck_enable_meta, p3_precheck_enable_iter;
reg        periodicity_enable_meta, periodicity_enable_iter;

always @(posedge clk_iter or negedge rst_n) begin
    if (!rst_n) begin
        max_iter_iter_meta      <= 12'd0;
        max_iter_iter           <= 12'd0;
        p3_precheck_enable_meta <= 1'b0;
        p3_precheck_enable_iter <= 1'b0;
        periodicity_enable_meta <= 1'b0;
        periodicity_enable_iter <= 1'b0;
    end else begin
        max_iter_iter_meta      <= max_iter;
        max_iter_iter           <= max_iter_iter_meta;
        p3_precheck_enable_meta <= p3_precheck_enable;
        p3_precheck_enable_iter <= p3_precheck_enable_meta;
        periodicity_enable_meta <= periodicity_enable;
        periodicity_enable_iter <= periodicity_enable_meta;
    end
end

// =====================================================================
// Coordinate source is external (coord_generator or region_manager,
// muxed at the top level). coord_ready is the dispatcher's "ready" line.
// =====================================================================

// =====================================================================
// Per-slot state (clk_sys)
// =====================================================================
reg                     iter_busy    [0:N_ITERATORS-1];
reg                     iter_start_q [0:N_ITERATORS-1]; // toggle in clk_sys
// Per-slot pixel tag {px, py, rid}: written at dispatch, read once at
// collect.  An MLAB with an asynchronous read replaces the per-slot
// register file and its N:1 collect mux (2026-10-16).  Dispatch writes a
// free slot and collect reads a busy one, so the two never touch the
// same word in one cycle: no read-during-write bypass needed.
localparam TAG_W = 11 + 11 + RID_W;
(* ramstyle = "MLAB, no_rw_check" *) reg [TAG_W-1:0] mem_tag [0:N_ITERATORS-1];
// The coordinates themselves live in each quad's slot RAM (iter_quad
// mem_ld), written through the quad's clk_sys port at dispatch.

// =====================================================================
// CDC: per-slot start (clk_sys → clk_iter) via toggle synchronizer
// =====================================================================
// 4-FF chain (2026-10-16, was 3): the slot's coordinates are written into
// the quad's dual-clock RAM on the same clk_sys edge as the toggle, and a
// mixed-port read must not fall within one write-clock period (20 ns) of
// the write.  Three clk_iter edges (>= 23 ns at 130 MHz) before the pulse
// cover that; the extra 7.7 ns of dispatch latency is <1% of a pixel.
reg [3:0] iter_start_sync [0:N_ITERATORS-1]; // 4-FF chain in clk_iter
wire      iter_start_pulse_iter [0:N_ITERATORS-1]; // 1-cycle pulse on clk_iter

genvar gs;
generate
    for (gs = 0; gs < N_ITERATORS; gs = gs + 1) begin : gen_start_sync
        always @(posedge clk_iter or negedge rst_n) begin
            if (!rst_n) iter_start_sync[gs] <= 4'b0;
            else        iter_start_sync[gs] <= {iter_start_sync[gs][2:0], iter_start_q[gs]};
        end
        assign iter_start_pulse_iter[gs] = iter_start_sync[gs][3] ^ iter_start_sync[gs][2];
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
// iter_quad instances (clk_iter), 8 contexts each (2026-10-14 rewrite:
// flat per-quad slot buses; N_ITERATORS must be a multiple of 8)
// =====================================================================
genvar gq, gc;
generate
    for (gq = 0; gq < N_ITERATORS/8; gq = gq + 1) begin : gen_quad
        wire [7:0]         q_start;
        wire [7:0]         q_done, q_escaped;
        wire [8*12-1:0]    q_iter_count;
        // Slot coordinate write port: this quad owns slots 8*gq .. 8*gq+7.
        wire               q_ld_we = coord_valid && coord_ready &&
                                     ((dispatch_slot >> 3) == gq);
        for (gc = 0; gc < 8; gc = gc + 1) begin : gen_slot
            assign q_start[gc]                 = iter_start_pulse_iter[8*gq+gc];
            assign iter_done_level[8*gq+gc]    = q_done[gc];
            assign iter_escaped_level[8*gq+gc] = q_escaped[gc];
            assign iter_count_level[8*gq+gc]   = q_iter_count[gc*12 +: 12];
        end
        iter_quad #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_quad (
            .clk(clk_iter), .rst_n(rst_n),
            .max_iter(max_iter_iter),
            .p3_precheck_enable(p3_precheck_enable_iter),
            .periodicity_enable(periodicity_enable_iter),
            .clk_wr(clk),
            .ld_we(q_ld_we),
            .ld_wa(dispatch_slot[2:0]),
            .ld_cr(coord_cr),
            .ld_ci(coord_ci),
            .start(q_start),
            .done(q_done),
            .iter_count_flat(q_iter_count),
            .escaped(q_escaped)
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
// Per-slot done_pending flag latches the synchronized done pulse; the
// collect logic consumes ONE pending slot per clk_sys cycle, chosen by a
// first-pending priority encoder (2026-10-12).  The previous round-robin
// walk (collect_idx advancing every cycle regardless of pending state)
// left a finished pixel's iterator blocked for 12 cycles on average and
// 24 worst case before it could be re-dispatched — ~0.3 us of dead time
// per pixel per slot on top of the two clock crossings, i.e. ~10% of
// the per-pixel budget on 30 fps views (measured in sim/pixel_pipeline).
//
// Dispatch targets the FIRST FREE slot (priority encoder over the busy
// vector).  The previous in-order ring (`dispatch_idx` advancing only on
// dispatch) meant the in-flight set was always a contiguous window of
// <=24 consecutive scan pixels: one slow pixel stalled the window and
// idled the other 23 iterators once their pixels finished — severe
// head-of-line blocking on scenes with interleaved fast/slow pixels
// (dendrites, seahorse valley).  Free-slot dispatch lets fast slots
// recycle immediately regardless of the stragglers.
// =====================================================================
reg             iter_done_pending [0:N_ITERATORS-1];

// First-free priority encoder over the (already flattened) busy vector.
reg [IDX_W-1:0] dispatch_slot;
integer pe;
always @(*) begin
    dispatch_slot = {IDX_W{1'b0}};
    for (pe = N_ITERATORS - 1; pe >= 0; pe = pe - 1)
        if (!busy_flat[pe]) dispatch_slot = pe[IDX_W-1:0];
end
assign coord_ready = ~&busy_flat;

// First-pending priority encoder over (done_pending & busy).
reg [N_ITERATORS-1:0] pend_flat;
reg [IDX_W-1:0]       collect_slot;
reg                   collect_any;
integer pc;
always @(*) begin
    for (pc = 0; pc < N_ITERATORS; pc = pc + 1)
        pend_flat[pc] = iter_done_pending[pc] & iter_busy[pc];
    collect_slot = {IDX_W{1'b0}};
    collect_any  = 1'b0;
    for (pc = N_ITERATORS - 1; pc >= 0; pc = pc - 1)
        if (pend_flat[pc]) begin collect_slot = pc[IDX_W-1:0]; collect_any = 1'b1; end
end

// Pixel tag store (no reset: a RAM; a slot's word is written before it is
// ever read).
always @(posedge clk)
    if (coord_valid && coord_ready)
        mem_tag[dispatch_slot] <= {coord_px, coord_py, coord_region_id};

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_valid <= 1'b0;
        result_x <= 11'd0; result_y <= 11'd0;
        result_iter <= 12'd0; result_escaped <= 1'b0;
        result_region_id <= {RID_W{1'b0}};
        for (i = 0; i < N_ITERATORS; i = i + 1) begin
            iter_busy[i]         <= 1'b0;
            iter_start_q[i]      <= 1'b0;
            iter_done_pending[i] <= 1'b0;
        end
    end else begin
        result_valid <= 1'b0;

        // ---- Latch synchronized done pulses into per-slot pending flags ----
        for (i = 0; i < N_ITERATORS; i = i + 1) begin
            if (iter_done_pulse_sys[i])
                iter_done_pending[i] <= 1'b1;
        end

        // ---- Dispatch (first free slot) ----
        if (coord_valid && coord_ready) begin
            // Toggle the slot's start bit; CDC pulse-syncs into clk_iter.
            // The coordinates go into the quad's slot RAM (q_ld_we above)
            // and the pixel tag into mem_tag on this same edge.
            iter_start_q[dispatch_slot] <= ~iter_start_q[dispatch_slot];
            iter_busy[dispatch_slot]    <= 1'b1;
        end

        // ---- Collect (first pending slot) ----
        // iter_count/escaped buses are stable in clk_iter from done assertion
        // until next dispatch — safe to sample combinationally here.  The
        // freed slot is visible to the dispatch encoder next cycle.
        if (collect_any) begin
            result_valid                   <= 1'b1;
            {result_x, result_y, result_region_id} <= mem_tag[collect_slot];
            result_iter                    <= iter_count_level[collect_slot];
            result_escaped                 <= iter_escaped_level[collect_slot];
            iter_busy[collect_slot]        <= 1'b0;
            iter_done_pending[collect_slot]<= 1'b0;
        end
    end
end

endmodule
