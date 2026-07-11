// Gallery Mode controller (docs/GALLERY_DESIGN.md).
//
// STAGE 3b (this version): buffer clear, bank policy and the O[59]
// live-render toggle.
//
//   - Activation clear: on gallery entry both index buffers are wiped
//     to index 0 (interior black) through the normal write port, so
//     the first thing on screen is black — never stale DDR3 noise.
//     clear_done pulses once so fractal_top can force a re-render
//     (an in-flight render's writes are dropped during the clear).
//   - Live mode (O[59]=On, default): render_bank == display_bank —
//     each POI paints progressively over the previous image, the
//     classic fractal-program look.
//   - Hidden mode (O[59]=Off): render_bank == ~display_bank; when a
//     frame commits (render collected + write FIFO drained), the
//     palette fades to black (fade_scale -> 0), FB_BASE flips while
//     the screen is uniformly black (tear-free by construction), and
//     the palette fades back in.
//   - dwell_ok: high only when a settled image is on display (fade at
//     full, no flip in progress) — auto_zoom's "Wait on POI" counts
//     only this time.
//
// Fade rate: 3/vblank, 63 -> 0 in 21 frames (~0.35 s per direction).
//
// clk = clk_sys.

module gallery_ctl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gallery_en,
    input  wire        live_render,      // O[59]==0: paint visibly
    input  wire        frame_done_rise,  // render frame collected
    input  wire        render_idle,      // render FSM idle, no restart pending
    input  wire        wr_idle,          // gallery_fb FIFO drained
    input  wire        vblank_rise,      // clk-domain vblank tick
    input  wire        wr_ready,         // clear-write pacing

    // clear stream (fractal_top muxes it ahead of the render tap)
    output wire        clear_active,
    output reg         clear_wr,
    output reg  [10:0] clear_x,
    output reg  [10:0] clear_y,
    output reg         clear_bank,
    output reg         clear_done,       // 1-cycle: force re-render

    // bank policy + palette fade (consumed by gallery_fb / _palette)
    output wire        render_bank,
    output reg         display_bank,
    output reg  [5:0]  fade_scale,
    output wire        dwell_ok
);

localparam [10:0] W = 11'd1920;
localparam [10:0] H = 11'd1080;
localparam [5:0]  FADE_STEP = 6'd3;

localparam [2:0] G_OFF      = 3'd0,
                 G_CLEAR    = 3'd1,
                 G_WAIT     = 3'd2,
                 G_FADE_OUT = 3'd3,
                 G_FADE_IN  = 3'd4;
reg [2:0] state;

// clear_wr is registered: the final write is presented one cycle
// AFTER the state leaves G_CLEAR — hold clear_active through it so
// the write mux doesn't drop the last pixel (caught by the TB's
// clear push count: 4,147,199 of 4,147,200).
assign clear_active = (state == G_CLEAR) || clear_wr;
// live: paint into the displayed buffer; hidden: into the other one
assign render_bank  = live_render ? display_bank : ~display_bank;
assign dwell_ok     = (state == G_WAIT) && (fade_scale == 6'd63);

// commit = frame collected AND every index write drained to DDR3
reg commit_arm;
wire commit = commit_arm && wr_idle;

// Internal clear scan counters — SEPARATE from the output registers:
// the outputs latch the coordinate being written on the same edge as
// clear_wr, while cx/cy/cbank advance to the next pixel.  (Same
// hazard as the stage-1 pattern engine: advancing the output directly
// presents the write one pixel ahead.)
reg [10:0] cx, cy;
reg        cbank;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= G_OFF;
        clear_wr     <= 1'b0;
        clear_x      <= 11'd0;
        clear_y      <= 11'd0;
        clear_bank   <= 1'b0;
        clear_done   <= 1'b0;
        display_bank <= 1'b0;
        fade_scale   <= 6'd0;
        commit_arm   <= 1'b0;
        cx           <= 11'd0;
        cy           <= 11'd0;
        cbank        <= 1'b0;
    end else begin
        clear_wr   <= 1'b0;
        clear_done <= 1'b0;

        if (frame_done_rise) commit_arm <= 1'b1;

        if (!gallery_en) begin
            state        <= G_OFF;
            display_bank <= 1'b0;
            fade_scale   <= 6'd0;
            commit_arm   <= 1'b0;
        end else case (state)
        G_OFF: begin
            // gallery just activated: wipe both banks to black
            cx         <= 11'd0;
            cy         <= 11'd0;
            cbank      <= 1'b0;
            fade_scale <= 6'd0;
            commit_arm <= 1'b0;
            state      <= G_CLEAR;
        end

        G_CLEAR: begin
            if (wr_ready) begin
                clear_wr   <= 1'b1;
                clear_x    <= cx;
                clear_y    <= cy;
                clear_bank <= cbank;
                if (cx == W - 11'd1) begin
                    cx <= 11'd0;
                    if (cy == H - 11'd1) begin
                        cy <= 11'd0;
                        if (cbank) begin
                            // both banks black; render restarts via
                            // clear_done, palette can show immediately
                            clear_done <= 1'b1;
                            commit_arm <= 1'b0;
                            if (live_render) fade_scale <= 6'd63;
                            state <= G_WAIT;
                        end else begin
                            cbank <= 1'b1;
                        end
                    end else begin
                        cy <= cy + 11'd1;
                    end
                end else begin
                    cx <= cx + 11'd1;
                end
            end
        end

        G_WAIT: begin
            if (!live_render && commit) begin
                commit_arm <= 1'b0;
                state <= G_FADE_OUT;
            end else begin
                if (live_render) commit_arm <= 1'b0;  // paints in place
                // live mode (or a hidden->live switch mid-fade): ramp
                // the palette to full
                if (live_render && fade_scale != 6'd63 && vblank_rise)
                    fade_scale <= (fade_scale > 6'd63 - FADE_STEP)
                                  ? 6'd63 : fade_scale + FADE_STEP;
            end
        end

        G_FADE_OUT: begin
            if (vblank_rise && fade_scale != 6'd0)
                fade_scale <= (fade_scale <= FADE_STEP)
                              ? 6'd0 : fade_scale - FADE_STEP;
            // Flip only while black AND no render in flight: a frame
            // started before the flip samples render_bank per push, so
            // flipping mid-render splits it across banks (TB caught 4
            // pre-flip pushes draining after the flip).  If a rerender
            // raced the fade, hold at black until it commits — the
            // flip then shows the newest frame, and the flip consumes
            // that commit (else G_WAIT would ping-pong on it).
            if (fade_scale == 6'd0 && render_idle && wr_idle) begin
                display_bank <= ~display_bank;
                commit_arm   <= 1'b0;
                state        <= G_FADE_IN;
            end
        end

        G_FADE_IN: begin
            if (vblank_rise) begin
                if (fade_scale >= 6'd63 - FADE_STEP) begin
                    fade_scale <= 6'd63;
                    state      <= G_WAIT;
                end else begin
                    fade_scale <= fade_scale + FADE_STEP;
                end
            end
        end

        default: state <= G_OFF;
        endcase
    end
end

endmodule
