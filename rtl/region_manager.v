//============================================================================
// region_manager.v — Mariani-Silver with N-slot region pipelining (v2)
//
// Up to N_SLOTS regions in flight concurrently. Each pixel dispatched
// carries a region_id tag (RID_W bits); when iter results return, the
// result_region_id routes the result to the right slot's accumulators.
// This eliminates the v1 iterator-starvation problem where the pipeline
// drained between regions while we waited in S_BD_WAIT/S_DECIDE.
//
// Slot states:
//   IDLE       - empty; master assigns a region from the stack
//   PREP       - 1-cycle setup (compute bounds, pick BD vs FULL path)
//   BD_TOP/RIGHT/BOTTOM/LEFT - boundary-walk dispatch phases
//   FULL_OUT   - small-region full dispatch (every pixel)
//   WAIT_BD    - boundary fully dispatched; wait for results to drain
//   WAIT_FULL  - full-dispatch done; wait for results, then back to IDLE
//   DECIDE     - 1-cycle decision: fill or split
//   FILL       - one pixel per cycle of fill (arbiter picks one FILL slot)
//   SPLIT      - 1-cycle: push 4 children, then IDLE
//
// Shared resources (one per cycle):
//   - coord output (dispatch arbiter picks one slot in a DISPATCH state)
//   - fill output  (fill arbiter picks one slot in SL_FILL state)
//   - stack push   (split arbiter picks one slot in SL_SPLIT)
//   - stack pop    (idle arbiter picks one SL_IDLE slot to populate)
//
// Coord tables (cr_per_x, ci_per_y) and the region stack are identical
// to v1 — see Quartus fitter report; both tables infer cleanly as M10K.
//============================================================================

module region_manager #(
    parameter WIDTH        = 64,
    parameter FRAC_BITS    = 56,
    parameter H_RES_MAX    = 640,
    parameter V_RES        = 240,
    parameter STACK_DEPTH  = 64,
    parameter N_SLOTS      = 4,
    parameter RID_W        = 2  // ceil(log2(N_SLOTS))
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    mode_640,

    // Frame control
    input  wire                    start_frame,
    output reg                     frame_done,
    input  wire [7:0]              min_region_dim,

    // Coord parameters (latched at start_frame)
    input  wire signed [WIDTH-1:0] center_x,
    input  wire signed [WIDTH-1:0] center_y,
    input  wire signed [WIDTH-1:0] step,
    input  wire [11:0]             max_iter,

    // Coord output to pixel_pipeline (combinational from active slot's walk)
    input  wire                    coord_ready,
    output wire                    coord_valid,
    output wire [10:0]             coord_px,
    output wire [9:0]              coord_py,
    output wire signed [WIDTH-1:0] coord_cr,
    output wire signed [WIDTH-1:0] coord_ci,
    output wire [RID_W-1:0]        coord_region_id,

    // Iter result back from pixel_pipeline (tagged with region_id)
    input  wire                    result_valid,
    input  wire [10:0]             result_x,
    input  wire [9:0]              result_y,
    input  wire [11:0]             result_iter,
    input  wire                    result_escaped,
    input  wire [RID_W-1:0]        result_region_id,

    // Fill bypass directly to framebuffer write mux
    output wire                    fill_valid,
    output wire [10:0]             fill_x,
    output wire [9:0]              fill_y,
    output wire [11:0]             fill_iter,
    output wire                    fill_escaped
);

// ---- Per-mode resolution ----
wire [10:0] H_PIXELS = mode_640 ? 11'd640 : 11'd320;

wire signed [WIDTH-1:0] step_x       = mode_640 ? (step >>> 1) : step;
wire signed [WIDTH-1:0] half_h_off   = (step <<< 7) + (step <<< 5);
wire signed [WIDTH-1:0] half_v_off   = (step <<< 7) - (step <<< 3);
wire signed [WIDTH-1:0] cr_first     = center_x - half_h_off;
wire signed [WIDTH-1:0] ci_first     = center_y - half_v_off;

