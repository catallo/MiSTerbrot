//============================================================================
// Coordinate Generator (mode-selectable 320 / 640 wide)
//
// Scans pixels left-to-right, top-to-bottom and maps each pixel (x,y) to
// complex plane coordinates (cr, ci) based on center/step (zoom) registers.
//
// mode_640=0: 320×240 grid, step_x = step
// mode_640=1: 640×240 grid, step_x = step/2 (so the same horizontal extent
//             of the complex plane is sampled at twice the density — square
//             pixels in 8:3-source-into-4:3-output ascaler config)
//
// Uses accumulation (no per-pixel multiply): adds step_x for each x increment,
// adds step (vertical) for each row increment.
//
// Valid/ready handshake: outputs a new coordinate when valid=1 and ready=1.
//============================================================================

module coord_generator #(
    parameter WIDTH    = 64,
    parameter FRAC_BITS = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    mode_640,

    // Control
    input  wire                    start_frame,
    // Real-axis symmetry: when 1, scan only rows 0..120 (the top half +
    // center axis).  Caller mirror-writes rows 121..239 from the
    // (240-y) result.  Latched at start_frame so it can't change
    // mid-scan.
    input  wire                    symmetry_active,
    input  wire signed [WIDTH-1:0] center_x,
    input  wire signed [WIDTH-1:0] center_y,
    input  wire signed [WIDTH-1:0] step,

    // Handshake
    input  wire                    ready,
    output reg                     valid,

    // Coordinate output
    output reg  [10:0]             pixel_x,
    output reg  [9:0]              pixel_y,
    output reg  signed [WIDTH-1:0] cr,
    output reg  signed [WIDTH-1:0] ci,
    output reg                     frame_done
);

// Per-mode resolution
localparam [9:0]  V_PIXELS = 10'd240;
// Last row to emit when symmetry is active.  With the half-step ci
// grid shift below, the symmetry axis lies *between* rows 119 and
// 120 instead of on row 120 itself, so we iterate exactly 120 rows
// (0..119) and the caller mirrors them to rows 239..120.  Result:
// clean 2.00× speedup, no center-axis row to special-case.
localparam [9:0]  V_PIXELS_SYM_LAST = 10'd119;

// Per-frame latched copies of step and mode_640.  Without these
// latches the per-pixel cr-increment and per-row ci-increment use
// the LIVE input values, which drift continuously when auto_zoom is
// interpolating between POIs.  On slow scenes (~few fps) the drift
// is large enough between top-of-frame and bottom-of-frame to cause
// visible geometric warping — the top half samples with one step,
// the bottom with another.  Latching here is the same pattern as
// `sym_frame` below.
reg signed [WIDTH-1:0] step_frame;
reg                    mode_640_frame;

wire [10:0]             H_PIXELS_frame = mode_640_frame ? 11'd640 : 11'd320;
// step_x: in 640 mode, halve step so 640 pixels cover same complex-plane
// horizontal extent as 320 pixels did.  Uses the latched step.
wire signed [WIDTH-1:0] step_x_frame   = mode_640_frame ? (step_frame >>> 1)
                                                        : step_frame;

// Internal pixel counters
reg [10:0] px;
reg [9:0]  py;

// Accumulated coordinates
reg signed [WIDTH-1:0] cr_accum;
reg signed [WIDTH-1:0] ci_accum;
reg signed [WIDTH-1:0] cr_row_start;

