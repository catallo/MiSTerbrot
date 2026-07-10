//============================================================================
// MiSTerbrot OSD Configuration (v0.9.0)
//
// Decodes MiSTer OSD status bits into fractal parameters.
//
// Status bit allocation (v0.9.0):
//   [0]       = Reset
//   [3:2]     = Type: 0=Mandelbrot, 1=Julia
//   [9:4]     = Theme override: 0=Auto, 1-32=fixed theme
//   [14:12]   = Iterations: 0=Auto (zoom-adaptive), 1=512, 2=128, 3=256, 4=1024, 5=2048
//   [13]      = Color Cycling: 0=Off, 1=On
//   [17]      = V-Sync disable: 0=On (default), 1=Off
//   [17]      = Buffer: 0=Double, 1=Single
//   [18]      = Blank Text: 0=On (auto-hide), 1=Off (always show)
//   [19]      = Always Show FPS: 0=On, 1=Off
//   [20]      = Always Show POI/Palette: 0=On, 1=Off
//   [122:121] = Aspect ratio
//============================================================================

module fractal_osd #(
    parameter WIDTH = 64,
    parameter FRAC_BITS = 56
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] status,

    output wire [6:0]   palette_sel,
    output wire         iter_override,
    output wire [11:0]  max_iter,
    output wire         color_cycle_enable,
    output wire [2:0]   osd_iter_sel,
    output wire         osd_iter_changed,
    output wire         osd_reset,
    output wire         single_buffer,
    output wire         blank_text_enable,
    output wire         always_show_fps,
    output wire         always_show_poi,
    output wire         overlay_bg_dim,
    // A3 (period-3 bulb precheck) mode:
    //   2'd0 = Auto (use the per-POI bench flag in benchmark mode,
    //          off in non-benchmark mode)
    //   2'd1 = On  (force-enable for all scenes)
    //   2'd2 = Off (force-disable for all scenes)
    output wire [1:0]   p3_mode,
    // P2 periodicity detection (status[51]): 0 = On (default), 1 = Off
    output wire         periodicity_enable,
    // Attract Randomizer (status[52]): 0 = On (default), 1 = Off
    output wire         attract_randomize,
    // Unified resolution (status[56:54]): 0 = 320x240 (default),
    // 1 = 640x240, 2 = 320x480i, 3 = 640x480i, 4 = 640x480p (both
    // DDR3 framebuffer).  Bit 56 was free since the Deinterlace move
    // to O[58:57], so existing saved configs keep their meaning.
    output wire [2:0]   res_mode,
    // Deinterlace mode for 480i (status[58:57]): 0 = Weave (default;
    // sharp, combs on motion), 1 = Bob (no combing, slightly softer),
    // 2 = Off (fields scaled as independent half-pictures: F1 is
    // suppressed toward the framework)
    output wire [1:0]   deint_mode,
    // Color depth (status[36]):
    //   1'b0 = 6-bit (default, recommended — matches MiSTer Analog I/O R-2R DAC)
    //   1'b1 = 8-bit full (no quantization)
    output wire         color_depth_mode,
    // Color Cycling submenu (status[45:37]):
    output wire [3:0]   cycle_speed_sel,    // [40:37] 0=Normal(default),1=Glacial,2=Slow,3=Quick,4=Fast,5=VeryFast,6=Strobe,7=Hyper,8=Insane
    output wire [1:0]   cycle_direction,    // [42:41] 0=Forward(default),1=Reverse,2=Ping-Pong
    output wire         cycle_blend_hard,   // [43]    0=Smooth(default),1=Hard-step
    output wire [1:0]   cycle_band_mode,    // [45:44] 0=Off(default),1=Low Slow,2=Low Fast,3=Counter
    output wire [1:0]   palette_transition_mode, // [47:46] 0=Instant(default),1=Crossfade ~1s,2=Slow Crossfade ~2s
    output wire         zoom_pacing_mode,        // [48] 0=Cinematic(default),1=Constant
    output wire [1:0]   zoom_speed_sel,          // [50:49] 0=Normal(default),1=Slow,2=Fast,3=VeryFast
    // Attract Mode submenu (status[35:29]):
    //   [29] zoom_in_disable  (default 0 = zoom-in enabled)
    //   [30] zoom_out_disable (default 0 = zoom-out enabled)
    //   [35:31] wait_sel — 5-bit selector → 16-bit vblank target below
    output wire         attract_zoom_in_enable,
    output wire         attract_zoom_out_enable,
    output wire [15:0]  attract_wait_vblanks
);