// ---- Coordinate lookup tables (M10K) ----
// Force Quartus to use M10K — without this attribute the v2 design's
// muxed read address (cr_per_x[slot_walk_px[disp_slot]]) defeats automatic
// inference and Quartus falls back to ~56K registers (31K extra ALMs).
(* ramstyle = "M10K" *) reg signed [WIDTH-1:0] cr_per_x [0:H_RES_MAX-1];
(* ramstyle = "M10K" *) reg signed [WIDTH-1:0] ci_per_y [0:V_RES-1];

reg [10:0]             init_px;
reg [9:0]              init_py;
reg signed [WIDTH-1:0] init_cr_accum;
reg signed [WIDTH-1:0] init_ci_accum;

// ---- Region stack (LIFO) ----
reg [9:0]  stack_x0 [0:STACK_DEPTH-1];
reg [9:0]  stack_y0 [0:STACK_DEPTH-1];
reg [10:0] stack_w  [0:STACK_DEPTH-1];
reg [9:0]  stack_h  [0:STACK_DEPTH-1];
localparam SP_W = $clog2(STACK_DEPTH+1);
reg [SP_W-1:0] stack_top;

// ---- Slot states ----
localparam [3:0]
    SL_IDLE      = 4'd0,
    SL_PREP      = 4'd1,
    SL_BD_TOP    = 4'd2,
    SL_BD_RIGHT  = 4'd3,
    SL_BD_BOT    = 4'd4,
    SL_BD_LEFT   = 4'd5,
    SL_FULL_OUT  = 4'd6,
    SL_WAIT_BD   = 4'd7,
    SL_WAIT_FULL = 4'd8,
    SL_DECIDE    = 4'd9,
    SL_FILL      = 4'd10,
    SL_SPLIT     = 4'd11;

// ---- Per-slot state arrays ----
reg [3:0]  slot_state    [0:N_SLOTS-1];
reg [10:0] slot_x0       [0:N_SLOTS-1];
reg [9:0]  slot_y0       [0:N_SLOTS-1];
reg [10:0] slot_w        [0:N_SLOTS-1];
reg [9:0]  slot_h        [0:N_SLOTS-1];
reg [10:0] slot_x_max    [0:N_SLOTS-1];
reg [9:0]  slot_y_max    [0:N_SLOTS-1];
reg [10:0] slot_walk_px  [0:N_SLOTS-1];
reg [9:0]  slot_walk_py  [0:N_SLOTS-1];
reg [16:0] slot_received [0:N_SLOTS-1];
reg [16:0] slot_expected [0:N_SLOTS-1];
reg [11:0] slot_min_iter [0:N_SLOTS-1];
reg [11:0] slot_max_iter [0:N_SLOTS-1];
reg        slot_first    [0:N_SLOTS-1];
reg        slot_unif_t   [0:N_SLOTS-1];
reg        slot_unif_f   [0:N_SLOTS-1];
reg [11:0] slot_fill_iter[0:N_SLOTS-1];
reg        slot_fill_esc [0:N_SLOTS-1];

// ---- Master state ----
localparam [1:0]
    M_IDLE        = 2'd0,
    M_INIT_TABLES = 2'd1,
    M_RUN         = 2'd2,
    M_DONE        = 2'd3;
reg [1:0] master_state;

// ===========================================================================
// Combinational arbiters
// ===========================================================================

// Dispatch eligibility: any slot in a BD_* or FULL_OUT state.
wire [N_SLOTS-1:0] disp_eligible;
wire [N_SLOTS-1:0] fill_eligible;
wire [N_SLOTS-1:0] idle_eligible;
wire [N_SLOTS-1:0] split_eligible;

genvar gv;
generate
    for (gv = 0; gv < N_SLOTS; gv = gv + 1) begin : gen_eligibility
        assign disp_eligible[gv]  = (slot_state[gv] == SL_BD_TOP)   ||
                                    (slot_state[gv] == SL_BD_RIGHT) ||
                                    (slot_state[gv] == SL_BD_BOT)   ||
                                    (slot_state[gv] == SL_BD_LEFT)  ||
                                    (slot_state[gv] == SL_FULL_OUT);
        assign fill_eligible[gv]  = (slot_state[gv] == SL_FILL);
        assign idle_eligible[gv]  = (slot_state[gv] == SL_IDLE);
        assign split_eligible[gv] = (slot_state[gv] == SL_SPLIT);
    end
