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

    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        active,
    output reg  [10:0] pixel_x,
    output reg  [9:0]  pixel_y
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

// Vertical constants (same both modes)
localparam V_ACTIVE = 10'd240;
localparam V_FP     = 10'd3;
localparam V_SYNC   = 10'd3;
localparam V_BP     = 10'd16;
localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP; // 262

// Runtime-muxed horizontal constants
wire [10:0] h_active = mode_640 ? H_ACTIVE_640 : H_ACTIVE_320;
wire [10:0] h_fp     = mode_640 ? H_FP_640     : H_FP_320;
wire [10:0] h_sync   = mode_640 ? H_SYNC_640   : H_SYNC_320;
wire [10:0] h_total  = mode_640 ? H_TOTAL_640  : H_TOTAL_320;

reg [10:0] hc;
reg [9:0]  vc;

assign active = ~hblank & ~vblank;

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
    end else if (ce_pix) begin
        // Horizontal counter
        if (hc == h_total - 11'd1) begin
            hc <= 11'd0;
            // Vertical counter
            if (vc == V_TOTAL - 10'd1)
                vc <= 10'd0;
            else
                vc <= vc + 10'd1;
        end else begin
            hc <= hc + 11'd1;
        end

        // Horizontal signals
        hblank <= (hc >= h_active);
        hsync  <= (hc >= h_active + h_fp) && (hc < h_active + h_fp + h_sync);

        // Vertical signals
        vblank <= (vc >= V_ACTIVE);
        vsync  <= (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);

        // Pixel coordinates (in active region)
        pixel_x <= hc;
        pixel_y <= vc;
    end
end

endmodule
