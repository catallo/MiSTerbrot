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
wire [10:0] H_PIXELS = mode_640 ? 11'd640 : 11'd320;
localparam [9:0]  V_PIXELS = 10'd240;

// step_x: in 640 mode, halve step so 640 pixels cover same complex-plane
// horizontal extent as 320 pixels did. Vertical step stays at `step`.
wire signed [WIDTH-1:0] step_x = mode_640 ? (step >>> 1) : step;

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
wire signed [WIDTH-1:0] ci_start = center_y - half_v_offset;

// States
localparam [1:0] S_IDLE  = 2'd0,
                 S_SCAN  = 2'd1,
                 S_DONE  = 2'd2;

reg [1:0] state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_IDLE;
        valid        <= 1'b0;
        frame_done   <= 1'b0;
        px           <= 11'd0;
        py           <= 10'd0;
        cr_accum     <= {WIDTH{1'b0}};
        ci_accum     <= {WIDTH{1'b0}};
        cr_row_start <= {WIDTH{1'b0}};
        pixel_x      <= 11'd0;
        pixel_y      <= 10'd0;
        cr           <= {WIDTH{1'b0}};
        ci           <= {WIDTH{1'b0}};
    end else begin
        case (state)
        S_IDLE: begin
            valid      <= 1'b0;
            frame_done <= 1'b0;
            if (start_frame) begin
                px           <= 11'd0;
                py           <= 10'd0;
                cr_accum     <= cr_start;
                ci_accum     <= ci_start;
                cr_row_start <= cr_start;
                state        <= S_SCAN;
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
                if (px == H_PIXELS - 11'd1) begin
                    if (py == V_PIXELS - 10'd1) begin
                        // End of frame
                        state <= S_DONE;
                    end else begin
                        // Next row
                        px           <= 11'd0;
                        py           <= py + 10'd1;
                        cr_accum     <= cr_row_start;
                        ci_accum     <= ci_accum + step;
                    end
                end else begin
                    // Next pixel in row
                    px       <= px + 11'd1;
                    cr_accum <= cr_accum + step_x;
                end
            end
        end

        S_DONE: begin
            valid      <= 1'b0;
            frame_done <= 1'b1;
            if (start_frame) begin
                px           <= 11'd0;
                py           <= 10'd0;
                cr_accum     <= cr_start;
                ci_accum     <= ci_start;
                cr_row_start <= cr_start;
                frame_done   <= 1'b0;
                state        <= S_SCAN;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
