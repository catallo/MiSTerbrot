//============================================================================
// Input Handler (v0.8)
//
// Processes MiSTer joystick and keyboard input to control fractal parameters:
//   D-Pad:     Pan (adjust center_x, center_y)
//   L/R:       Zoom in/out (adjust step)
//   Button A:  Toggle fractal type (Mandelbrot <-> Julia)
//   Button B:  Cycle palette (32 palettes)
//   Button Y:  Reset to default view
//
// MiSTer joystick bit layout:
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=A [5]=B [6]=X [7]=Y
//   [8]=L [9]=R [10]=Select [11]=Start
//
// Debounces button presses and provides auto-repeat for D-pad.
//============================================================================

module input_handler #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire [15:0]             joystick,
    input  wire [10:0]             ps2_key,
    input  wire [2:0]              osd_iter_sel,
    input  wire                    osd_iter_changed,
    input  wire                    sync_clear_palette_override,

    // Current step (for computing pan speed)
    input  wire signed [WIDTH-1:0] step_in,

    // Outputs (directly drive fractal parameters)
    output reg  signed [WIDTH-1:0] center_x,
    output reg  signed [WIDTH-1:0] center_y,
    output reg  signed [WIDTH-1:0] step,
    output reg  [6:0]              palette_sel,
    output reg                     palette_override_active,
    output reg  [2:0]              iter_sel,
    output reg                     overlay_enable,
    output reg                     color_cycle_enable,  // 0=Auto, 1=On, 2=Off
    output reg                     view_changed,

    // Auto-zoom control
    output reg                     auto_zoom_toggle,
    output reg                     auto_zoom_deactivate,
    output reg                     auto_zoom_skip_next,
    output reg                     auto_zoom_snap_next,  // M key / X button: snap to next POI canonical view
    output reg                     benchmark_toggle,     // B key: toggle deterministic benchmark mode
    output reg                     benchmark_next,       // V key: advance deterministic benchmark scene
    output reg                     key_bg_dim_on,        // G key: force overlay BG to Dimmed
    output reg                     key_bg_dim_off,       // H key: force overlay BG to Transparent
    output reg                     key_blank_text_on,    // K key: force overlay blanking timer ON
    output reg                     key_blank_text_off,   // L key: force overlay blanking timer OFF
    output reg                     key_vmode_toggle,     // J key: toggle V-Mode 240p/480i (verification)
    input  wire                    auto_zoom_active,
    input  wire                    sync_from_auto_zoom,
    input  wire signed [WIDTH-1:0] sync_center_x,
    input  wire signed [WIDTH-1:0] sync_center_y,
    input  wire signed [WIDTH-1:0] sync_step,
    input  wire [6:0]              sync_palette_sel
);

// Default view parameters
localparam signed [WIDTH-1:0] DEFAULT_CENTER_X = 64'shFF80000000000000; // -0.5
localparam signed [WIDTH-1:0] DEFAULT_CENTER_Y = 64'sh0000000000000000; //  0.0
localparam signed [WIDTH-1:0] DEFAULT_STEP     = 64'sh0003333333333333; //  0.0125
localparam signed [WIDTH-1:0] MIN_STEP         = 64'sh0000000000000010; //  tiny zoom
// Manual view bounds (2026-10-11).  The iterator's interior prechecks are
// 8.56 fixed-point with no overflow guard on the cardioid product
// q*(q+x): beyond |c| of about 3.4 it wraps and paints false interior
// bands, and past |c| >= 11.3 even the z1=c escape test wraps.  So every
// on-screen pixel must stay inside |cr|,|ci| <= VIEW_LIMIT.  The frame
// extends 160*step horizontally and 120*step vertically from the centre
// (coord_generator's half_h_offset / half_v_offset), hence:
//   MAX_STEP   = 3.0/160 = 0.01875 (1.5x the default view width, which
//                already shows the whole set with margin)
//   pan/zoom   = only applied when the resulting frame stays inside the
//                limit; a move that would leave it is simply ignored.
// The old MAX_STEP of 4.0 let the edges reach +-640 and center_x/y were
// never clamped at all.
localparam signed [WIDTH-1:0] MAX_STEP         = 64'sh0004CCCCCCCCCCCD; //  0.01875
localparam signed [WIDTH-1:0] VIEW_LIMIT       = 64'sh0300000000000000; //  3.0

