//============================================================================
// MiSTerbrot OSD Configuration (v0.9.0)
//
// Decodes MiSTer OSD status bits into fractal parameters.
//
// Status bit allocation (v0.9.0):
//   [0]       = Reset
//   [3:2]     = Type: 0=Mandelbrot, 1=Julia
//   [9:4]     = Theme override: 0=Auto, 1-32=fixed theme
//   [12:10]   = Iterations: 0=Keyboard, 1=128, 2=256, 3=512, 4=1024, 5=2048
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

    output wire [1:0]   fractal_type,
    output wire [5:0]   palette_sel,
    output wire         iter_override,
    output wire [11:0]  max_iter,
    output wire         color_cycle_enable,
    output wire [2:0]   osd_iter_sel,
    output wire         osd_iter_changed,
    output wire         osd_reset,
    output wire         single_buffer,
    output wire         blank_text_enable,
    output wire         always_show_fps,
    output wire         always_show_poi
);

// Iterations: OSD order 512,128,256,1024,2048 → remap to iter_sel (0=128,1=256,2=512,3=1024,4=2048)
wire [2:0] raw_iter = status[14:12];
assign osd_iter_sel = (raw_iter == 3'd0) ? 3'd2 :  // 512
                      (raw_iter == 3'd1) ? 3'd0 :  // 128
                      (raw_iter == 3'd2) ? 3'd1 :  // 256
                      (raw_iter == 3'd3) ? 3'd3 :  // 1024
                                          3'd4;    // 2048
reg [2:0] osd_iter_sel_prev;
assign osd_iter_changed = (osd_iter_sel != osd_iter_sel_prev);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        osd_iter_sel_prev <= 3'd2;  // match default (512)
    else
        osd_iter_sel_prev <= osd_iter_sel;
end
assign osd_reset     = status[0];
assign single_buffer = status[18];
assign blank_text_enable = ~status[19];  // On=0=blank after 10s
assign always_show_fps = status[20];     // Off=0=default, On=1
assign always_show_poi = ~status[21];    // On=0=always show
assign fractal_type  = 2'd0;  // Mandelbrot only (Julia removed)
assign palette_sel   = status[9:4];
// Color Cycling: 0=Auto (keyboard), 1=Force On, 2=Force Off
assign color_cycle_enable = ~status[10];  // 0=On, 1=Off

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
