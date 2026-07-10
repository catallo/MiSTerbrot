//============================================================================
// MiSTerbrot Top - v0.9.0 Core Module
//
// BRAM double-buffered 320x240, DSP time-shared iter_pair iterators,
// 12-bit iteration count (up to 2048), 42 color palettes.
//
// Pipeline: input_handler -> coord_generator -> pixel_pipeline -> framebuffer
//           video_timing -> framebuffer read -> color_mapper -> VGA output
//
// Critical fix: buffer swap ONLY during VBLANK rising edge.
// Display always reads from front buffer = zero tearing.
//
// 50 MHz system clock, ce_pix pulses every 8th clock for 6.25 MHz pixel clock.
// Native 240p output (320x240 @ 15kHz). MiSTer ascaler handles upscaling.
//============================================================================

`include "benchmark_generated.vh"

module fractal_top #(
    parameter H_RES       = 320,
    parameter V_RES       = 240,
    parameter N_ITERATORS = 24,  // 4 quads x 6 contexts/quad
    parameter WIDTH       = 64,
    parameter FRAC_BITS   = 56,
    // ~1 s of progressive output before honoring a saved interlaced
    // resolution (the ARM's first mode lock fails on 480i).  Parameter
    // so TBs can shorten it; synthesis always uses the default.
    parameter [5:0] BOOT_GRACE_VBLANKS = 6'd60
)(
    input  wire        clk,       // 50 MHz (clk_sys: render, framebuffer write, control)
    input  wire        clk_iter,  // 100 MHz (iter_quad math)
    input  wire        clk_vid,   // 100 MHz video domain (physically = clk_iter;
                                  // display path: timing, fb read, color, overlay).
                                  // See docs/480P_DESIGN.md for the domain split.
    input  wire        rst_n,

    // MiSTer interface
    input  wire [15:0] joystick,
    input  wire [10:0] ps2_key,
    input  wire [127:0] status,
    input  wire [32:0] entropy_seed,

    // Video output (native 240p timing)
    output wire        ce_pix,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        vga_f1,     // ALWAYS 0: the field flag is permanently
                                   // suppressed (the scaler scales each field
                                   // as an independent progressive half-
                                   // picture; real 15 kHz displays interlace
                                   // from the half-line sync cadence, which
                                   // the video timing carries without F1)
    output wire        vga_interlaced,  // level: 480i mode active
    output wire        vga_mode_480p,   // level: 640x480p (31 kHz) active
    output reg         new_vmode,  // toggles on any resolution change (hps_io)
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,

    // DDR3 framebuffer (Track B, 640x480i): emu DDRAM_* passthrough,
    // driven by fb_ddr3.  Idle (never issues commands) outside that mode.
    output wire [28:0] ddram_addr,
    output wire [7:0]  ddram_burstcnt,
    input  wire        ddram_busy,
    input  wire [63:0] ddram_dout,
    input  wire        ddram_dout_ready,
    output wire        ddram_rd,
    output wire [63:0] ddram_din,
    output wire [7:0]  ddram_be,
    output wire        ddram_we,
    output wire        ddram_underrun,  // sticky line-fetch budget violation

    // Status
    output wire        rendering
);

// ---- Deterministic benchmark scene data ----
reg                     benchmark_active;
reg [`BENCH_IDX_BITS-1:0] benchmark_idx;
reg                     benchmark_view_changed;
reg signed [WIDTH-1:0] bench_center_x;
reg signed [WIDTH-1:0] bench_center_y;
reg signed [WIDTH-1:0] bench_step;
reg [11:0]             bench_max_iter;
reg [3:0]              bench_iter_tier;
reg [6:0]              bench_palette;
reg                    bench_mode_640;
reg                    bench_precheck_p3;  // A3 per-POI opt-in flag (BENCH_SCENE_CASES)

