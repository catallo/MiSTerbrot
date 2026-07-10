//============================================================================
// Video Timing Generator
//
// Generates native 240p timing signals at 15 kHz line rate.
// Mode-selectable horizontal resolution:
//   mode_640=0 → 320×240 @ 6.25 MHz dot clock (320+8+32+40=400 H_TOTAL)
//   mode_640=1 → 640×240 @ 12.5 MHz dot clock (640+16+64+80=800 H_TOTAL)
// Both produce ~59.7 Hz refresh, 15.625 kHz line rate.
//
// V_TOTAL = 240+3+3+16 = 262 (same in both modes).
//============================================================================

module video_timing (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce_pix,
    input  wire        mode_640,    // 0 = 320×240, 1 = 640×240
    // 480i (2026-07-09): when 1, output a 525-line interlaced frame at
    // the same 15.625 kHz line rate — field 0 = 262 lines, field 1 =
    // 263 lines, with field 1's vsync offset by half a line (the
    // classic CRT interlace trigger).  When 0 this module is
    // BIT-IDENTICAL to the pre-480i progressive timing (15 kHz hard
    // requirement) — verified by a cycle-compare TB against the old
    // module.
    input  wire        interlace,
    // 640x480p (Track B stage 2): 525 progressive lines at the same
    // 800-pixel H structure — 31.25 kHz / ~59.5 Hz with a 25 MHz dot
    // clock (ce_pix /4 in the 100 MHz video domain).  Mutually
    // exclusive with interlace (fractal_top enforces it).  All other
    // modes stay BIT-IDENTICAL when this is 0.
    input  wire        mode_480p,

    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        active,
    output reg  [10:0] pixel_x,
    output reg  [9:0]  pixel_y,
    output reg         field,       // 0 = even field, 1 = odd field

    // DDR3 line prefetch (Track B, additive — no effect on the above):
    // one 1-clk pulse at the start of every line carrying the LOGICAL
    // framebuffer row that will display on the FOLLOWING line (during
    // blanking: row 0 of the upcoming field, repeated — harmless
    // refetches).  Matches fb_ddr3's request protocol: the display
    // view rotates on each req, one req per line, one line ahead.
    output reg         prefetch_req,
    output reg  [9:0]  prefetch_row
);

// 320 mode horizontal constants
localparam H_ACTIVE_320 = 11'd320;
localparam H_FP_320     = 11'd8;
localparam H_SYNC_320   = 11'd32;
localparam H_BP_320     = 11'd40;
localparam H_TOTAL_320  = H_ACTIVE_320 + H_FP_320 + H_SYNC_320 + H_BP_320; // 400

// 640 mode horizontal constants (proportionally doubled)
localparam H_ACTIVE_640 = 11'd640;
localparam H_FP_640     = 11'd16;
localparam H_SYNC_640   = 11'd64;
localparam H_BP_640     = 11'd80;
localparam H_TOTAL_640  = H_ACTIVE_640 + H_FP_640 + H_SYNC_640 + H_BP_640; // 800

// Vertical constants (same both modes).
// V_FP=10 (was 3) so the scandoubler's 4-stage vbo[3:0] VBlank-delay
// pipeline propagates BEFORE VSync rises. With V_FP=3, VSync was firing
// at vc=243 while the scandoubler's delayed VBlank didn't reach the
// frame-reset logic until vc=244 — leading to a misaligned frame
// reset that left stale line-buffer content visible as a "top 15%
// shows bottom 15%" artifact in 640 mode.
// V_TOTAL stays at 262: V_FP+V_SYNC+V_BP = 10+3+9 = 22 lines blanking.
localparam V_ACTIVE = 10'd240;
localparam V_FP     = 10'd10;
localparam V_SYNC   = 10'd3;
localparam V_BP     = 10'd9;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP; // 262

// 480p vertical constants: 480+10+3+32 = 525 lines -> 31.25 kHz line
// rate / 59.52 Hz frame rate at the 800-pixel 640-mode H structure.
localparam V_ACTIVE_480P = 10'd480;
localparam V_BP_480P     = 10'd32;
localparam V_TOTAL_480P  = V_ACTIVE_480P + V_FP + V_SYNC + V_BP_480P; // 525

// Runtime-muxed vertical constants (mode_480p=0 reduces to the
// original constants everywhere)
wire [9:0] v_active = mode_480p ? V_ACTIVE_480P : V_ACTIVE;
wire [9:0] v_total  = mode_480p ? V_TOTAL_480P  : V_TOTAL;