// Pan speed: step * 2 (reduced to 1/4 of the previous manual pan speed)
wire signed [WIDTH-1:0] pan_speed = {step[WIDTH-2:0], 1'b0};

// Manual zoom speed: 2x faster than auto-zoom's step >>> 9
wire signed [WIDTH-1:0] step_delta = step >>> 8;

// ---- View-bound checks (sampled only on repeat_tick, 50 MHz domain) ----
// The new centre / step values are exact 64-bit; the BOUND arithmetic
// runs on the top 24 bits (8 integer + 16 fraction bits, 1.5e-5
// resolution) — a +/-3.0 limit does not need 56 fraction bits, and the
// 64-bit version cost ~500 ALMs (ALM diet 2026-10-12).  Truncation makes
// a check at most 1.5e-5 permissive, invisible at the limit.
localparam BW = 24;
localparam signed [BW-1:0] VIEW_LIMIT_B = VIEW_LIMIT[WIDTH-1 -: BW];
localparam signed [BW-1:0] MAX_STEP_B   = MAX_STEP[WIDTH-1 -: BW];
wire signed [WIDTH-1:0] cx_right = center_x + pan_speed;
wire signed [WIDTH-1:0] cx_left  = center_x - pan_speed;
wire signed [WIDTH-1:0] cy_down  = center_y + pan_speed;
wire signed [WIDTH-1:0] cy_up    = center_y - pan_speed;
wire signed [WIDTH-1:0] step_out = step + step_delta;
wire signed [BW-1:0] step_b     = step[WIDTH-1 -: BW];
wire signed [BW-1:0] step_out_b = step_out[WIDTH-1 -: BW];
// Half extents of the current / zoomed-out frame (160 * step, 120 * step).
wire signed [BW-1:0] half_w     = (step_b <<< 7) + (step_b <<< 5);
wire signed [BW-1:0] half_h     = (step_b <<< 7) - (step_b <<< 3);
wire signed [BW-1:0] half_w_out = (step_out_b <<< 7) + (step_out_b <<< 5);
wire signed [BW-1:0] half_h_out = (step_out_b <<< 7) - (step_out_b <<< 3);
wire signed [BW-1:0] bound_x    = VIEW_LIMIT_B - half_w;            // max |centre_x|
wire signed [BW-1:0] bound_y    = VIEW_LIMIT_B - half_h;            // max |centre_y|
wire signed [BW-1:0] cx_right_b = cx_right[WIDTH-1 -: BW];
wire signed [BW-1:0] cx_left_b  = cx_left [WIDTH-1 -: BW];
wire signed [BW-1:0] cy_down_b  = cy_down [WIDTH-1 -: BW];
wire signed [BW-1:0] cy_up_b    = cy_up   [WIDTH-1 -: BW];
// Each direction is allowed when the NEW centre is inside the bound in
// that direction only — so a centre that is somehow already outside can
// still be panned back in, never further out.
wire pan_right_ok = (cx_right_b <= bound_x);
wire pan_left_ok  = (cx_left_b  >= -bound_x);
wire pan_down_ok  = (cy_down_b  <= bound_y);
wire pan_up_ok    = (cy_up_b    >= -bound_y);
// Zoom-out: the larger frame around the current centre must still fit.
wire signed [BW-1:0] cx_b    = center_x[WIDTH-1 -: BW];
wire signed [BW-1:0] cy_b    = center_y[WIDTH-1 -: BW];
wire signed [BW-1:0] abs_cx  = cx_b[BW-1] ? -cx_b : cx_b;
wire signed [BW-1:0] abs_cy  = cy_b[BW-1] ? -cy_b : cy_b;
wire zoom_out_ok = (step_out_b <= MAX_STEP_B)
                && ((abs_cx + half_w_out) <= VIEW_LIMIT_B)
                && ((abs_cy + half_h_out) <= VIEW_LIMIT_B);

// Button edge detection
reg [15:0] joy_prev;
wire [15:0] joy_press = joystick & ~joy_prev;

// PS/2 keyboard edge detection
reg        ps2_strobe_prev;
wire       ps2_strobe_edge = (ps2_key[10] != ps2_strobe_prev);
wire       ps2_pressed     = ps2_key[9];
wire       ps2_extended    = ps2_key[8];
wire [7:0] ps2_scancode    = ps2_key[7:0];

// Held keys for pan/zoom
reg key_up, key_down, key_left, key_right;
reg key_zoom_in, key_zoom_out;

// Auto-repeat counter (~15 Hz at 50 MHz)
reg [19:0] repeat_cnt;
wire repeat_tick = (repeat_cnt == 20'd0);

// Combined held signals
wire hold_right    = joystick[0] | key_right;
wire hold_left     = joystick[1] | key_left;
wire hold_down     = joystick[2] | key_down;
wire hold_up       = joystick[3] | key_up;
wire hold_zoom_out = joystick[8] | key_zoom_out;
wire hold_zoom_in  = joystick[9] | key_zoom_in;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        center_x        <= DEFAULT_CENTER_X;
        center_y        <= DEFAULT_CENTER_Y;
        step            <= DEFAULT_STEP;
        palette_sel     <= 7'd0;
        palette_override_active <= 1'b0;
        iter_sel        <= 3'd5;  // Auto
        overlay_enable  <= 1'b1;
        color_cycle_enable <= 1'b1;  // Auto
        view_changed    <= 1'b1;
        joy_prev        <= 16'd0;
        repeat_cnt      <= 20'd0;
        ps2_strobe_prev <= 1'b0;
        key_up          <= 1'b0;
        key_down        <= 1'b0;
        key_left        <= 1'b0;
        key_right       <= 1'b0;
        key_zoom_in     <= 1'b0;
        key_zoom_out    <= 1'b0;
        auto_zoom_toggle     <= 1'b0;
        auto_zoom_deactivate <= 1'b0;
        auto_zoom_skip_next  <= 1'b0;
        auto_zoom_snap_next  <= 1'b0;
        benchmark_toggle     <= 1'b0;
        benchmark_next       <= 1'b0;
        key_bg_dim_on        <= 1'b0;
        key_bg_dim_off       <= 1'b0;
        key_blank_text_on    <= 1'b0;
        key_blank_text_off   <= 1'b0;
        key_vmode_toggle     <= 1'b0;
    end else begin
        auto_zoom_toggle     <= 1'b0;
        auto_zoom_deactivate <= 1'b0;
        auto_zoom_skip_next  <= 1'b0;
        auto_zoom_snap_next  <= 1'b0;
        benchmark_toggle     <= 1'b0;
        benchmark_next       <= 1'b0;
        key_bg_dim_on        <= 1'b0;
        key_bg_dim_off       <= 1'b0;
        key_blank_text_on    <= 1'b0;
        key_blank_text_off   <= 1'b0;
        key_vmode_toggle     <= 1'b0;
        joy_prev        <= joystick;
        ps2_strobe_prev <= ps2_key[10];
        view_changed    <= 1'b0;

        if (sync_from_auto_zoom) begin
            center_x    <= sync_center_x;
            center_y    <= sync_center_y;
            step        <= sync_step;
            palette_sel <= sync_palette_sel;
            view_changed <= 1'b1;
        end

        // ---- Sync: clear palette override on target change ----
        if (sync_clear_palette_override)
            palette_override_active <= 1'b0;

        // ---- Continuous palette mirror while auto-zoom drives the view ----
        // While auto-zoom is active and the user has not overridden the
        // palette, keep palette_sel in lockstep with sync_palette_sel (=
        // az_palette_idx). This way the next P-press increments from the
        // palette the user is actually looking at, not from the reset value.
        if (auto_zoom_active && !palette_override_active)
            palette_sel <= sync_palette_sel;

        // ---- OSD Iterations sync ----
        if (osd_iter_changed) begin
            iter_sel <= osd_iter_sel;
            view_changed <= 1'b1;
        end

        // ---- PS/2 Keyboard Input ----
        if (ps2_strobe_edge) begin
            if (ps2_extended) begin
                case (ps2_scancode)
                    8'h75: begin key_up       <= ps2_pressed; end
                    8'h72: begin key_down     <= ps2_pressed; end
                    8'h6B: begin key_left     <= ps2_pressed; end
                    8'h74: begin key_right    <= ps2_pressed; end
                    8'h7D: begin key_zoom_in  <= ps2_pressed; end
                    8'h7A: begin key_zoom_out <= ps2_pressed; end
                    8'h6C: begin // Home = Reset view
                        if (ps2_pressed) begin
                            center_x     <= DEFAULT_CENTER_X;
                            center_y     <= DEFAULT_CENTER_Y;
                            step         <= DEFAULT_STEP;
                            palette_sel  <= 7'd0;
                            palette_override_active <= 1'b0;
                            iter_sel     <= 3'd5;  // Auto
                            view_changed <= 1'b1;
                            if (auto_zoom_active) auto_zoom_deactivate <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end else begin
                case (ps2_scancode)
                    // WASD pan
                    8'h1D: begin key_up       <= ps2_pressed; end
                    8'h1B: begin key_down     <= ps2_pressed; end
                    8'h1C: begin key_left     <= ps2_pressed; end
                    8'h23: begin key_right    <= ps2_pressed; end
                    // Zoom: Plus(=)/Minus
                    8'h55: begin key_zoom_in  <= ps2_pressed; end
                    8'h4A: begin key_zoom_out <= ps2_pressed; end
                    default: ;
                endcase
                // Edge-triggered actions
                if (ps2_pressed) begin
                    case (ps2_scancode)
                        8'h4D: begin // P = Cycle palette (does NOT stop auto-zoom)
                            palette_sel <= (palette_sel == 7'd89) ? 7'd0 : palette_sel + 7'd1;
                            palette_override_active <= 1'b1;
                            view_changed <= 1'b1;
                        end
                        8'h43: begin // I = Cycle iterations (0=128 .. 4=2048, 5=Auto)
                            iter_sel <= (iter_sel == 3'd5) ? 3'd0 : iter_sel + 3'd1;
                            view_changed <= 1'b1;
                        end
                        8'h18: begin // O = Toggle text overlay
                            overlay_enable <= ~overlay_enable;
                        end
                        8'h21: begin // C = Cycle color cycling mode (Auto->On->Off->Auto)
                            color_cycle_enable <= ~color_cycle_enable;
                        end
                        8'h2D: begin // R = Reset view
                            center_x     <= DEFAULT_CENTER_X;
                            center_y     <= DEFAULT_CENTER_Y;
                            step         <= DEFAULT_STEP;
                            palette_sel  <= 7'd0;
                            palette_override_active <= 1'b0;
                            iter_sel     <= 3'd5;  // Auto
                            view_changed <= 1'b1;
                            if (auto_zoom_active) auto_zoom_deactivate <= 1'b1;
                        end
                        8'h31: begin // N = Skip to next in playlist
                            if (auto_zoom_active) auto_zoom_skip_next <= 1'b1;
                        end
                        8'h32: begin // B = Toggle deterministic benchmark mode
                            benchmark_toggle <= 1'b1;
                        end
                        8'h2A: begin // V = Advance deterministic benchmark scene
                            benchmark_next <= 1'b1;
                        end
                        8'h3A: begin // M = Snap to next POI canonical view (verification mode)
                            auto_zoom_snap_next <= 1'b1;
                        end
                        8'h34: begin // G = Force overlay BG to Dimmed (verification helper)
                            key_bg_dim_on <= 1'b1;
                        end
                        8'h33: begin // H = Force overlay BG to Transparent
                            key_bg_dim_off <= 1'b1;
                        end
                        8'h42: begin // K = Force overlay blanking timer ON (text auto-hides)
                            key_blank_text_on <= 1'b1;
                        end
                        8'h4B: begin // L = Force overlay blanking timer OFF (always visible)
                            key_blank_text_off <= 1'b1;
                        end
                        8'h3B: begin // J = Toggle V-Mode 240p/480i (verification)
                            key_vmode_toggle <= 1'b1;
                        end
                        // S/A keys used to toggle Mariani-Silver, and
                        // 1/2/3/4 used to set MIN_REGION_DIM. Both dropped
                        // when MS was disabled in the shipping core (the
                        // region_manager has an intermittent hang and the
                        // diagnosed fix breaks HDMI synchronization).
                        // Re-add when MS gets a proper sim-driven debug.
                        8'h1A, // Z = Toggle auto-zoom screensaver
                        8'h29: begin // Space = Toggle auto-zoom screensaver
                            auto_zoom_toggle <= 1'b1;
                        end
                        default: ;
                    endcase
                end
            end
        end

        // Auto-repeat timer
        if (hold_up | hold_down | hold_left | hold_right | hold_zoom_in | hold_zoom_out)
            repeat_cnt <= (repeat_cnt == 20'd0) ? 20'd833333 : repeat_cnt - 20'd1;
        else
            repeat_cnt <= 20'd0;

        // ---- Pan (bounded, see VIEW_LIMIT) ----
        if (hold_right && repeat_tick && pan_right_ok) begin
            center_x <= cx_right;
            view_changed <= 1'b1;
        end
        if (hold_left && repeat_tick && pan_left_ok) begin
            center_x <= cx_left;
            view_changed <= 1'b1;
        end
        if (hold_down && repeat_tick && pan_down_ok) begin
            center_y <= cy_down;
            view_changed <= 1'b1;
        end
        if (hold_up && repeat_tick && pan_up_ok) begin
            center_y <= cy_up;
            view_changed <= 1'b1;
        end

        // ---- Zoom ----
        if (hold_zoom_out && repeat_tick) begin
            if (zoom_out_ok) begin
                step <= step_out;
                view_changed <= 1'b1;
            end
        end
        if (hold_zoom_in && repeat_tick) begin
            if (step > MIN_STEP) begin
                step <= step - step_delta;
                view_changed <= 1'b1;
            end
        end

        // ---- Face buttons ----
        if (joy_press[4]) begin // A = Cycle palette
            palette_sel <= (palette_sel == 7'd89) ? 7'd0 : palette_sel + 7'd1;
            palette_override_active <= 1'b1;
            view_changed <= 1'b1;
        end
        if (joy_press[5]) begin // B = Toggle color cycling
            color_cycle_enable <= ~color_cycle_enable;
        end
        if (joy_press[6]) begin // X = Snap to next POI canonical view (verification mode)
            auto_zoom_snap_next <= 1'b1;
        end
        if (joy_press[10]) begin // Select = Toggle text overlay
            overlay_enable <= ~overlay_enable;
        end
        if (joy_press[7]) begin // Y = Next POI
            if (auto_zoom_active) auto_zoom_skip_next <= 1'b1;
        end

        // ---- Auto-zoom toggle (only via Start button) ----
        if (joy_press[11]) begin // Start = Toggle auto-zoom
            auto_zoom_toggle <= 1'b1;
        end
    end
end

endmodule