always @(*) begin
    case (benchmark_idx)
        `BENCH_SCENE_CASES
        default: begin
            bench_center_x = 64'shFF80000000000000;
            bench_center_y = 64'sh0000000000000000;
            bench_step     = 64'sh0003333333333333;
            bench_max_iter = 12'd512;
            bench_iter_tier = 4'd2;
            bench_palette  = 7'd0;
            bench_mode_640 = 1'b0;
            bench_precheck_p3 = 1'b0;
        end
    endcase
end

// ---- Unified resolution: 320x240 / 640x240 / 320x480i / 640x480i ----
// One OSD selector (O[55:54]); the J key cycles through the three modes
// (sticky override, same convention as the G/H/K/L keys).  Benchmark
// mode forces the per-scene 240p geometry.
// J-key override releases as soon as the OSD selection changes — the
// most recently used source wins (a sticky override made the OSD
// selector appear dead after the first keypress; found on hardware).
reg  [2:0] res_override;
reg        res_override_en;
reg  [2:0] osd_res_prev;
reg  [2:0] eff_res_prev_nv;
wire [2:0] eff_res = res_override_en ? res_override : osd_res_mode;
// Boot grace: the framework's very first mode lock after a core load
// cannot cope with an interlaced signal (PSX never boots interlaced —
// its BIOS runs 240p; found the hard way with a saved 480i setting).
// Hold 480i off for the first ~1 s so the ARM locks progressive first,
// then switch — a transition it demonstrably handles (new_vmode fires).
reg [5:0] boot_grace_cnt;
wire      boot_grace_done = (boot_grace_cnt >= BOOT_GRACE_VBLANKS);
wire interlace_mode = (eff_res == 3'd2 || eff_res == 3'd3)
                    && boot_grace_done && !benchmark_active;
// 640x480p (eff_res 4, Track B stage 2): progressive 525-line timing
// at 31.25 kHz.  Same boot-grace policy as the interlaced modes.
wire mode_480p = (eff_res == 3'd4) && boot_grace_done && !benchmark_active;
wire effective_mode_640 = benchmark_active ? bench_mode_640
                        : (eff_res == 3'd1 || eff_res == 3'd3 || eff_res == 3'd4);
// 640x480 (i or p) = 307,200 px = 2x one BRAM bank: the framebuffer
// moves to DDR3 (fb_ddr3).  During boot grace / benchmark the mode falls
// back to progressive 640x240 in BRAM, same as 320x480i falls back to
// 320x240.
wire ddr_fb_mode = ((eff_res == 3'd3) && interlace_mode)
                 || mode_480p;
// 480-line rendering (interlaced scanout or 480p): drives the coord
// ladder and the A2 symmetry bounds/mirror target below.
wire render_480 = interlace_mode | mode_480p;

// ---- Pixel clock (video domain, 100 MHz base) ----
//   320 mode: 100 MHz / 16 = 6.25 MHz dot clock (15.625 kHz line rate)
//   640 mode: 100 MHz / 8  = 12.5 MHz dot clock (15.625 kHz at 800 H_TOTAL)
// Same absolute rates as the former 50 MHz dividers; the 100 MHz base
// exists so a future 480p can run 25 MHz at the proven 4-clk cadence.
reg [3:0] ce_pix_cnt;
always @(posedge clk_vid or negedge rst_n) begin
    if (!rst_n) ce_pix_cnt <= 4'd0;
    else        ce_pix_cnt <= ce_pix_cnt + 4'd1;
end
assign ce_pix = mode_480p            ? (ce_pix_cnt[1:0] == 2'd0)
              : effective_mode_640   ? (ce_pix_cnt[2:0] == 3'd0)
                                     : (ce_pix_cnt       == 4'd0);

// ---- OSD Parameter Decoding ----
wire [6:0] osd_palette_sel;
wire [2:0] osd_iter_sel;
wire       osd_iter_changed;
wire       osd_color_cycle_enable;
wire       osd_reset;
wire       single_buffer;
wire       osd_blank_text_enable;
wire       always_show_fps;
wire       always_show_poi;
wire       osd_overlay_bg_dim;
wire       key_bg_dim_on, key_bg_dim_off;
wire       key_blank_text_on, key_blank_text_off;
wire       key_vmode_toggle;
// A3 OSD mode: 2'd0 = Auto (use per-POI flag), 2'd1 = On (force-enable),
// 2'd2 = Off (force-disable).  Decoded from status[26:25] in fractal_osd.v.
wire [1:0] osd_p3_mode;
wire       osd_periodicity_enable;
wire       attract_randomize;
wire [2:0] osd_res_mode;
wire       color_depth_mode;
wire [3:0] cycle_speed_sel;
wire [1:0] cycle_direction;
wire       cycle_blend_hard;
wire [1:0] cycle_band_mode;
wire [1:0] palette_transition_mode;
wire       zoom_pacing_mode;
wire [1:0] zoom_speed_sel;
wire       attract_zoom_in_enable;
wire       attract_zoom_out_enable;
wire [15:0] attract_wait_vblanks;

fractal_osd #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_osd (
    .clk(clk),
    .rst_n(rst_n),
    .status(status),
    .palette_sel(osd_palette_sel),
    .osd_iter_sel(osd_iter_sel),
    .osd_iter_changed(osd_iter_changed),
    .color_cycle_enable(osd_color_cycle_enable),

    .osd_reset(osd_reset),
    .single_buffer(single_buffer),
    .blank_text_enable(osd_blank_text_enable),
    .always_show_fps(always_show_fps),
    .always_show_poi(always_show_poi),
    .overlay_bg_dim(osd_overlay_bg_dim),
    .p3_mode(osd_p3_mode),
    .periodicity_enable(osd_periodicity_enable),
    .attract_randomize(attract_randomize),
    .res_mode(osd_res_mode),
    .color_depth_mode(color_depth_mode),
    .cycle_speed_sel(cycle_speed_sel),
    .cycle_direction(cycle_direction),
    .cycle_blend_hard(cycle_blend_hard),
    .cycle_band_mode(cycle_band_mode),
    .palette_transition_mode(palette_transition_mode),
    .zoom_pacing_mode(zoom_pacing_mode),
    .zoom_speed_sel(zoom_speed_sel),
    .attract_zoom_in_enable(attract_zoom_in_enable),
    .attract_zoom_out_enable(attract_zoom_out_enable),
    .attract_wait_vblanks(attract_wait_vblanks)
);

// ---- Verification-mode overrides (keys force on/off, default = follow OSD) ----
// blank_text_override: 2'b00=follow OSD, 2'b01=force OFF (always visible), 2'b10=force ON (auto-blank)
// bg_dim_override   : same encoding for the Overlay BG bit.
reg [1:0] blank_text_override;
reg [1:0] bg_dim_override;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        blank_text_override <= 2'b00;
        bg_dim_override     <= 2'b00;
        res_override        <= 3'd0;
        res_override_en     <= 1'b0;
        osd_res_prev        <= 3'd0;
        eff_res_prev_nv     <= 3'd0;
        new_vmode           <= 1'b0;
        boot_grace_cnt      <= 6'd0;
    end else begin
        if (key_blank_text_on)  blank_text_override <= 2'b10;
        if (key_blank_text_off) blank_text_override <= 2'b01;
        if (key_bg_dim_on)      bg_dim_override     <= 2'b10;
        if (key_bg_dim_off)     bg_dim_override     <= 2'b01;
        osd_res_prev <= osd_res_mode;
        if (vblank_rise && !boot_grace_done)
            boot_grace_cnt <= boot_grace_cnt + 6'd1;
        // Signal every effective-resolution change to the ARM (hps_io
        // new_vmode) so the scaler re-measures immediately — without it
        // the boot-time 240p->480i transition (saved OSD setting arrives
        // a moment after core start) leaves the scaler unlocked until
        // the user manually switches modes.  Same mechanism as PSX.
        eff_res_prev_nv <= eff_res;
        if (eff_res != eff_res_prev_nv) new_vmode <= ~new_vmode;
        if (key_vmode_toggle) begin
            res_override_en <= 1'b1;
            res_override    <= (eff_res >= 3'd4) ? 3'd0 : (eff_res + 3'd1);
        end else if (osd_res_mode != osd_res_prev) begin
            res_override_en <= 1'b0;
        end
    end
end
wire blank_text_enable = (blank_text_override == 2'b10) ? 1'b1 :
                         (blank_text_override == 2'b01) ? 1'b0 :
                         osd_blank_text_enable;
wire overlay_bg_dim    = (bg_dim_override == 2'b10) ? 1'b1 :
                         (bg_dim_override == 2'b01) ? 1'b0 :
                         osd_overlay_bg_dim;

// ---- Input Handler ----
wire signed [WIDTH-1:0] input_center_x;
wire signed [WIDTH-1:0] input_center_y;
wire signed [WIDTH-1:0] input_step;
wire [6:0]              input_palette_sel;
wire                    input_palette_override;
wire [2:0]              input_iter_sel;
wire                    overlay_enable;
wire                    color_cycle_enable;
wire                    input_view_changed;
wire                    auto_zoom_toggle;
wire                    auto_zoom_deactivate;
wire                    auto_zoom_skip_next;
wire                    auto_zoom_snap_next;
wire                    benchmark_toggle;
wire                    benchmark_next;
wire                    auto_zoom_active;
wire signed [WIDTH-1:0] az_center_x;
wire signed [WIDTH-1:0] az_center_y;
wire signed [WIDTH-1:0] az_step;
wire                    az_view_changed;
wire [6:0]              az_palette_idx;
wire [17:0]             az_fb_rd_addr;
wire                    az_fb_sampling;
wire [6:0]              az_target_idx;
wire [11:0]             az_max_iter;
wire [3:0]              az_rnd_cycle_speed;
wire [1:0]              az_rnd_cycle_direction;
reg  [6:0]              az_target_idx_prev;
reg                     az_enable;
reg                     az_enable_prev;
wire                    auto_zoom_handoff = az_enable_prev & ~az_enable;

// ---- Overlay visibility timer (6s after last input) ----
localparam [28:0] OVERLAY_SHOW_TICKS = 29'd500_000_000;  // 10s @ 50MHz
reg [28:0] overlay_timer;
reg        overlay_visible;
reg [15:0] joystick_prev;
reg        ps2_strobe_prev;
wire       overlay_wakeup = (|(joystick ^ joystick_prev)) | (ps2_key[10] != ps2_strobe_prev);

input_handler #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_input (
    .clk(clk),
    .rst_n(rst_n),
    .joystick(joystick),
    .ps2_key(ps2_key),
    .step_in(input_step),
    .center_x(input_center_x),
    .center_y(input_center_y),
    .step(input_step),
    .palette_sel(input_palette_sel),
    .palette_override_active(input_palette_override),
    .osd_iter_sel(osd_iter_sel),
    .osd_iter_changed(osd_iter_changed),
    .sync_clear_palette_override(auto_zoom_active && (az_target_idx != az_target_idx_prev)),
    .iter_sel(input_iter_sel),
    .overlay_enable(overlay_enable),
    .color_cycle_enable(color_cycle_enable),
    .view_changed(input_view_changed),
    .auto_zoom_toggle(auto_zoom_toggle),
    .auto_zoom_deactivate(auto_zoom_deactivate),
    .auto_zoom_skip_next(auto_zoom_skip_next),
    .auto_zoom_snap_next(auto_zoom_snap_next),
    .benchmark_toggle(benchmark_toggle),
    .benchmark_next(benchmark_next),
    .key_bg_dim_on(key_bg_dim_on),
    .key_bg_dim_off(key_bg_dim_off),
    .key_blank_text_on(key_blank_text_on),
    .key_blank_text_off(key_blank_text_off),
    .key_vmode_toggle(key_vmode_toggle),
    .auto_zoom_active(auto_zoom_active),
    .sync_from_auto_zoom(auto_zoom_handoff),
    .sync_center_x(az_center_x),
    .sync_center_y(az_center_y),
    .sync_step(az_step),
    .sync_palette_sel(az_palette_idx)
);

// ---- Framebuffer parameters (needed by auto_zoom and framebuffer) ----
localparam FB_ADDR_WIDTH = 18;  // ceil(log2(640*240))
// 9-bit pixels (480i prep, 2026-07-09): the display path only ever
// consumes {escaped, iter[7:0]} — the palette index wraps at 256 and
// the band-select bit is iter[7].  Storing the upper iter bits was
// legacy; dropping them frees ~120 M10K blocks (room for the third
// field bank the 480i scheme needs).
localparam FB_DATA_WIDTH = 9;   // 8-bit iter + 1-bit escaped

// ---- Auto-Zoom Screensaver ----

// Enable: toggle on Z/Space press, force off on deactivate, start enabled
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        az_enable <= 1'b1;  // Auto-start screensaver
        az_enable_prev <= 1'b1;
    end else begin
        az_enable_prev <= az_enable;
        if (benchmark_toggle && !benchmark_active)
            az_enable <= 1'b0;
        else if (auto_zoom_deactivate)
            az_enable <= 1'b0;
        else if (auto_zoom_toggle)
            az_enable <= ~az_enable;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        benchmark_active       <= 1'b0;
        benchmark_idx          <= {`BENCH_IDX_BITS{1'b0}};
        benchmark_view_changed <= 1'b0;
    end else begin
        benchmark_view_changed <= 1'b0;

        if (benchmark_toggle) begin
            benchmark_active       <= ~benchmark_active;
            benchmark_view_changed <= 1'b1;
        end

        if (benchmark_next) begin
            benchmark_idx <= (benchmark_idx == `BENCH_LAST_IDX) ?
                             {`BENCH_IDX_BITS{1'b0}} :
                             (benchmark_idx + {{(`BENCH_IDX_BITS-1){1'b0}}, 1'b1});
            if (benchmark_active)
                benchmark_view_changed <= 1'b1;
        end
    end
end

// Forward declaration: rd_data from framebuffer (declared below)
wire [FB_DATA_WIDTH-1:0] rd_data;

auto_zoom #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_auto_zoom (
    .clk(clk),
    .rst_n(rst_n),
    .enable(az_enable),
    .skip_next(auto_zoom_skip_next),
    .snap_next(auto_zoom_snap_next),
    .frame_done(vblank_rise),
    .vblank(vblank_sync_s[1]),
    .entropy_seed(entropy_seed),
    .attract_zoom_in_enable(attract_zoom_in_enable),
    .attract_zoom_out_enable(attract_zoom_out_enable),
    .attract_wait_vblanks(attract_wait_vblanks),
    .zoom_pacing_mode(zoom_pacing_mode),
    .zoom_speed_sel(zoom_speed_sel),
    .randomize_enable(attract_randomize),
    .fb_rd_data({4'd0, rd_data}),
    .fb_rd_addr(az_fb_rd_addr),
    .fb_sampling(az_fb_sampling),
    .center_x(az_center_x),
    .center_y(az_center_y),
    .step(az_step),
    .active(auto_zoom_active),
    .view_changed(az_view_changed),
    .palette_idx(az_palette_idx),
    .target_idx_out(az_target_idx),
    .target_max_iter(az_max_iter),
    .rnd_cycle_speed(az_rnd_cycle_speed),
    .rnd_cycle_direction(az_rnd_cycle_direction),
    .rnd_zoom_speed()
);

// ---- Mux: auto_zoom overrides manual when active ----
wire signed [WIDTH-1:0] center_x    = benchmark_active ? bench_center_x :
                                       auto_zoom_active ? az_center_x    : input_center_x;
wire signed [WIDTH-1:0] center_y    = benchmark_active ? bench_center_y :
                                       auto_zoom_active ? az_center_y    : input_center_y;
wire signed [WIDTH-1:0] step        = benchmark_active ? bench_step     :
                                       auto_zoom_active ? az_step        : input_step;
wire                    view_changed = benchmark_active ? benchmark_view_changed :
                                       auto_zoom_active ? az_view_changed : input_view_changed;

// OSD overrides for palette; iterations can come from OSD or keyboard.
wire       osd_palette_override = (osd_palette_sel != 7'd0);
wire [6:0] osd_palette_idx_full = osd_palette_sel - 7'd1;
wire [6:0] osd_palette_idx = osd_palette_idx_full;
wire [6:0] palette_sel  = benchmark_active     ? bench_palette :
                          osd_palette_override ? osd_palette_idx :
                          input_palette_override ? input_palette_sel :
                          auto_zoom_active       ? az_palette_idx  : input_palette_sel;
reg  [11:0] input_max_iter;
// In benchmark mode, the per-scene `bench_max_iter` from the catalogue
// is used UNLESS the OSD Iterations setting is anything other than Auto
// (input_iter_sel != 3'd5).  This lets an automated profiling pass
// sweep through {128, 256, 512, 1024, 2048} for every scene by simply
// toggling the OSD setting between bench runs — no per-scene catalogue
// edit needed for the profiling itself.  See `tools/profile_max_iter.py`.
wire [11:0] max_iter = (benchmark_active && input_iter_sel == 3'd5)
                       ? bench_max_iter   // bench + OSD-Auto: per-scene catalogue value
                       : input_max_iter;  // otherwise: OSD-driven (Auto-ladder or fixed)
reg  [6:0] palette_sel_prev;
reg  [11:0] max_iter_prev;
reg         mode_640_prev;
reg         interlace_prev;
wire settings_changed = (palette_sel != palette_sel_prev) ||
                        (max_iter != max_iter_prev) ||
                        (effective_mode_640 != mode_640_prev) ||
                        (interlace_mode != interlace_prev);

// Auto-iter: scale max_iter with zoom depth so deep zooms don't render solid
// black for lack of iterations. Tiers match tools/poi_render.max_iter_for_zoom.
localparam signed [WIDTH-1:0] FT_DEFAULT_STEP = 64'sh0003333333333333;
wire signed [WIDTH-1:0] step_z12 = FT_DEFAULT_STEP >>> 12;
wire signed [WIDTH-1:0] step_z18 = FT_DEFAULT_STEP >>> 18;
wire signed [WIDTH-1:0] step_z24 = FT_DEFAULT_STEP >>> 24;
wire [11:0] auto_max_iter = (step >= step_z12) ? 12'd512  :  // floor: never below 512
                            (step >= step_z18) ? 12'd1024 :
                            (step >= step_z24) ? 12'd2048 :
                                                 12'd4095;

// When auto-zoom is locked on a target POI and the OSD is set to Auto,
// prefer the per-POI max_iter from rtl/poi_generated.vh (sourced from
// tools/poi_master.json max_iter override) over the step-based ladder.
// Falls back to the ladder for manual zoom or OSD=Auto without a POI.
wire [11:0] auto_iter_choice = auto_zoom_active ? az_max_iter : auto_max_iter;
always @(*) begin
    case (input_iter_sel)
        3'd0:    input_max_iter = 12'd128;
        3'd1:    input_max_iter = 12'd256;
        3'd2:    input_max_iter = 12'd512;
        3'd3:    input_max_iter = 12'd1024;
        3'd4:    input_max_iter = 12'd2048;
        default: input_max_iter = auto_iter_choice;  // 3'd5 = Auto
    endcase
end

localparam [24:0] FPS_SAMPLE_TICKS = 25'd25000000;

// ======================================================================
// DOUBLE-BUFFER CONTROL
// ======================================================================
// bank_sel: 0 = display A / render B, 1 = display B / render A
// Swap ONLY on VBLANK rising edge after frame completes = zero tearing.
// ======================================================================

reg  bank_sel;
reg  frame_complete;  // Latched on frame_done, cleared on swap
reg  swap_pending;    // Bank-swap requested at vblank_rise, deferred
                      // until the A2 mirror FIFO drains (symq_empty)
wire frame_done;
reg  frame_done_prev;
wire frame_done_rise;
reg [24:0] fps_tick_counter;
reg [6:0]  fps_halfsec_count;
reg [6:0]  fps_value;
wire [6:0] fps_sample_count = fps_halfsec_count + {6'd0, frame_done_rise};
wire [6:0] fps_sample_value = {fps_sample_count[5:0], 1'b0};

// VBLANK crossing into the render/control domain (vblank is generated
// in clk_vid since the video-domain move): 2FF sync + edge detect.
// All clk-domain consumers (bank swap, boot grace, attract pacing,
// benchmark windows) use this synced copy; the 2-3 clock latency is
// nothing against 22+ blank lines.
reg [1:0] vblank_sync_s;
reg vblank_prev;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vblank_sync_s <= 2'b00;
        vblank_prev   <= 1'b0;
    end else begin
        vblank_sync_s <= {vblank_sync_s[0], vblank};
        vblank_prev   <= vblank_sync_s[1];
    end
end
wire vblank_rise = vblank_sync_s[1] & ~vblank_prev;
assign frame_done_rise = frame_done & ~frame_done_prev;

// Mirror-write FIFO empty flag (driven in the A2 symmetry block below).
// Forward-declared here so the bank-swap state machine can wait on it.
wire symq_empty;
// Backpressure on coord_generator dispatch when FIFO is near-full.
// Also forward-declared; assigned in the FIFO section.
wire symq_backpressure;

// Bank swap state machine
//
// Two-step: vblank_rise + frame_complete sets `swap_pending`; the
// actual bank toggle defers until the mirror-write FIFO has drained
// (symq_empty).  Otherwise late mirror writes would land on the
// freshly-toggled bank — which is the previous front-bank that's
// still being scanned out — causing visible corruption.  VBLANK is
// thousands of cycles long, the FIFO drains in ≤32, so deferring
// inside the same VBLANK is always safe.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bank_sel        <= 1'b0;
        frame_complete  <= 1'b0;
        frame_done_prev <= 1'b0;
        swap_pending    <= 1'b0;
    end else begin
        frame_done_prev <= frame_done;

        if (frame_done_rise)
            frame_complete <= 1'b1;

        if (vblank_rise && (frame_complete || frame_done_rise))
            swap_pending <= 1'b1;

        if (swap_pending && symq_empty) begin
            bank_sel       <= ~bank_sel;
            frame_complete <= 1'b0;
            swap_pending   <= 1'b0;
        end
    end
end

// ---- FPS Counter ----
// Sample completed render frames over 500 ms, then double for FPS.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fps_tick_counter  <= 25'd0;
        fps_halfsec_count <= 7'd0;
        fps_value         <= 7'd0;
    end else begin
        if (frame_done_rise)
            fps_halfsec_count <= fps_halfsec_count + 7'd1;

        if (fps_tick_counter == FPS_SAMPLE_TICKS - 25'd1) begin
            fps_tick_counter  <= 25'd0;
            fps_value         <= fps_sample_value;
            fps_halfsec_count <= frame_done_rise ? 7'd1 : 7'd0;
        end else begin
            fps_tick_counter <= fps_tick_counter + 25'd1;
        end
    end
end

// ---- Render Control ----
// State machine: IDLE -> RENDER -> WAIT_SWAP -> (RENDER or IDLE)
localparam [1:0] RS_IDLE      = 2'd0,
                 RS_RENDER    = 2'd1,
                 RS_WAIT_SWAP = 2'd2;

reg [1:0] render_state;
reg       start_render;
reg       need_rerender;  // Latches view_changed during render/wait

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        render_state <= RS_RENDER;
        start_render <= 1'b1;  // Render first frame on startup
        need_rerender <= 1'b0;
        az_target_idx_prev <= 7'd0;
        palette_sel_prev  <= 7'd0;
        max_iter_prev     <= 12'd512;
        mode_640_prev     <= 1'b0;
        interlace_prev    <= 1'b0;
    end else begin
        start_render <= 1'b0;
        az_target_idx_prev <= az_target_idx;
        palette_sel_prev  <= palette_sel;
        max_iter_prev     <= max_iter;
        mode_640_prev     <= effective_mode_640;
        interlace_prev    <= interlace_mode;

        // Latch view changes during render or wait
        if ((view_changed || settings_changed) && render_state != RS_IDLE)
            need_rerender <= 1'b1;

        case (render_state)
        RS_IDLE: begin
            if (view_changed || settings_changed || need_rerender) begin
                start_render  <= 1'b1;
                need_rerender <= 1'b0;
                render_state  <= RS_RENDER;
            end
        end

        RS_RENDER: begin
            if (frame_done) begin
                // Always wait for VBLANK before restarting. Skipping vsync
                // here (the previous "bench mode raw throughput" hack) broke
                // the MiSTer HDMI scaler and the on-disk screenshot capture
                // — both lock to the framebuffer's vsync edge. Analog video
                // bypasses the scaler so it kept working, but losing HDMI +
                // screenshots kills the bench_decode_screenshot.py loop.
                // Side effect: F10 caps at 596 (~60 fps) on fast scenes.
                // That's an acceptable trade for an end-to-end working
                // benchmark pipeline.
                render_state <= RS_WAIT_SWAP;
            end
        end

        RS_WAIT_SWAP: begin
            // Wait for the bank swap to actually happen before starting the
            // next render — the swap is gated on the A2 mirror FIFO being
            // empty (see swap_pending logic above), so we wait on that same
            // condition here to stay in lockstep.
            if (swap_pending && symq_empty) begin
                if (view_changed || settings_changed || need_rerender ||
                    benchmark_active) begin
                    // benchmark_active forces a continuous re-render so F10
                    // measures sustained throughput. Capped at vsync (~60 Hz)
                    // because we removed the vsync bypass — see the comment
                    // in RS_RENDER above.
                    start_render  <= 1'b1;
                    need_rerender <= 1'b0;
                    render_state  <= RS_RENDER;
                end else begin
                    render_state <= RS_IDLE;
                end
            end
        end

        default: render_state <= RS_IDLE;
        endcase
    end
end

assign rendering = (render_state == RS_RENDER);

// ---- Pixel Pipeline ----
wire        pipe_result_valid;
wire [10:0] pipe_result_x;
wire [9:0]  pipe_result_y;
wire [11:0] pipe_result_iter;
wire        pipe_result_escaped;

// Mariani-Silver toggle (OSD bit 25). When 0, the classic coord_generator
// Mariani-Silver was attempted (region_manager.v + S/A keys + OSD toggle)
// but exhibited an intermittent hang at MR=16 (most reliable) and at
// MR=64/128/sometimes-32 (less so). The diagnosed root-cause fix breaks
// HDMI synchronization on the MiSTer scaler. Until we can debug it
// properly with simulation (see docs/SIMULATION.md), MS is disabled in
// the shipping core. region_manager.v stays in the tree for future work.
// See docs/MR16_HANG_REPORT.md / _V2.md and MR16_HANG_CHATGPT_PRO_V2.md
// for the investigation transcript.

// ---- Real-axis symmetry detection (A2) ----
// Mandelbrot is symmetric across ci = 0.  When the view is centred on
// the real axis (center_y == 0), we can compute only rows 0..119 and
// mirror-write rows 120..239 — exact 2.00× speedup on applicable POIs.
//
// With the half-step ci grid shift in coord_generator (rows have
// ci = (Y - 119.5)*step + center_y), the symmetry axis lies *between*
// rows 119 and 120.  Mirror pairs are (0↔239), (1↔238), …, (119↔120).
// No special-case axis row.
//
// Latched at start_render so it can't change mid-frame (auto_zoom drift
// could otherwise change center_y between scan and finish).
//
// Strict equality `== 0` is intentional: catalogue real-axis POIs use
// exactly 0.  As soon as auto-zoom drifts to non-zero, sym_active goes
// false and we render the full frame — no risk of asymmetric corruption
// when center_y is "almost" 0.
wire cy_is_zero       = (center_y == {WIDTH{1'b0}});
reg  sym_active_frame;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)             sym_active_frame <= 1'b0;
    else if (start_render)  sym_active_frame <= cy_is_zero;
end

// ---- Coord source: classic raster-order generator (only source) ----
wire                    cg_valid, cg_ready;
wire [10:0]             cg_px;
wire [9:0]              cg_py;
wire signed [WIDTH-1:0] cg_cr, cg_ci;
wire                    cg_frame_done;

coord_generator #(
    .WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)
) u_coord_gen (
    .clk(clk), .rst_n(rst_n),
    .mode_640(effective_mode_640),
    .mode_480(render_480),
    .start_frame(start_render),
    // Raw cy_is_zero, NOT sym_active_frame: coord_generator latches its
    // own copy at start_frame — the same edge sym_active_frame latches.
    // Feeding it the registered flag gave it the PREVIOUS frame's value,
    // so on a sym→non-sym POI transition the scan stopped at row 119
    // while the mirror logic (correctly) didn't mirror — one frame with
    // a stale bottom half.  Both latching cy_is_zero at the same edge
    // keeps scan range and mirror writes in lockstep.
    .symmetry_active(cy_is_zero),
    .center_x(center_x), .center_y(center_y), .step(step),
    .ready(cg_ready), .valid(cg_valid),
    .pixel_x(cg_px), .pixel_y(cg_py),
    .cr(cg_cr), .ci(cg_ci), .frame_done(cg_frame_done)
);

// ---- Pipeline coord port — direct pass-through from coord_generator ----
localparam RID_W = 1;
// Backpressure on the dispatch handshake when the mirror FIFO is
// approaching full.  Pipeline can sustain result_valid=1 indefinitely
// on fast scenes (precheck-heavy), and during pipe_result_valid=1 the
// FIFO drain is blocked (mirror_drain = !pipe_result_valid &&
// !symq_empty).  Without backpressure the FIFO eventually overflows
// on any sustained-fast workload.
//
// Both sides of the valid/ready handshake must be gated together —
// gating only cg_ready holds coord_generator at the current pixel,
// but the pipeline (which doesn't see cg_ready) keeps finding free
// slots in its round-robin walk and redispatches the *held* pixel
// into each of them.  With N_ITERATORS=24, that's up to 24 redundant
// dispatches of the same pixel, each enqueueing its own mirror →
// FIFO overflow regardless of the threshold.  Discovered 2026-05-16
// after the first sweep with the sym_overflow flag set on all 86
// scenes.
//
// `symq_backpressure` is forward-declared near the top of the module
// and assigned in the FIFO section below.
wire                    pipe_coord_valid       = cg_valid && !symq_backpressure;
wire [10:0]             pipe_coord_px          = cg_px;
wire [9:0]              pipe_coord_py          = cg_py;
wire signed [WIDTH-1:0] pipe_coord_cr          = cg_cr;
wire signed [WIDTH-1:0] pipe_coord_ci          = cg_ci;
wire [RID_W-1:0]        pipe_coord_region_id   = {RID_W{1'b0}};
wire                    pipe_coord_frame_done  = cg_frame_done;
wire                    pipe_coord_ready;
wire [RID_W-1:0]        pipe_result_region_id;
// In DDR3 mode the write FIFO adds a third backpressure source; its
// wr_ready threshold leaves headroom for the ~24 in-flight slot results
// that keep completing after dispatch stalls.
assign cg_ready = pipe_coord_ready && !symq_backpressure
                && (ddr_wr_ready || !ddr_fb_mode);

// A3 (period-3 bulb precheck) per-frame enable.  Three sources, OSD wins:
//   osd_p3_mode = 2'd0 (Auto) → use the per-POI bench flag in benchmark
//                                mode; default off otherwise (no per-POI
//                                data outside benchmark scenes yet)
//   osd_p3_mode = 2'd1 (On)   → force-enable for all scenes
//   osd_p3_mode = 2'd2 (Off)  → force-disable for all scenes
wire p3_precheck_enable = (osd_p3_mode == 2'd1) ? 1'b1 :
                          (osd_p3_mode == 2'd2) ? 1'b0 :
                          (benchmark_active ? bench_precheck_p3 : 1'b0);

pixel_pipeline #(
    .N_ITERATORS(N_ITERATORS),
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS),
    .RID_W(RID_W)
) u_pipeline (
    .clk(clk),
    .clk_iter(clk_iter),
    .rst_n(rst_n),
    .frame_done(frame_done),
    .max_iter(max_iter),
    .p3_precheck_enable(p3_precheck_enable),
    .periodicity_enable(osd_periodicity_enable),
    .coord_valid(pipe_coord_valid),
    .coord_ready(pipe_coord_ready),
    .coord_px(pipe_coord_px),
    .coord_py(pipe_coord_py),
    .coord_cr(pipe_coord_cr),
    .coord_ci(pipe_coord_ci),
    .coord_region_id(pipe_coord_region_id),
    .coord_frame_done(pipe_coord_frame_done),
    .result_valid(pipe_result_valid),
    .result_x(pipe_result_x),
    .result_y(pipe_result_y),
    .result_iter(pipe_result_iter),
    .result_escaped(pipe_result_escaped),
    .result_region_id(pipe_result_region_id)
);

// ---- Benchmark counters ----
// Benchmark mode continuously re-renders the static scene, so the 10-second
// window counter measures sustained throughput without relying on screenshot
// timing.
localparam [28:0] BENCH_WINDOW_TICKS = 29'd500_000_000; // 10s @ 50 MHz

reg [28:0]                bench_window_ticks;
reg [15:0]                bench_window_frames;
reg [15:0]                last_bench_window_frames;
// Scene-change detection — reset the F10 window when the scene advances so
// each scene gets a clean, full 10-second window after V. Otherwise the
// tumbling window can straddle a scene transition and report a mix of old
// + new frames.
reg [`BENCH_IDX_BITS-1:0] bench_idx_prev;
wire                      bench_scene_changed =
                              benchmark_active && (benchmark_idx != bench_idx_prev);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bench_window_ticks          <= 29'd0;
        bench_window_frames         <= 16'd0;
        last_bench_window_frames    <= 16'd0;
        bench_idx_prev              <= {`BENCH_IDX_BITS{1'b0}};
    end else begin
        bench_idx_prev <= benchmark_idx;
        if (!benchmark_active || bench_scene_changed) begin
            bench_window_ticks       <= 29'd0;
            bench_window_frames      <= 16'd0;
            last_bench_window_frames <= 16'd0;
        end else if (bench_window_ticks == BENCH_WINDOW_TICKS - 29'd1) begin
            bench_window_ticks       <= 29'd0;
            last_bench_window_frames <= bench_window_frames + {15'd0, frame_done_rise};
            bench_window_frames      <= 16'd0;
        end else begin
            bench_window_ticks <= bench_window_ticks + 29'd1;
            if (frame_done_rise)
                bench_window_frames <= bench_window_frames + 16'd1;
        end
    end
end

// ---- Mirror-write FIFO (real-axis symmetry, A2) ----
// When sym_active_frame, every pipeline result for row y in [0..119]
// also needs a mirror write to row (239-y).  The framebuffer has a
// single write port per bank, so we serialise: original on the cycle
// pipe_result_valid asserts, mirror drains when no original is
// pending.
//
// Sizing: pipeline result rate ~0.28/cycle average (24 iterators,
// hundreds of cycles per pixel), so steady-state enqueue rate (with
// mirroring) is ~0.56/cycle — well under the 1/cycle drain rate.
// Worst-case burst: collect FSM walks 24 consecutive done slots,
// queueing 24 mirrors before pipeline goes quiet for at least the
// next-batch-completion time.  Depth 32 absorbs that with margin.
//
// Flushed on start_render — pending mirrors from a now-stale frame
// must not bleed into the new one.
localparam SYMQ_DEPTH = 32;
localparam SYMQ_AW    = 5;   // log2(SYMQ_DEPTH)
reg [10:0] symq_x    [0:SYMQ_DEPTH-1];
reg [9:0]  symq_y    [0:SYMQ_DEPTH-1];
reg [11:0] symq_iter [0:SYMQ_DEPTH-1];
reg        symq_esc  [0:SYMQ_DEPTH-1];
reg [SYMQ_AW:0] symq_wr_ptr, symq_rd_ptr;  // 1 extra bit for full/empty

assign symq_empty = (symq_wr_ptr == symq_rd_ptr);  // wire fwd-declared above
wire symq_full   = (symq_wr_ptr[SYMQ_AW-1:0] == symq_rd_ptr[SYMQ_AW-1:0]) &&
                   (symq_wr_ptr[SYMQ_AW]     != symq_rd_ptr[SYMQ_AW]);

// Number of entries currently in the FIFO (0..SYMQ_DEPTH).
// Two's-complement subtract on the (SYMQ_AW+1)-bit pointers gives the
// correct count even across the wrap (the wrap bit makes the difference
// negative, which interprets correctly as DEPTH+ when masked).
wire [SYMQ_AW:0] symq_count = symq_wr_ptr - symq_rd_ptr;

// Backpressure threshold: stop dispatching new work when the FIFO has
// no room left for every in-flight iterator to enqueue its mirror after
// dispatch stops.  At DEPTH=32, N_ITERATORS=24 → threshold 8.  When
// sym is off, FIFO stays empty so backpressure never fires.
assign symq_backpressure = sym_active_frame &&
                           (symq_count >= (SYMQ_DEPTH - N_ITERATORS));

wire need_mirror_now = sym_active_frame &&
                       (pipe_result_y <= (render_480 ? 10'd239 : 10'd119));
wire mirror_drain    = !pipe_result_valid && !symq_empty
                     && (ddr_wr_ready || !ddr_fb_mode);

wire [10:0] mirror_x    = symq_x   [symq_rd_ptr[SYMQ_AW-1:0]];
wire [9:0]  mirror_y    = symq_y   [symq_rd_ptr[SYMQ_AW-1:0]];
wire [11:0] mirror_iter = symq_iter[symq_rd_ptr[SYMQ_AW-1:0]];
wire        mirror_esc  = symq_esc [symq_rd_ptr[SYMQ_AW-1:0]];

// Sticky overflow flag — set if a mirror write was ever silently
// dropped because the FIFO was full.  Statistically should never fire
// (depth 32 vs ~24 worst-case burst), but a silent visual glitch
// would be otherwise invisible to debug.  Surfaced in the benchmark
// telemetry strip (bit 27) so a bench sweep would catch it.
// Sticky for the lifetime of a power cycle; reset only via rst_n.
reg sym_overflow_sticky;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sym_overflow_sticky <= 1'b0;
    end else if (pipe_result_valid && need_mirror_now && symq_full) begin
        sym_overflow_sticky <= 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        symq_wr_ptr <= {(SYMQ_AW+1){1'b0}};
        symq_rd_ptr <= {(SYMQ_AW+1){1'b0}};
        // FIFO entries are not reset — rd_ptr starts at 0 and only ever
        // reads slots that were previously written, so initial garbage is
        // never observed.  Skipping reset saves ~50 FFs of dead silicon.
    end else if (start_render) begin
        // Frame restart — discard pending mirror writes from the
        // aborted frame; they'd land in the wrong bank or wrong rows.
        symq_wr_ptr <= {(SYMQ_AW+1){1'b0}};
        symq_rd_ptr <= {(SYMQ_AW+1){1'b0}};
    end else begin
        if (pipe_result_valid && need_mirror_now && !symq_full) begin
            symq_x   [symq_wr_ptr[SYMQ_AW-1:0]] <= pipe_result_x;
            symq_y   [symq_wr_ptr[SYMQ_AW-1:0]] <= (render_480 ? 10'd479 : 10'd239)
                                                   - pipe_result_y;
            symq_iter[symq_wr_ptr[SYMQ_AW-1:0]] <= pipe_result_iter;
            symq_esc [symq_wr_ptr[SYMQ_AW-1:0]] <= pipe_result_escaped;
            symq_wr_ptr <= symq_wr_ptr + 1'b1;
        end
        if (mirror_drain) begin
            symq_rd_ptr <= symq_rd_ptr + 1'b1;
        end
    end
end

// ---- Framebuffer ----
// Write addr: y*H_RES + x.
//   320 mode: y*320 + x = (y<<8) + (y<<6) + x
//   640 mode: y*640 + x = (y<<9) + (y<<7) + x
// Two write sources, muxed:
//   1. pipe_result_valid → original write (priority on its cycle)
//   2. mirror FIFO drain → row-mirrored write when pipeline idle
wire [10:0] fb_wr_pixel_x = pipe_result_valid ? pipe_result_x       : mirror_x;
wire [9:0]  fb_wr_pixel_y = pipe_result_valid ? pipe_result_y       : mirror_y;
wire [11:0] fb_wr_iter    = pipe_result_valid ? pipe_result_iter    : mirror_iter;
wire        fb_wr_escaped = pipe_result_valid ? pipe_result_escaped : mirror_esc;
wire        fb_wr_en      = pipe_result_valid | mirror_drain;

wire [FB_ADDR_WIDTH-1:0] wr_y = {9'd0, fb_wr_pixel_y[8:0]};
wire [FB_ADDR_WIDTH-1:0] wr_x = {7'd0, fb_wr_pixel_x[10:0]};
wire [FB_ADDR_WIDTH-1:0] wr_addr = effective_mode_640
                                   ? ((wr_y << 9) + (wr_y << 7) + wr_x)
                                   : ((wr_y << 8) + (wr_y << 6) + wr_x);
wire [FB_DATA_WIDTH-1:0] wr_data = {fb_wr_escaped, fb_wr_iter[7:0]};

// Read address: same formula
wire [10:0] vid_pixel_x;
wire [9:0]  vid_pixel_y;

// Clamp x and y to the active region — outside, force address 0 to avoid
// out-of-bounds BRAM reads during hblank/vblank that could leak through
// the 1-cycle BRAM-read latency into the next active pixel.
wire vid_in_range = (vid_pixel_y < (mode_480p ? 10'd480 : 10'd240)) &&
                    (vid_pixel_x < (effective_mode_640 ? 11'd640 : 11'd320));
// 480i scanout: display row r of field f shows logical row 2r+f of the
// progressive 320x480 frame in the bank.
wire [9:0] scan_row = interlace_mode ? {vid_pixel_y[8:0], vid_field}
                                     : vid_pixel_y;
wire [FB_ADDR_WIDTH-1:0] rd_y = {8'd0, scan_row};
wire [FB_ADDR_WIDTH-1:0] rd_x = {7'd0, vid_pixel_x[10:0]};
wire [FB_ADDR_WIDTH-1:0] vid_rd_addr_raw = effective_mode_640
                                       ? ((rd_y << 9) + (rd_y << 7) + rd_x)
                                       : ((rd_y << 8) + (rd_y << 6) + rd_x);
wire [FB_ADDR_WIDTH-1:0] vid_rd_addr = vid_in_range ? vid_rd_addr_raw
                                                    : {FB_ADDR_WIDTH{1'b0}};

// Mux read address: auto_zoom sampling during VBLANK, video display otherwise
wire [FB_ADDR_WIDTH-1:0] rd_addr = az_fb_sampling ? az_fb_rd_addr : vid_rd_addr;

// ---- Video-domain synchronizers ----
// Quasi-static controls crossing into clk_vid (see 480P_DESIGN.md).
// bank_sel toggles deep inside vblank, so the 2FF latency can never
// race an active-area read; the others change on OSD/key events.
reg [1:0] bank_sel_vs, single_buf_vs, ddr_mode_vs, m480p_vs;
always @(posedge clk_vid or negedge rst_n) begin
    if (!rst_n) begin
        bank_sel_vs   <= 2'b00;
        single_buf_vs <= 2'b00;
        ddr_mode_vs   <= 2'b00;
        m480p_vs      <= 2'b00;
    end else begin
        bank_sel_vs   <= {bank_sel_vs[0], bank_sel};
        single_buf_vs <= {single_buf_vs[0], single_buffer};
        ddr_mode_vs   <= {ddr_mode_vs[0], ddr_fb_mode};
        m480p_vs      <= {m480p_vs[0], mode_480p};
    end
end
wire bank_sel_v    = bank_sel_vs[1];
wire ddr_fb_mode_v = ddr_mode_vs[1];
wire mode_480p_v   = m480p_vs[1];
wire display_bank_sel_v = single_buf_vs[1] ? ~bank_sel_v : bank_sel_v;

// vblank edge, video-domain native (for color_mapper's cycling state)
reg vblank_prev_v;
always @(posedge clk_vid or negedge rst_n) begin
    if (!rst_n) vblank_prev_v <= 1'b0;
    else        vblank_prev_v <= vblank;
end
wire vblank_rise_v = vblank & ~vblank_prev_v;

framebuffer #(
    .DATA_WIDTH(FB_DATA_WIDTH),
    .ADDR_WIDTH(FB_ADDR_WIDTH)
) u_framebuffer (
    .clk(clk),
    .rd_clk(clk_vid),
    .wr_en(fb_wr_en & ~ddr_fb_mode),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_addr(rd_addr),
    .rd_data(rd_data),
    .bank_sel(bank_sel),
    .display_bank_sel(display_bank_sel_v)
);

// ---- DDR3 framebuffer (Track B): serves 640x480i only ----
// Same 9-bit pixels, same whole-frame bank swap.  Each write FIFO entry
// captures its target bank at push time, so the swap needs no drain
// gating: late writes of frame N land in N's bank even after the swap,
// and the first display fetch of that bank comes >=1 line (64 us) after
// the swap while the FIFO drains in ~5 us.  The Buffer OSD option
// (single) is ignored in this mode — behaves as Double.
wire        ddr_wr_ready, ddr_wr_idle, ddr_line_busy;
wire [8:0]  ddr_rd_data;
wire        vt_prefetch_req;
wire [9:0]  vt_prefetch_row;

fb_ddr3 u_fb_ddr3 (
    .clk(clk),
    .clk_vid(clk_vid),
    .rst_n(rst_n),
    .wr_en(fb_wr_en & ddr_fb_mode),
    .wr_x(fb_wr_pixel_x),
    .wr_y(fb_wr_pixel_y),
    .wr_data(wr_data),
    .render_bank(bank_sel),
    .wr_ready(ddr_wr_ready),
    .wr_idle(ddr_wr_idle),
    .line_req(vt_prefetch_req & ddr_fb_mode_v),
    .line_row(vt_prefetch_row),
    .line_busy(ddr_line_busy),
    .rd_x(vid_in_range ? vid_pixel_x[9:0] : 10'd0),
    .rd_data(ddr_rd_data),
    .underrun_sticky(ddram_underrun),
    .ddram_addr(ddram_addr),
    .ddram_burstcnt(ddram_burstcnt),
    .ddram_busy(ddram_busy),
    .ddram_dout(ddram_dout),
    .ddram_dout_ready(ddram_dout_ready),
    .ddram_rd(ddram_rd),
    .ddram_din(ddram_din),
    .ddram_be(ddram_be),
    .ddram_we(ddram_we)
);
wire unused_ddr = &{1'b0, ddr_wr_idle, ddr_line_busy};

// ---- Video Timing ----
wire vid_active;
reg  vid_active_d;
reg [10:0] vid_pixel_x_d;
reg [9:0]  vid_pixel_y_d;

wire vid_field;
video_timing u_video_timing (
    .clk(clk_vid),
    .rst_n(rst_n),
    .ce_pix(ce_pix),
    .mode_640(effective_mode_640),
    .interlace(interlace_mode),
    .mode_480p(mode_480p),
    .hsync(hsync),
    .vsync(vsync),
    .hblank(hblank),
    .vblank(vblank),
    .active(vid_active),
    .pixel_x(vid_pixel_x),
    .pixel_y(vid_pixel_y),
    .field(vid_field),
    .prefetch_req(vt_prefetch_req),
    .prefetch_row(vt_prefetch_row)
);
// Field flag permanently suppressed (former Deinterlace=Off, now the
// only mode — user call 2026-07-11): weave combs on motion and bob
// shimmers; scaling each field independently is the clean scaler
// behavior for this content.  Native 15 kHz interlace lives in the
// half-line sync cadence, not in F1.  status[58:57] are free again.
assign vga_f1 = 1'b0;
assign vga_interlaced = interlace_mode;
assign vga_mode_480p  = mode_480p;

always @(posedge clk_vid or negedge rst_n) begin
    if (!rst_n) begin
        vid_active_d  <= 1'b0;
        vid_pixel_x_d <= 11'd0;
        vid_pixel_y_d <= 10'd0;
    end else if (ce_pix) begin
        vid_active_d  <= vid_active;
        vid_pixel_x_d <= vid_pixel_x;
        vid_pixel_y_d <= vid_pixel_y;
    end
end

// ---- Color Mapping (display path) ----
// Pixel source mux: BRAM banks for 240p/320x480i, DDR3 line buffer for
// 640x480i.  Both have 1-cycle read latency, so downstream timing is
// identical.
wire        fb_escaped = ddr_fb_mode_v ? ddr_rd_data[8]   : rd_data[8];
wire [11:0] fb_iter    = {4'd0, ddr_fb_mode_v ? ddr_rd_data[7:0]
                                              : rd_data[7:0]};

wire [7:0] disp_r, disp_g, disp_b;
wire [7:0] overlay_r, overlay_g, overlay_b;
// Color Cycling: unified mode from keyboard (OSD also sets same values)
// 0=Auto (on during auto-zoom), 1=On, 2=Off
// Color cycling is force-disabled in benchmark mode for deterministic
// frame output — every sweep capture of the same scene must produce
// pixel-identical results so the analyze_max_iter.py per-POI grids
// can be visually compared and the structural diff stays clean.
// (Cycling phase otherwise rotates the escape-pixel palette indices
// every frame, making same-scene captures from different sweeps look
// totally different even though the underlying iter classification is
// identical.)  Normal manual/auto-zoom use is unaffected.
wire       effective_color_cycle_enable = osd_color_cycle_enable
                                        & color_cycle_enable
                                        & ~benchmark_active;

color_mapper u_color_mapper (
    .clk(clk_vid),
    .rst_n(rst_n),
    .vblank_rise(vblank_rise_v),
    // Keep the RGB pipeline warm through blanking. During blanking the read
    // address is clamped to pixel 0, so the first visible clocks of the next
    // line no longer expose the previous line's held color.
    .pixel_valid_in(ce_pix),
    .iter_count(fb_iter),
    .escaped(fb_escaped),
    .palette_sel(palette_sel),
    .cycle_enable(effective_color_cycle_enable),
    .cycle_speed_sel((attract_randomize && auto_zoom_active) ? az_rnd_cycle_speed : cycle_speed_sel),
    .cycle_direction((attract_randomize && auto_zoom_active) ? az_rnd_cycle_direction : cycle_direction),
    .cycle_blend_hard(cycle_blend_hard),
    .cycle_band_mode(cycle_band_mode),
    .palette_transition_mode(palette_transition_mode),
    .pixel_valid_out(),
    .color_r(disp_r),
    .color_g(disp_g),
    .color_b(disp_b)
);

text_overlay #(
    .WIDTH(WIDTH),
    .FRAC_BITS(FRAC_BITS)
) u_text_overlay (
    .clk(clk_vid),
    .mode_640(effective_mode_640),
    .overlay_enable(overlay_enable),
    .overlay_visible(overlay_visible),
    .blank_text_enable(blank_text_enable),
    .always_show_fps(always_show_fps),
    .always_show_poi(always_show_poi),
    .overlay_bg_dim(overlay_bg_dim),
    .pixel_x(vid_pixel_x_d),
    // 480p scans 480 native rows; halving keeps the glyph layout (and
    // its doubled-line look) identical to all other modes
    .pixel_y(mode_480p_v ? {1'b0, vid_pixel_y_d[9:1]} : vid_pixel_y_d),
    .video_active(vid_active_d),
    .palette_sel(palette_sel),
    .max_iter(max_iter),
    .iter_auto_mode(input_iter_sel == 3'd5),
    .fps_value(fps_value),
    .center_x(center_x),
    .center_y(center_y),
    .step(step),
    .auto_zoom_active(auto_zoom_active),
    .color_cycle_active(effective_color_cycle_enable),
    .color_cycle_mode(2'd0),  // no more 3-mode display
    .target_idx(az_target_idx),
    .benchmark_active(benchmark_active),
    .benchmark_idx(benchmark_idx),
    .in_r(disp_r),
    .in_g(disp_g),
    .in_b(disp_b),
    .out_r(overlay_r),
    .out_g(overlay_g),
    .out_b(overlay_b)
);

// ---- Overlay visibility timer state machine ----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        overlay_timer <= OVERLAY_SHOW_TICKS;
        overlay_visible <= 1'b1;
        joystick_prev <= 16'd0;
        ps2_strobe_prev <= 1'b0;
    end else begin
        joystick_prev <= joystick;
        ps2_strobe_prev <= ps2_key[10];
        if (overlay_wakeup) begin
            overlay_timer <= OVERLAY_SHOW_TICKS;
            overlay_visible <= 1'b1;
        end else if (overlay_timer != 29'd0) begin
            overlay_timer <= overlay_timer - 29'd1;
        end else if (blank_text_enable) begin
            overlay_visible <= 1'b0;
        end else begin
            overlay_visible <= 1'b1;  // blank disabled = always visible
        end
    end
end

// VGA output
// In benchmark mode, encode machine-readable telemetry into 32 tiny 4x4
// color blocks at the top-left:
//   bits 31..28 = magic A
//   bits 27     = sym_overflow_sticky (A2 mirror FIFO ever overflowed)
//   bits 26..23 = spare
//   bits 22..16 = scene index (7 bits — 86-POI catalogue)
//   bits 15..12 = iter_tier
//   bits 11..0  = F10
wire [31:0] benchmark_telemetry = {4'hA,
                                   sym_overflow_sticky, 4'b0,
                                   benchmark_idx[6:0],
                                   bench_iter_tier,
                                   last_bench_window_frames[11:0]};
wire        benchmark_telemetry_region = benchmark_active && vid_active_d &&
                                          (vid_pixel_y_d < 10'd4) &&
                                          (vid_pixel_x_d < 11'd128);
wire [4:0]  benchmark_telemetry_bit_idx = vid_pixel_x_d[6:2];
wire        benchmark_telemetry_bit = benchmark_telemetry[5'd31 - benchmark_telemetry_bit_idx];

// Color-depth quantization.  6-bit default matches the MiSTer Analog
// I/O R-2R DAC so HDMI shows the same colour banding as the CRT.
// Bench telemetry strip stays full 8-bit (see below) so the screenshot
// decoder isn't confused by reduced contrast.
wire [7:0] q_r = color_depth_mode ? overlay_r : {overlay_r[7:2], 2'b00};
wire [7:0] q_g = color_depth_mode ? overlay_g : {overlay_g[7:2], 2'b00};
wire [7:0] q_b = color_depth_mode ? overlay_b : {overlay_b[7:2], 2'b00};
assign vga_r = benchmark_telemetry_region ? (benchmark_telemetry_bit ? 8'hFF : 8'h00) : q_r;
assign vga_g = benchmark_telemetry_region ? (benchmark_telemetry_bit ? 8'hFF : 8'h00) : q_g;
assign vga_b = benchmark_telemetry_region ? (benchmark_telemetry_bit ? 8'h00 : 8'hFF) : q_b;

endmodule