// Runtime-muxed horizontal constants
wire [10:0] h_active = mode_640 ? H_ACTIVE_640 : H_ACTIVE_320;
wire [10:0] h_fp     = mode_640 ? H_FP_640     : H_FP_320;
wire [10:0] h_sync   = mode_640 ? H_SYNC_640   : H_SYNC_320;
wire [10:0] h_total  = mode_640 ? H_TOTAL_640  : H_TOTAL_320;

reg [10:0] hc;
reg [9:0]  vc;

assign active = ~hblank & ~vblank;

// Interlace: field 1 runs one extra line (263 vs 262) and its vsync is
// offset by half a line.  With interlace=0, v_total_eff == V_TOTAL and
// the vsync expression reduces exactly to the progressive one.
wire [9:0]  v_total_eff = (interlace && field) ? (v_total + 10'd1) : v_total;
wire [10:0] h_half      = {1'b0, h_total[10:1]};   // h_total/2 (h_total is even)

wire vsync_line_first = (vc == v_active + V_FP);              // 250 / 490
wire vsync_line_mid   = (vc >  v_active + V_FP) &&
                        (vc <  v_active + V_FP + V_SYNC);
wire vsync_line_last  = (vc == v_active + V_FP + V_SYNC);
wire vsync_prog = vsync_line_first || vsync_line_mid;
// Field-1 vsync: starts mid-line on 250, ends mid-line on 253.
wire vsync_ilace_odd = (vsync_line_first && (hc >= h_half)) ||
                       vsync_line_mid ||
                       (vsync_line_last && (hc < h_half));
wire vsync_next = (interlace && field) ? vsync_ilace_odd : vsync_prog;

// ---- DDR3 line-prefetch bookkeeping (Track B) ----
// At each line wrap, look TWO lines ahead (the line that begins now is
// vc_next; the row requested must be the one displaying on the line
// after that) and translate to the logical progressive row: 2r+f when
// interlaced, r otherwise.  During the blank tail the upcoming active
// row is row 0 of the next field.
wire        line_wrap   = (hc == h_total - 11'd1);
wire        frame_wrap  = (vc == v_total_eff - 10'd1);
wire [9:0]  vc_next     = frame_wrap ? 10'd0 : (vc + 10'd1);
wire        field_next  = frame_wrap ? (interlace ? ~field : 1'b0) : field;
wire [9:0]  vte_next    = (interlace && field_next) ? (v_total + 10'd1) : v_total;
wire        frame_wrap2 = (vc_next == vte_next - 10'd1);
wire [9:0]  line_after  = frame_wrap2 ? 10'd0 : (vc_next + 10'd1);
wire        field_after = frame_wrap2 ? (interlace ? ~field_next : 1'b0) : field_next;
wire [9:0]  pf_y = (line_after < v_active) ? line_after : 10'd0;
wire        pf_f = (line_after < v_active) ? field_after
                                           : (interlace ? ~field_next : 1'b0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prefetch_req <= 1'b0;
        prefetch_row <= 10'd0;
    end else begin
        prefetch_req <= ce_pix && line_wrap;
        if (ce_pix && line_wrap)
            prefetch_row <= interlace ? {pf_y[8:0], pf_f} : pf_y;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hc      <= 11'd0;
        vc      <= 10'd0;
        hsync   <= 1'b0;
        vsync   <= 1'b0;
        hblank  <= 1'b1;
        vblank  <= 1'b1;
        pixel_x <= 11'd0;
        pixel_y <= 10'd0;
        field   <= 1'b0;
    end else if (ce_pix) begin
        // Horizontal counter
        if (hc == h_total - 11'd1) begin
            hc <= 11'd0;
            // Vertical counter
            if (vc == v_total_eff - 10'd1) begin
                vc <= 10'd0;
                field <= interlace ? ~field : 1'b0;
            end else
                vc <= vc + 10'd1;
        end else begin
            hc <= hc + 11'd1;
        end

        // Horizontal signals
        hblank <= (hc >= h_active);
        hsync  <= (hc >= h_active + h_fp) && (hc < h_active + h_fp + h_sync);

        // Vertical signals
        vblank <= (vc >= v_active);
        vsync  <= vsync_next;

        // Pixel coordinates (in active region)
        pixel_x <= hc;
        pixel_y <= vc;
    end
end

endmodule
