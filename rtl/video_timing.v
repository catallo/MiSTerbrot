//============================================================================
// Video Timing Generator
//
// Generates native 240p timing signals for 320x240 @ ~59.7Hz (15kHz).
// Active region, sync pulses, blanking intervals.
//
// With clk=50MHz and ce_pix pulsing every 8th clock -> 6.25MHz pixel clock.
// H: 320 active + 8 front porch + 32 sync + 40 back porch = 400 total
// V: 240 active + 3 front porch + 3 sync + 16 back porch = 262 total
//============================================================================

module video_timing #(
    parameter H_ACTIVE = 320,
    parameter H_FP     = 8,
    parameter H_SYNC   = 32,
    parameter H_BP     = 40,
    parameter V_ACTIVE = 240,
    parameter V_FP     = 3,
    parameter V_SYNC   = 3,
    parameter V_BP     = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ce_pix,

    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output wire        active,
    output reg  [10:0] pixel_x,
    output reg  [9:0]  pixel_y
);

localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

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
        if (hc == H_TOTAL - 1) begin
            hc <= 11'd0;
            // Vertical counter
            if (vc == V_TOTAL - 1)
                vc <= 10'd0;
            else
                vc <= vc + 10'd1;
        end else begin
            hc <= hc + 11'd1;
        end

        // Horizontal signals
        hblank <= (hc >= H_ACTIVE);
        hsync  <= (hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC);

        // Vertical signals
        vblank <= (vc >= V_ACTIVE);
        vsync  <= (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);

        // Pixel coordinates (in active region)
        pixel_x <= hc;
        pixel_y <= vc;
    end
end

endmodule
