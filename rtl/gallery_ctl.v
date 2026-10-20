// Gallery Mode controller (docs/GALLERY_DESIGN.md).
//
// Live render only (2026-10-20; the O[59] "Gallery Live Render" toggle
// and its hidden-bank fade-flip path were removed — gallery always paints
// each POI progressively over the previous image, the classic
// fractal-program look, into the single displayed buffer).
//
//   - Activation clear: on gallery entry the index buffer is wiped to
//     index 0 (interior black) through the normal write port, so the
//     first thing on screen is black — never stale DDR3 noise.
//     clear_done pulses once so fractal_top can force a re-render (an
//     in-flight render's writes are dropped during the clear).
//   - blank: high from gallery entry until the clear has finished; the
//     palette writer emits all-black entries while it is set, so the
//     clear itself is never visible.
//   - dwell_ok: high once the buffer is cleared and painting in place —
//     auto_zoom's "Wait on POI" counts only this time.
//
// clk = clk_sys.

module gallery_ctl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gallery_en,
    input  wire        wr_ready,         // clear-write pacing

    // clear stream (fractal_top muxes it ahead of the render tap)
    output wire        clear_active,
    output reg         clear_wr,
    output reg  [10:0] clear_x,
    output reg  [10:0] clear_y,
    output reg         clear_done,       // 1-cycle: force re-render

    output wire        blank,            // palette black until cleared
    output wire        dwell_ok
);

localparam [10:0] W = 11'd1920;
localparam [10:0] H = 11'd1080;

localparam [1:0] G_OFF   = 2'd0,
                 G_CLEAR = 2'd1,
                 G_LIVE  = 2'd2;
reg [1:0] state;

// clear_wr is registered: the final write is presented one cycle
// AFTER the state leaves G_CLEAR — hold clear_active through it so
// the write mux doesn't drop the last pixel (caught by the TB's
// clear push count).
assign clear_active = (state == G_CLEAR) || clear_wr;
assign blank        = (state != G_LIVE);
assign dwell_ok     = (state == G_LIVE);

// Internal clear scan counters — SEPARATE from the output registers:
// the outputs latch the coordinate being written on the same edge as
// clear_wr, while cx/cy advance to the next pixel.  (Same hazard as
// the stage-1 pattern engine: advancing the output directly presents
// the write one pixel ahead.)
reg [10:0] cx, cy;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= G_OFF;
        clear_wr   <= 1'b0;
        clear_x    <= 11'd0;
        clear_y    <= 11'd0;
        clear_done <= 1'b0;
        cx         <= 11'd0;
        cy         <= 11'd0;
    end else begin
        clear_wr   <= 1'b0;
        clear_done <= 1'b0;

        if (!gallery_en) begin
            state <= G_OFF;
        end else case (state)
        G_OFF: begin
            // gallery just activated: wipe the buffer to black
            cx    <= 11'd0;
            cy    <= 11'd0;
            state <= G_CLEAR;
        end

        G_CLEAR: begin
            if (wr_ready) begin
                clear_wr <= 1'b1;
                clear_x  <= cx;
                clear_y  <= cy;
                if (cx == W - 11'd1) begin
                    cx <= 11'd0;
                    if (cy == H - 11'd1) begin
                        cy <= 11'd0;
                        // buffer black; render restarts via clear_done,
                        // palette shows from here on
                        clear_done <= 1'b1;
                        state      <= G_LIVE;
                    end else begin
                        cy <= cy + 11'd1;
                    end
                end else begin
                    cx <= cx + 11'd1;
                end
            end
        end

        G_LIVE: ;   // paint in place until gallery_en drops

        default: state <= G_OFF;
        endcase
    end
end

endmodule