endgenerate

// Priority encoders (lowest index wins). N_SLOTS=4 hard-coded for clarity.
reg [RID_W-1:0] disp_slot;
reg             disp_has;
reg [RID_W-1:0] fill_slot;
reg             fill_has;
reg [RID_W-1:0] idle_slot;
reg             idle_has;
reg [RID_W-1:0] split_slot;
reg             split_has;

integer i;
always @(*) begin
    disp_slot  = {RID_W{1'b0}}; disp_has  = 1'b0;
    fill_slot  = {RID_W{1'b0}}; fill_has  = 1'b0;
    idle_slot  = {RID_W{1'b0}}; idle_has  = 1'b0;
    split_slot = {RID_W{1'b0}}; split_has = 1'b0;
    for (i = 0; i < N_SLOTS; i = i + 1) begin
        if (!disp_has  && disp_eligible[i])  begin disp_slot  = i[RID_W-1:0]; disp_has  = 1'b1; end
        if (!fill_has  && fill_eligible[i])  begin fill_slot  = i[RID_W-1:0]; fill_has  = 1'b1; end
        if (!idle_has  && idle_eligible[i])  begin idle_slot  = i[RID_W-1:0]; idle_has  = 1'b1; end
        if (!split_has && split_eligible[i]) begin split_slot = i[RID_W-1:0]; split_has = 1'b1; end
    end
end

// ===========================================================================
// Shared outputs (driven from arbiter picks)
// ===========================================================================
assign coord_valid     = disp_has  && (master_state == M_RUN);
assign coord_px        = slot_walk_px[disp_slot];
assign coord_py        = slot_walk_py[disp_slot];
assign coord_cr        = cr_per_x[slot_walk_px[disp_slot][9:0]];
assign coord_ci        = ci_per_y[slot_walk_py[disp_slot][7:0]];
assign coord_region_id = disp_slot;

assign fill_valid      = fill_has  && (master_state == M_RUN);
assign fill_x          = slot_walk_px[fill_slot];
assign fill_y          = slot_walk_py[fill_slot];
assign fill_iter       = slot_fill_iter[fill_slot];
assign fill_escaped    = slot_fill_esc[fill_slot];

// ===========================================================================
// Quadtree split halves (for the slot currently in SL_SPLIT)
// ===========================================================================
wire [10:0] split_w_a = (slot_w[split_slot] + 11'd1) >>> 1;
wire [10:0] split_w_b =  slot_w[split_slot] - split_w_a;
wire [9:0]  split_h_a = (slot_h[split_slot] + 10'd1) >>> 1;
wire [9:0]  split_h_b =  slot_h[split_slot] - split_h_a;

// ===========================================================================
// Combined stack_top delta — IDLE pop and SPLIT push can both fire in the
// same cycle. If both wrote stack_top from inside the per-slot for-loop,
// Verilog NBA "last assignment wins" would silently drop one update. We
// compute the net delta once and apply it outside the loop.
//
// Both push and pop reference the PRE-edge stack_top, so the push writes
// land at stack_top..stack_top+3 and the pop reads at stack_top-1 — disjoint
// indices, no array conflict. Only stack_top itself needs serialization.
// ===========================================================================
wire pop_will_happen  = (master_state == M_RUN) && idle_has &&
                        (stack_top != {SP_W{1'b0}});
wire push_will_happen = (master_state == M_RUN) && split_has;

// ===========================================================================
// Frame-done detection — parametric in N_SLOTS
// ===========================================================================
wire [N_SLOTS-1:0] slot_is_idle;
generate
    for (gv = 0; gv < N_SLOTS; gv = gv + 1) begin : gen_idle_check
        assign slot_is_idle[gv] = (slot_state[gv] == SL_IDLE);
    end
endgenerate
wire all_slots_idle = &slot_is_idle;
wire frame_complete = all_slots_idle && (stack_top == {SP_W{1'b0}});

// ===========================================================================
// Main always block
// ===========================================================================
integer s;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        master_state  <= M_IDLE;
        frame_done    <= 1'b0;
        stack_top     <= {SP_W{1'b0}};
        init_px       <= 11'd0;
        init_py       <= 10'd0;
        init_cr_accum <= {WIDTH{1'b0}};
        init_ci_accum <= {WIDTH{1'b0}};
        for (s = 0; s < N_SLOTS; s = s + 1) begin
            slot_state[s]      <= SL_IDLE;
            slot_x0[s]         <= 11'd0;
            slot_y0[s]         <= 10'd0;
            slot_w[s]          <= 11'd0;
            slot_h[s]          <= 10'd0;
            slot_x_max[s]      <= 11'd0;
            slot_y_max[s]      <= 10'd0;
            slot_walk_px[s]    <= 11'd0;
            slot_walk_py[s]    <= 10'd0;
            slot_received[s]   <= 17'd0;
            slot_expected[s]   <= 17'd0;
            slot_min_iter[s]   <= 12'd0;
            slot_max_iter[s]   <= 12'd0;
            slot_first[s]      <= 1'b0;
            slot_unif_t[s]     <= 1'b1;
            slot_unif_f[s]     <= 1'b1;
            slot_fill_iter[s]  <= 12'd0;
            slot_fill_esc[s]   <= 1'b0;
        end
    end else begin
        // -------- Master FSM (table init + frame_done) --------
        case (master_state)
        M_IDLE: begin
            frame_done <= 1'b0;
            if (start_frame) begin
                init_px       <= 11'd0;
                init_py       <= 10'd0;
                init_cr_accum <= cr_first;
                init_ci_accum <= ci_first;
                stack_top     <= {SP_W{1'b0}};
                master_state  <= M_INIT_TABLES;
            end
        end

        M_INIT_TABLES: begin
            if (init_px < H_PIXELS) begin
                cr_per_x[init_px[9:0]] <= init_cr_accum;
                init_px                <= init_px + 11'd1;
                init_cr_accum          <= init_cr_accum + step_x;
            end
            if (init_py < 10'd240) begin
                ci_per_y[init_py[7:0]] <= init_ci_accum;
                init_py                <= init_py + 10'd1;
                init_ci_accum          <= init_ci_accum + step;
            end
            if ((init_px >= H_PIXELS) && (init_py >= 10'd240)) begin
                // Push initial region (full screen)
                stack_x0[0]  <= 10'd0;
                stack_y0[0]  <= 10'd0;
                stack_w [0]  <= H_PIXELS;
                stack_h [0]  <= 10'd240;
                stack_top    <= {{(SP_W-1){1'b0}}, 1'b1};
                master_state <= M_RUN;
            end
        end

        M_RUN: begin
            if (frame_complete) master_state <= M_DONE;
        end

        M_DONE: begin
            frame_done <= 1'b1;
            if (start_frame) begin
                frame_done    <= 1'b0;
                init_px       <= 11'd0;
                init_py       <= 10'd0;
                init_cr_accum <= cr_first;
                init_ci_accum <= ci_first;
                stack_top     <= {SP_W{1'b0}};
                master_state  <= M_INIT_TABLES;
            end
        end

        default: master_state <= M_IDLE;
        endcase

        // -------- Per-slot FSM transitions (M_RUN only) --------
        if (master_state == M_RUN) begin
            for (s = 0; s < N_SLOTS; s = s + 1) begin
                case (slot_state[s])
                SL_IDLE: begin
                    // Idle arbiter assigns one IDLE slot the top of the stack.
                    // stack_top update is handled by the combined delta below.
                    if ((s[RID_W-1:0] == idle_slot) && idle_has &&
                        (stack_top != {SP_W{1'b0}})) begin
                        slot_x0[s]    <= {1'b0, stack_x0[stack_top - 1'b1]};
                        slot_y0[s]    <=         stack_y0[stack_top - 1'b1];
                        slot_w[s]     <=         stack_w [stack_top - 1'b1];
                        slot_h[s]     <=         stack_h [stack_top - 1'b1];
                        slot_state[s] <= SL_PREP;
                    end
                end

                SL_PREP: begin
                    slot_x_max[s]    <= slot_x0[s] + slot_w[s] - 11'd1;
                    slot_y_max[s]    <= slot_y0[s] + slot_h[s] - 10'd1;
                    slot_received[s] <= 17'd0;
                    slot_first[s]    <= 1'b0;
                    slot_min_iter[s] <= 12'd0;
                    slot_max_iter[s] <= 12'd0;
                    slot_unif_t[s]   <= 1'b1;
                    slot_unif_f[s]   <= 1'b1;
                    slot_walk_px[s]  <= slot_x0[s];
                    slot_walk_py[s]  <= slot_y0[s];
                    if ((slot_w[s] < {3'b0, min_region_dim}) ||
                        (slot_h[s] < {2'b0, min_region_dim})) begin
                        slot_expected[s] <= {6'b0, slot_w[s]} * {7'b0, slot_h[s]};
                        slot_state[s]    <= SL_FULL_OUT;
                    end else begin
                        slot_expected[s] <= {6'b0, slot_w[s]} + {6'b0, slot_w[s]} +
                                            {7'b0, slot_h[s]} + {7'b0, slot_h[s]} - 17'd4;
                        slot_state[s]    <= SL_BD_TOP;
                    end
                end

                SL_FULL_OUT: begin
                    if ((s[RID_W-1:0] == disp_slot) && disp_has && coord_ready) begin
                        if (slot_walk_px[s] == slot_x_max[s]) begin
                            slot_walk_px[s] <= slot_x0[s];
                            if (slot_walk_py[s] == slot_y_max[s]) begin
                                slot_state[s] <= SL_WAIT_FULL;
                            end else begin
                                slot_walk_py[s] <= slot_walk_py[s] + 10'd1;
                            end
                        end else begin
                            slot_walk_px[s] <= slot_walk_px[s] + 11'd1;
                        end
                    end
                end

                SL_BD_TOP: begin
                    if ((s[RID_W-1:0] == disp_slot) && disp_has && coord_ready) begin
                        if (slot_walk_px[s] == slot_x_max[s]) begin
                            slot_walk_py[s] <= slot_y0[s] + 10'd1;
                            slot_state[s]   <= SL_BD_RIGHT;
                        end else begin
                            slot_walk_px[s] <= slot_walk_px[s] + 11'd1;
                        end
                    end
                end

                SL_BD_RIGHT: begin
                    if ((s[RID_W-1:0] == disp_slot) && disp_has && coord_ready) begin
                        if (slot_walk_py[s] == slot_y_max[s]) begin
                            slot_walk_px[s] <= slot_x_max[s] - 11'd1;
                            slot_state[s]   <= SL_BD_BOT;
                        end else begin
                            slot_walk_py[s] <= slot_walk_py[s] + 10'd1;
                        end
                    end
                end

                SL_BD_BOT: begin
                    if ((s[RID_W-1:0] == disp_slot) && disp_has && coord_ready) begin
                        if (slot_walk_px[s] == slot_x0[s]) begin
                            slot_walk_py[s] <= slot_y_max[s] - 10'd1;
                            slot_state[s]   <= SL_BD_LEFT;
                        end else begin
                            slot_walk_px[s] <= slot_walk_px[s] - 11'd1;
                        end
                    end
                end

                SL_BD_LEFT: begin
                    if ((s[RID_W-1:0] == disp_slot) && disp_has && coord_ready) begin
                        if (slot_walk_py[s] == slot_y0[s] + 10'd1) begin
                            slot_state[s] <= SL_WAIT_BD;
                        end else begin
                            slot_walk_py[s] <= slot_walk_py[s] - 10'd1;
                        end
                    end
                end

                SL_WAIT_BD: begin
                    if (slot_received[s] == slot_expected[s]) begin
                        slot_state[s] <= SL_DECIDE;
                    end
                end

                SL_WAIT_FULL: begin
                    if (slot_received[s] == slot_expected[s]) begin
                        slot_state[s] <= SL_IDLE;
                    end
                end

                SL_DECIDE: begin
                    if ((slot_min_iter[s] == slot_max_iter[s]) &&
                        (slot_unif_t[s] || slot_unif_f[s])) begin
                        slot_fill_iter[s] <= slot_min_iter[s];
                        slot_fill_esc[s]  <= slot_unif_t[s];
                        slot_walk_px[s]   <= slot_x0[s] + 11'd1;
                        slot_walk_py[s]   <= slot_y0[s] + 10'd1;
                        slot_state[s]     <= SL_FILL;
                    end else begin
                        slot_state[s]     <= SL_SPLIT;
                    end
                end

                SL_FILL: begin
                    // Only one slot fills per cycle (lowest-id wins).
                    if (s[RID_W-1:0] == fill_slot) begin
                        if (slot_walk_px[s] == slot_x_max[s] - 11'd1) begin
                            if (slot_walk_py[s] == slot_y_max[s] - 10'd1) begin
                                slot_state[s] <= SL_IDLE;
                            end else begin
                                slot_walk_px[s] <= slot_x0[s] + 11'd1;
                                slot_walk_py[s] <= slot_walk_py[s] + 10'd1;
                            end
                        end else begin
                            slot_walk_px[s] <= slot_walk_px[s] + 11'd1;
                        end
                    end
                end

                SL_SPLIT: begin
                    // Split arbiter: only one slot pushes per cycle.
                    // stack_top update is handled by the combined delta below.
                    if (s[RID_W-1:0] == split_slot) begin
                        stack_x0[stack_top + 'd0] <= slot_x0[s][9:0];
                        stack_y0[stack_top + 'd0] <= slot_y0[s];
                        stack_w [stack_top + 'd0] <= split_w_a;
                        stack_h [stack_top + 'd0] <= split_h_a;
                        stack_x0[stack_top + 'd1] <= slot_x0[s][9:0] + split_w_a[9:0];
                        stack_y0[stack_top + 'd1] <= slot_y0[s];
                        stack_w [stack_top + 'd1] <= split_w_b;
                        stack_h [stack_top + 'd1] <= split_h_a;
                        stack_x0[stack_top + 'd2] <= slot_x0[s][9:0];
                        stack_y0[stack_top + 'd2] <= slot_y0[s] + {1'b0, split_h_a[8:0]};
                        stack_w [stack_top + 'd2] <= split_w_a;
                        stack_h [stack_top + 'd2] <= split_h_b;
                        stack_x0[stack_top + 'd3] <= slot_x0[s][9:0] + split_w_a[9:0];
                        stack_y0[stack_top + 'd3] <= slot_y0[s] + {1'b0, split_h_a[8:0]};
                        stack_w [stack_top + 'd3] <= split_w_b;
                        stack_h [stack_top + 'd3] <= split_h_b;
                        slot_state[s]             <= SL_IDLE;
                    end
                end

                default: slot_state[s] <= SL_IDLE;
                endcase
            end

            // -------- Result router --------
            // Route the returning iter result to the slot that owns it.
            if (result_valid) begin
                slot_received[result_region_id] <= slot_received[result_region_id] + 17'd1;
                if (!slot_first[result_region_id]) begin
                    slot_min_iter[result_region_id] <= result_iter;
                    slot_max_iter[result_region_id] <= result_iter;
                    slot_unif_t[result_region_id]   <=  result_escaped;
                    slot_unif_f[result_region_id]   <= ~result_escaped;
                    slot_first[result_region_id]    <= 1'b1;
                end else begin
                    if (result_iter < slot_min_iter[result_region_id])
                        slot_min_iter[result_region_id] <= result_iter;
                    if (result_iter > slot_max_iter[result_region_id])
                        slot_max_iter[result_region_id] <= result_iter;
                    if (!result_escaped) slot_unif_t[result_region_id] <= 1'b0;
                    if ( result_escaped) slot_unif_f[result_region_id] <= 1'b0;
                end
            end

            // -------- Combined stack_top update --------
            // Apply both push (+4) and pop (-1) deltas in one assignment so
            // the per-slot for-loop above never writes stack_top from
            // multiple branches. Saturating: push can't grow stack past
            // STACK_DEPTH (regions large enough to split fit easily).
            if (push_will_happen && pop_will_happen)
                stack_top <= stack_top + 'd4 - 'd1;
            else if (push_will_happen)
                stack_top <= stack_top + 'd4;
            else if (pop_will_happen)
                stack_top <= stack_top - 'd1;
        end
    end
end

endmodule