// Iterations: OSD order Auto,512,128,256,1024,2048 → remap to canonical iter_sel
// (0=128, 1=256, 2=512, 3=1024, 4=2048, 5=Auto). Auto is the OSD default.
wire [2:0] raw_iter = status[14:12];
assign osd_iter_sel = (raw_iter == 3'd0) ? 3'd5 :  // Auto (default)
                      (raw_iter == 3'd1) ? 3'd2 :  // 512
                      (raw_iter == 3'd2) ? 3'd0 :  // 128
                      (raw_iter == 3'd3) ? 3'd1 :  // 256
                      (raw_iter == 3'd4) ? 3'd3 :  // 1024
                                          3'd4;    // 2048
reg [2:0] osd_iter_sel_prev;
assign osd_iter_changed = (osd_iter_sel != osd_iter_sel_prev);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        osd_iter_sel_prev <= 3'd5;  // match default (Auto)
    else
        osd_iter_sel_prev <= osd_iter_sel;
end
assign osd_reset     = status[0];
assign single_buffer = status[18];
assign blank_text_enable = ~status[19];  // On=0=blank after 10s
assign always_show_fps = status[20];     // Off=0=default, On=1
assign always_show_poi = ~status[21];    // On=0=always show
assign overlay_bg_dim  = status[23];      // 0=Transparent (default), 1=Dimmed
assign palette_sel   = status[10:4];
// Color Cycling moved to O[24] to free O[10] for the 7-bit palette selector.
assign color_cycle_enable = ~status[24];  // 0=On, 1=Off
// A3 P3 Bulb Precheck: status[26:25] — Auto/On/Off (2 bits, 3 used).
assign p3_mode = status[26:25];
assign periodicity_enable = ~status[51];
assign attract_randomize = ~status[52];
assign res_mode = status[56:54];
assign deint_mode = status[58:57];
assign color_depth_mode = status[36];

// Color Cycling submenu decoding
assign cycle_speed_sel  = status[40:37];
assign cycle_direction  = status[42:41];
assign cycle_blend_hard = status[43];
assign cycle_band_mode  = status[45:44];
assign palette_transition_mode = status[47:46];
assign zoom_pacing_mode        = status[48];
assign zoom_speed_sel          = status[50:49];

// Attract Mode decoding
assign attract_zoom_in_enable  = ~status[29];
assign attract_zoom_out_enable = ~status[30];

// Wait selector lookup → display vblank count (60 Hz).
// Default (sel=0) is 10s = 600 vblanks to preserve current behavior.
// 1 color cycle = 1024 display vblanks (cycle_phase 12-bit, +4/vblank,
// wraps at 4096 → 1024 vblanks per full palette rotation).
reg [15:0] attract_wait_vblanks_r;
always @(*) begin
    case (status[35:31])
        5'd0:  attract_wait_vblanks_r = 16'd600;    // 10s (default)
        5'd1:  attract_wait_vblanks_r = 16'd60;     // 1s
        5'd2:  attract_wait_vblanks_r = 16'd120;    // 2s
        5'd3:  attract_wait_vblanks_r = 16'd180;    // 3s
        5'd4:  attract_wait_vblanks_r = 16'd240;    // 4s
        5'd5:  attract_wait_vblanks_r = 16'd300;    // 5s
        5'd6:  attract_wait_vblanks_r = 16'd360;    // 6s
        5'd7:  attract_wait_vblanks_r = 16'd420;    // 7s
        5'd8:  attract_wait_vblanks_r = 16'd480;    // 8s
        5'd9:  attract_wait_vblanks_r = 16'd540;    // 9s
        5'd10: attract_wait_vblanks_r = 16'd900;    // 15s
        5'd11: attract_wait_vblanks_r = 16'd1024;   // 1 cycle
        5'd12: attract_wait_vblanks_r = 16'd1200;   // 20s
        5'd13: attract_wait_vblanks_r = 16'd1800;   // 30s
        5'd14: attract_wait_vblanks_r = 16'd2048;   // 2 cycles
        5'd15: attract_wait_vblanks_r = 16'd3072;   // 3 cycles
        5'd16: attract_wait_vblanks_r = 16'd3600;   // 1m
        5'd17: attract_wait_vblanks_r = 16'd4096;   // 4 cycles
        5'd18: attract_wait_vblanks_r = 16'd5120;   // 5 cycles
        5'd19: attract_wait_vblanks_r = 16'd7200;   // 2m
        5'd20: attract_wait_vblanks_r = 16'd10240;  // 10 cycles
        5'd21: attract_wait_vblanks_r = 16'd18000;  // 5m
        default: attract_wait_vblanks_r = 16'd600;
    endcase
end
assign attract_wait_vblanks = attract_wait_vblanks_r;

// Iteration decode. When status=0, keyboard/manual selection is active.
reg [11:0] max_iter_r;
always @(*) begin
    case (status[12:10])
        3'd1:    max_iter_r = 12'd128;
        3'd2:    max_iter_r = 12'd256;
        3'd3:    max_iter_r = 12'd512;
        3'd4:    max_iter_r = 12'd1024;
        3'd5:    max_iter_r = 12'd2048;
        default: max_iter_r = 12'd512;
    endcase
end
assign max_iter = max_iter_r;

endmodule