// Starting coordinates using shift-add (no 64-bit multiplies)
// cr_start = center_x - (H_PIXELS/2) * step_x. Both modes evaluate to 160*step:
//   320 mode: 160 * step
//   640 mode: 320 * (step/2) = 160 * step
// → identical formula in both modes (160*step), no mux needed.
wire signed [WIDTH-1:0] half_h_offset = (step <<< 7) + (step <<< 5);  // 160 * step
wire signed [WIDTH-1:0] half_v_offset = (step <<< 7) - (step <<< 3);  // 120 * step
wire signed [WIDTH-1:0] cr_start = center_x - half_h_offset;
// Half-step grid shift in ci: ci_start is offset by step/2 so no row
// ever lands on ci=0 exactly.  Without this, any view crossing the
// real axis renders a hard horizontal line at that row — the M-set's
// real-axis intersection M∩ℝ = [-2, 0.25] is a 1D line of zero
// imaginary width, and a single-sample renderer hitting it produces
// dramatically different iter counts than ci=±step neighbours.
// See Cheritat (math.univ-toulouse.fr) for the canonical description
// of this artifact.  Cost: 0 (just a different constant); side
// effect: image samples shifted by half a pixel in the imaginary
// direction (sub-pixel — visually imperceptible).
wire signed [WIDTH-1:0] ci_start = center_y - half_v_offset + (step >>> 1);

// States
localparam [1:0] S_IDLE  = 2'd0,
                 S_SCAN  = 2'd1,
                 S_DONE  = 2'd2;

reg [1:0] state;

// Per-frame latched copy of symmetry_active so the scan range can't
// change between IDLE and DONE even if the caller toggles the input
// while a frame is in flight.
reg sym_frame;
wire [9:0] py_last = sym_frame ? V_PIXELS_SYM_LAST : (V_PIXELS - 10'd1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        valid          <= 1'b0;
        frame_done     <= 1'b0;
        px             <= 11'd0;
        py             <= 10'd0;
        cr_accum       <= {WIDTH{1'b0}};
        ci_accum       <= {WIDTH{1'b0}};
        cr_row_start   <= {WIDTH{1'b0}};
        pixel_x        <= 11'd0;
        pixel_y        <= 10'd0;
        cr             <= {WIDTH{1'b0}};
        ci             <= {WIDTH{1'b0}};
        sym_frame      <= 1'b0;
        step_frame     <= {WIDTH{1'b0}};
        mode_640_frame <= 1'b0;
    end else begin
        case (state)
        S_IDLE: begin
            valid      <= 1'b0;
            frame_done <= 1'b0;
            if (start_frame) begin
                px             <= 11'd0;
                py             <= 10'd0;
                cr_accum       <= cr_start;
                ci_accum       <= ci_start;
                cr_row_start   <= cr_start;
                sym_frame      <= symmetry_active;
                step_frame     <= step;
                mode_640_frame <= mode_640;
                state          <= S_SCAN;
            end
        end

        S_SCAN: begin
            if (!valid || ready) begin
                // Output current pixel
                valid   <= 1'b1;
                pixel_x <= px;
                pixel_y <= py;
                cr      <= cr_accum;
                ci      <= ci_accum;

                // Advance to next pixel
                if (px == H_PIXELS_frame - 11'd1) begin
                    if (py == py_last) begin
                        // End of frame (full or symmetric half)
                        state <= S_DONE;
                    end else begin
                        // Next row
                        px           <= 11'd0;
                        py           <= py + 10'd1;
                        cr_accum     <= cr_row_start;
                        ci_accum     <= ci_accum + step_frame;
                    end
                end else begin
                    // Next pixel in row
                    px       <= px + 11'd1;
                    cr_accum <= cr_accum + step_x_frame;
                end
            end
        end

        S_DONE: begin
            // Hold the final pixel until the consumer takes it.  Clearing
            // valid unconditionally here dropped the last pixel of the
            // frame whenever the dispatcher back-pressured on that exact
            // cycle (which it almost always does at end-of-frame — the
            // round-robin ring's oldest slot is still busy), leaving one
            // permanently stale framebuffer pixel per frame.  frame_done
            // must not assert until the pixel is actually handed off.
            if (!valid || ready) begin
                valid      <= 1'b0;
                frame_done <= 1'b1;
            end
            if (start_frame) begin
                valid          <= 1'b0;
                px             <= 11'd0;
                py             <= 10'd0;
                cr_accum       <= cr_start;
                ci_accum       <= ci_start;
                cr_row_start   <= cr_start;
                sym_frame      <= symmetry_active;
                step_frame     <= step;
                mode_640_frame <= mode_640;
                frame_done     <= 1'b0;
                state          <= S_SCAN;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
