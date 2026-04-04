//============================================================================
// Text Overlay
//
// Top-left info rows, top-right status, bottom-left target,
// and bottom-right version/GitHub link rendered directly into the video stream.
// Uses a hardcoded 5x5 monochrome font and fixed 32-char lines.
// 5x5 glyphs with 10px line height (5px glyph + 5px gap).
//============================================================================

module text_overlay #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
) (
    input  wire                    clk,
    input  wire                    overlay_enable,
    input  wire                    overlay_visible,
    input  wire                    blank_text_enable,
    input  wire                    always_show_fps,
    input  wire                    always_show_poi,
    input  wire [10:0]             pixel_x,
    input  wire [9:0]              pixel_y,
    input  wire                    video_active,
    input  wire [1:0]              fractal_type,
    input  wire [5:0]              palette_sel,
    input  wire [11:0]             max_iter,
    input  wire [6:0]              fps_value,
    input  wire signed [WIDTH-1:0] center_x,
    input  wire signed [WIDTH-1:0] center_y,
    input  wire signed [WIDTH-1:0] step,
    input  wire                    auto_zoom_active,
    input  wire                    color_cycle_active,
    input  wire [1:0]               color_cycle_mode,
    input  wire [4:0]              target_idx,
    input  wire [7:0]              in_r,
    input  wire [7:0]              in_g,
    input  wire [7:0]              in_b,
    output wire [7:0]              out_r,
    output wire [7:0]              out_g,
    output wire [7:0]              out_b
);

// ---- Screen and Region Constants (5x5 font, 10px line height) ----
localparam [10:0] SCREEN_W = 11'd320;

// Info region: top-left, 3 lines
localparam [10:0] INFO_X = 11'd5;
localparam [9:0]  INFO_Y = 10'd3;
localparam [10:0] INFO_W = 11'd164;  // 32*5 + 4 padding
localparam [9:0]  INFO_H = 10'd34;   // 3*10 + 4 padding

// Help region: top-right, 2 lines (auto zoom + color cycling status)
localparam [10:0] HELP_X = 11'd5;    // top-left (was top-right)
localparam [9:0]  HELP_Y = 10'd3;    // top-left
localparam [10:0] HELP_W = 11'd18;   // 2 chars * 5 + 4 padding + 4
localparam [9:0]  HELP_H = 10'd14;   // 1*10 + 4

// Meta region: overlaps info origin, 1 line (currently unused content)
localparam [10:0] META_X = INFO_X;
localparam [9:0]  META_Y = INFO_Y;
localparam [10:0] META_W = 11'd84;   // 16*5 + 4
localparam [9:0]  META_H = 10'd14;

// Target region: bottom-left, 2 lines
localparam [10:0] TARGET_X = 11'd5;
localparam [9:0]  TARGET_Y = 10'd216; // 240 - 24
localparam [10:0] TARGET_W = 11'd244; // 48*5 + 4
localparam [9:0]  TARGET_H = 10'd24;  // 2*10 + 4

// GitHub region: bottom-right, 2 lines (same Y as target)
localparam [10:0] GITHUB_X = 11'd221; // right-aligned: 313 - 18*5
localparam [9:0]  GITHUB_Y = 10'd216; // same as TARGET_Y
localparam [10:0] GITHUB_W = 11'd94;  // 18*5 + 4
localparam [9:0]  GITHUB_H = 10'd24;

localparam [5:0]  LINE_LEN = 6'd32;
localparam [6:0]  TARGET_LINE_LEN = 7'd48;
localparam signed [WIDTH-1:0] DEFAULT_STEP = 64'sh0003333333333333;

localparam [2:0]  INFO_LINES = 3'd3;
localparam [2:0]  META_LINES = 3'd1;
localparam [2:0]  HELP_LINES = 3'd1;
localparam [2:0]  TARGET_LINES = 3'd2;
localparam [2:0]  GITHUB_LINES = 3'd2;

localparam [9:0]  INFO_TEXT_H = 10'd30;   // 3*10
localparam [9:0]  META_TEXT_H = 10'd10;   // 1*10
localparam [9:0]  HELP_TEXT_H = 10'd20;   // 2*10
localparam [9:0]  TARGET_TEXT_H = 10'd20; // 2*10
localparam [9:0]  GITHUB_TEXT_H = 10'd20; // 2*10

localparam [10:0] LINE_PIX_W = 11'd160;        // LINE_LEN * 5
localparam [10:0] TARGET_PIX_W = 11'd240;       // TARGET_LINE_LEN * 5

localparam [5:0]  HELP_LINE_LEN = 6'd16;
localparam [5:0]  GITHUB_LINE_LEN = 6'd18;
localparam [10:0] HELP_PIX_W = 11'd80;         // HELP_LINE_LEN * 5
// Status region: top-right, 2 lines (color cycling mode + iterations)
localparam [10:0] STATUS_X = 11'd261;   // right-aligned for 10 chars: 313 - 10*5 - 2
localparam [9:0]  STATUS_Y = 10'd3;
localparam [10:0] STATUS_W = 11'd54;    // 10*5 + 4
localparam [9:0]  STATUS_H = 10'd24;    // 2*10 + 4
localparam [2:0]  STATUS_LINES = 3'd2;
localparam [5:0]  STATUS_LINE_LEN = 6'd10;
localparam [10:0] STATUS_PIX_W = 11'd50;
localparam [10:0] GITHUB_PIX_W = 11'd90;       // GITHUB_LINE_LEN * 5

localparam [255:0] BLANK_LINE = "                                ";
localparam [383:0] TARGET_BLANK_LINE = {
    "                                                "
};

// ---- Division by 5 and 10 helpers (FPGA-friendly multiply-shift) ----
// div5: floor(x/5) via (x * 205) >> 10, exact for x < 256
// div10: floor(y/10) via (y * 205) >> 11, exact for y < 100

function [5:0] div5;
    input [10:0] x;
    begin
        div5 = (x * 205) >> 10;
    end
endfunction

function [2:0] mod5;
    input [10:0] x;
    reg [5:0] q;
    begin
        q = (x * 205) >> 10;
        mod5 = x - q * 5;
    end
endfunction

function [2:0] div10;
    input [9:0] y;
    begin
        div10 = (y * 205) >> 11;
    end
endfunction

function [3:0] mod10;
    input [9:0] y;
    reg [2:0] q;
    begin
        q = (y * 205) >> 11;
        mod10 = y - q * 10;
    end
endfunction

// ---- Region active signals ----
wire info_region_active = 1'b0;  // disabled
wire help_region_active = overlay_enable && (overlay_visible || always_show_fps) && video_active &&
                          (pixel_x >= HELP_X) && (pixel_x < HELP_X + HELP_W) &&
                          (pixel_y >= HELP_Y) && (pixel_y < HELP_Y + HELP_H);
wire meta_region_active = overlay_enable && overlay_visible && video_active &&
                          (pixel_x >= META_X) && (pixel_x < META_X + META_W) &&
                          (pixel_y >= META_Y) && (pixel_y < META_Y + META_H);
wire target_region_active = overlay_enable && video_active &&
                            (pixel_x >= TARGET_X) && (pixel_x < TARGET_X + TARGET_W) &&
                            (pixel_y >= TARGET_Y) && (pixel_y < TARGET_Y + TARGET_H);
wire status_region_active = overlay_enable && overlay_visible && video_active &&
                            (pixel_x >= STATUS_X) && (pixel_x < STATUS_X + STATUS_W) &&
                            (pixel_y >= STATUS_Y) && (pixel_y < STATUS_Y + STATUS_H);
wire github_region_active = overlay_enable && overlay_visible && video_active &&
                            (pixel_x >= GITHUB_X) && (pixel_x < GITHUB_X + GITHUB_W) &&
                            (pixel_y >= GITHUB_Y) && (pixel_y < GITHUB_Y + GITHUB_H);

// ---- Info region coordinate extraction (5x5 font, 10px line height) ----
wire [10:0] info_local_x = pixel_x - INFO_X - 11'd2;
wire [9:0]  info_local_y = pixel_y - INFO_Y - 10'd2;
wire info_text_area = info_region_active && (pixel_x >= INFO_X + 11'd2) && (pixel_y >= INFO_Y + 10'd2);
wire [5:0] info_char_col = div5(info_local_x);   // divide by 5
wire [2:0] info_glyph_col = mod5(info_local_x);   // mod 5
wire [2:0] info_line_idx = div10(info_local_y);
wire [3:0] info_line_y = mod10(info_local_y);
wire [2:0] info_glyph_row_idx = info_line_y;
wire info_line_text_active = (info_line_y < 3'd5);

// ---- Help region ----
wire [10:0] help_local_x = pixel_x - HELP_X - 11'd2;
wire [9:0]  help_local_y = pixel_y - HELP_Y - 10'd2;
wire help_text_area = help_region_active && (pixel_x >= HELP_X + 11'd2) && (pixel_y >= HELP_Y + 10'd2);
wire [5:0] help_char_col = div5(help_local_x);
wire [2:0] help_glyph_col = mod5(help_local_x);
wire [2:0] help_line_idx = div10(help_local_y);
wire [3:0] help_line_y = mod10(help_local_y);
wire [2:0] help_glyph_row_idx = help_line_y;
wire help_line_text_active = (help_line_y < 3'd5);

// ---- Meta region ----
wire [10:0] meta_local_x = pixel_x - META_X - 11'd2;
wire [9:0]  meta_local_y = pixel_y - META_Y - 10'd2;
wire meta_text_area = meta_region_active && (pixel_x >= META_X + 11'd2) && (pixel_y >= META_Y + 10'd2);
wire [5:0] meta_char_col = div5(meta_local_x);
wire [2:0] meta_glyph_col = mod5(meta_local_x);
wire [2:0] meta_line_idx = div10(meta_local_y);
wire [3:0] meta_line_y = mod10(meta_local_y);
wire [2:0] meta_glyph_row_idx = meta_line_y;
wire meta_line_text_active = (meta_line_y < 3'd5);

// ---- Target region ----
wire [10:0] target_local_x = pixel_x - TARGET_X - 11'd2;
wire [9:0]  target_local_y = pixel_y - TARGET_Y - 10'd2;
wire target_text_area = target_region_active && (pixel_x >= TARGET_X + 11'd2) && (pixel_y >= TARGET_Y + 10'd2);
wire [6:0] target_char_col = div5(target_local_x);
wire [2:0] target_glyph_col = mod5(target_local_x);
wire [2:0] target_line_idx = div10(target_local_y);
wire [3:0] target_line_y = mod10(target_local_y);
wire [2:0] target_glyph_row_idx = target_line_y;
wire target_line_text_active = (target_line_y < 3'd5);

// ---- GitHub region ----
wire [10:0] github_local_x = pixel_x - GITHUB_X - 11'd2;
wire [9:0]  github_local_y = pixel_y - GITHUB_Y - 10'd2;
wire github_text_area = github_region_active && (pixel_x >= GITHUB_X + 11'd2) && (pixel_y >= GITHUB_Y + 10'd2);
wire [5:0] github_char_col = div5(github_local_x);
wire [2:0] github_glyph_col = mod5(github_local_x);
wire [2:0] github_line_idx = div10(github_local_y);
wire [3:0] github_line_y = mod10(github_local_y);
wire [2:0] github_glyph_row_idx = github_line_y;
wire github_line_text_active = (github_line_y < 3'd5);

// ---- Status region ----
wire [10:0] status_local_x = pixel_x - STATUS_X - 11'd2;
wire [9:0]  status_local_y = pixel_y - STATUS_Y - 10'd2;
wire status_text_area = status_region_active && (pixel_x >= STATUS_X + 11'd2) && (pixel_y >= STATUS_Y + 10'd2);
wire [5:0] status_char_col = div5(status_local_x);
wire [2:0] status_glyph_col = mod5(status_local_x);
wire [2:0] status_line_idx = div10(status_local_y);
wire [3:0] status_line_y = mod10(status_local_y);
wire [2:0] status_glyph_row_idx = status_line_y;
wire status_line_text_active = (status_line_y < 3'd5);

// ---- Numeric formatting (unchanged logic) ----
reg [7:0] iter_digit_3;
reg [7:0] iter_digit_2;
reg [7:0] iter_digit_1;
reg [7:0] iter_digit_0;
reg [6:0] fps_clamped;
reg [7:0] fps_digit_1;
reg [7:0] fps_digit_0;
reg [7:0] coord_x_sign;
reg [7:0] coord_y_sign;
reg [7:0] coord_x_int;
reg [7:0] coord_y_int;
reg [13:0] coord_x_frac;
reg [13:0] coord_y_frac;
reg [7:0] coord_x_d3;
reg [7:0] coord_x_d2;
reg [7:0] coord_x_d1;
reg [7:0] coord_x_d0;
reg [7:0] coord_y_d3;
reg [7:0] coord_y_d2;
reg [7:0] coord_y_d1;
reg [7:0] coord_y_d0;
reg signed [WIDTH-1:0] abs_x;
reg signed [WIDTH-1:0] abs_y;

always @(*) begin
    case (max_iter)
        12'd128:  begin iter_digit_3 = "1"; iter_digit_2 = "2"; iter_digit_1 = "8"; iter_digit_0 = " "; end
        12'd256:  begin iter_digit_3 = "2"; iter_digit_2 = "5"; iter_digit_1 = "6"; iter_digit_0 = " "; end
        12'd512:  begin iter_digit_3 = "5"; iter_digit_2 = "1"; iter_digit_1 = "2"; iter_digit_0 = " "; end
        12'd1024: begin iter_digit_3 = "1"; iter_digit_2 = "0"; iter_digit_1 = "2"; iter_digit_0 = "4"; end
        default:  begin iter_digit_3 = "2"; iter_digit_2 = "0"; iter_digit_1 = "4"; iter_digit_0 = "8"; end
    endcase
end

always @(*) begin
    fps_clamped = (fps_value > 7'd99) ? 7'd99 : fps_value;

    if (fps_clamped >= 7'd90) begin fps_digit_1 = "9"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd90); end
    else if (fps_clamped >= 7'd80) begin fps_digit_1 = "8"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd80); end
    else if (fps_clamped >= 7'd70) begin fps_digit_1 = "7"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd70); end
    else if (fps_clamped >= 7'd60) begin fps_digit_1 = "6"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd60); end
    else if (fps_clamped >= 7'd50) begin fps_digit_1 = "5"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd50); end
    else if (fps_clamped >= 7'd40) begin fps_digit_1 = "4"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd40); end
    else if (fps_clamped >= 7'd30) begin fps_digit_1 = "3"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd30); end
    else if (fps_clamped >= 7'd20) begin fps_digit_1 = "2"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd20); end
    else if (fps_clamped >= 7'd10) begin fps_digit_1 = "1"; fps_digit_0 = fps_ones_ascii(fps_clamped - 7'd10); end
    else begin fps_digit_1 = "0"; fps_digit_0 = fps_ones_ascii(fps_clamped); end
end

function signed [WIDTH-1:0] abs_fixed;
    input signed [WIDTH-1:0] value;
    begin
        abs_fixed = value[WIDTH-1] ? -value : value;
    end
endfunction

function [13:0] frac_to_4dp;
    input [13:0] frac14;
    reg [27:0] scaled;
    reg [13:0] result;
    begin
        scaled = ({14'd0, frac14} << 13) +
                 ({14'd0, frac14} << 10) +
                 ({14'd0, frac14} << 9)  +
                 ({14'd0, frac14} << 8)  +
                 ({14'd0, frac14} << 4);
        result = scaled[27:14];
        frac_to_4dp = (result > 14'd9999) ? 14'd9999 : result;
    end
endfunction

always @(posedge clk) begin
    abs_x <= abs_fixed(center_x);
    abs_y <= abs_fixed(center_y);

    coord_x_sign <= center_x[WIDTH-1] ? "-" : " ";
    coord_y_sign <= center_y[WIDTH-1] ? "-" : " ";
    coord_x_int <= digit_ascii(abs_x[FRAC_BITS+3:FRAC_BITS]);
    coord_y_int <= digit_ascii(abs_y[FRAC_BITS+3:FRAC_BITS]);
    coord_x_frac <= frac_to_4dp(abs_x[FRAC_BITS-1:FRAC_BITS-14]);
    coord_y_frac <= frac_to_4dp(abs_y[FRAC_BITS-1:FRAC_BITS-14]);

    coord_x_d3 <= digit_ascii((coord_x_frac / 14'd1000) % 10);
    coord_x_d2 <= digit_ascii((coord_x_frac / 14'd100) % 10);
    coord_x_d1 <= digit_ascii((coord_x_frac / 14'd10) % 10);
    coord_x_d0 <= digit_ascii(coord_x_frac % 10);

    coord_y_d3 <= digit_ascii((coord_y_frac / 14'd1000) % 10);
    coord_y_d2 <= digit_ascii((coord_y_frac / 14'd100) % 10);
    coord_y_d1 <= digit_ascii((coord_y_frac / 14'd10) % 10);
    coord_y_d0 <= digit_ascii(coord_y_frac % 10);
end

// ---- Target name functions ----
function [159:0] target_name_full;
    input [1:0] ftype;
    input [4:0] idx;
    begin
        // Julia removed - Mandelbrot only
        begin
            case (idx)
                5'd0:  target_name_full = "SEAHORSE ENTRY      ";
                5'd1:  target_name_full = "CARDIOID INTERIOR   ";
                5'd2:  target_name_full = "UPPER BOUNDARY      ";
                5'd3:  target_name_full = "SEAHORSE VALLEY     ";
                5'd4:  target_name_full = "UPPER DENDRITE      ";
                5'd5:  target_name_full = "PERIOD-2 NECK       ";
                5'd6:  target_name_full = "DEEP SEAHORSE       ";
                5'd7:  target_name_full = "ELEPHANT EDGE       ";
                5'd8:  target_name_full = "FILAMENT CROWN      ";
                5'd9:  target_name_full = "NEEDLE CORRIDOR     ";
                5'd10: target_name_full = "DEEP ELEPHANT       ";
                5'd11: target_name_full = "HALO FILAMENTS      ";
                5'd12: target_name_full = "CARDIOID EDGE       ";
                5'd13: target_name_full = "SPIRAL VALLEY       ";
                5'd14: target_name_full = "MINI-BROT           ";
                5'd15: target_name_full = "DOUBLE SPIRAL       ";
                5'd16: target_name_full = "ANTENNA TIP         ";
                5'd17: target_name_full = "BABY MANDELBROT     ";
                5'd18: target_name_full = "SEAHORSE TAIL       ";
                5'd19: target_name_full = "ELEPHANT TRUNK      ";
                5'd20: target_name_full = "TRIPLE SPIRAL       ";
                5'd21: target_name_full = "DENDRITE JUNCTION   ";
                5'd22: target_name_full = "SWIRL               ";
                5'd23: target_name_full = "LIGHTNING           ";
                default: target_name_full = "STARFISH            ";
            endcase
        end
    end
endfunction

// ---- Zoom calculation ----
function [1:0] nibble_msb;
    input [3:0] nibble;
    begin
        casez (nibble)
            4'b1???: nibble_msb = 2'd3;
            4'b01??: nibble_msb = 2'd2;
            4'b001?: nibble_msb = 2'd1;
            default: nibble_msb = 2'd0;
        endcase
    end
endfunction

reg [5:0] step_msb;
reg [WIDTH-1:0] step_norm;
reg [3:0] zoom_frac_nibble;
reg [3:0] zoom_frac_tenth;

always @(*) begin
    if (step[63:60] != 4'd0)      step_msb = 6'd60 + {4'd0, nibble_msb(step[63:60])};
    else if (step[59:56] != 4'd0) step_msb = 6'd56 + {4'd0, nibble_msb(step[59:56])};
    else if (step[55:52] != 4'd0) step_msb = 6'd52 + {4'd0, nibble_msb(step[55:52])};
    else if (step[51:48] != 4'd0) step_msb = 6'd48 + {4'd0, nibble_msb(step[51:48])};
    else if (step[47:44] != 4'd0) step_msb = 6'd44 + {4'd0, nibble_msb(step[47:44])};
    else if (step[43:40] != 4'd0) step_msb = 6'd40 + {4'd0, nibble_msb(step[43:40])};
    else if (step[39:36] != 4'd0) step_msb = 6'd36 + {4'd0, nibble_msb(step[39:36])};
    else if (step[35:32] != 4'd0) step_msb = 6'd32 + {4'd0, nibble_msb(step[35:32])};
    else if (step[31:28] != 4'd0) step_msb = 6'd28 + {4'd0, nibble_msb(step[31:28])};
    else if (step[27:24] != 4'd0) step_msb = 6'd24 + {4'd0, nibble_msb(step[27:24])};
    else if (step[23:20] != 4'd0) step_msb = 6'd20 + {4'd0, nibble_msb(step[23:20])};
    else if (step[19:16] != 4'd0) step_msb = 6'd16 + {4'd0, nibble_msb(step[19:16])};
    else if (step[15:12] != 4'd0) step_msb = 6'd12 + {4'd0, nibble_msb(step[15:12])};
    else if (step[11:8] != 4'd0)  step_msb = 6'd8  + {4'd0, nibble_msb(step[11:8])};
    else if (step[7:4] != 4'd0)   step_msb = 6'd4  + {4'd0, nibble_msb(step[7:4])};
    else                           step_msb = {4'd0, nibble_msb(step[3:0])};
end

wire [5:0] zoom_exp = (step >= DEFAULT_STEP) ? 6'd0 : (6'd49 - step_msb);

always @(*) begin
    if (step >= DEFAULT_STEP) begin
        step_norm = {WIDTH{1'b0}};
        zoom_frac_nibble = 4'd0;
        zoom_frac_tenth = 4'd0;
    end else begin
        step_norm = step << (6'd63 - step_msb);
        zoom_frac_nibble = step_norm[62:59];
        if (zoom_frac_nibble >= 4'd14)      zoom_frac_tenth = 4'd0;
        else if (zoom_frac_nibble >= 4'd13) zoom_frac_tenth = 4'd1;
        else if (zoom_frac_nibble >= 4'd11) zoom_frac_tenth = 4'd2;
        else if (zoom_frac_nibble >= 4'd9)  zoom_frac_tenth = 4'd3;
        else if (zoom_frac_nibble >= 4'd7)  zoom_frac_tenth = 4'd4;
        else if (zoom_frac_nibble >= 4'd6)  zoom_frac_tenth = 4'd5;
        else if (zoom_frac_nibble >= 4'd4)  zoom_frac_tenth = 4'd6;
        else if (zoom_frac_nibble >= 4'd3)  zoom_frac_tenth = 4'd7;
        else if (zoom_frac_nibble >= 4'd1)  zoom_frac_tenth = 4'd8;
        else                                zoom_frac_tenth = 4'd9;
    end
end

// ---- ASCII helper functions ----
function [7:0] zoom_tens_ascii;
    input [5:0] zoom_val;
    begin
        if (zoom_val >= 6'd60)      zoom_tens_ascii = "6";
        else if (zoom_val >= 6'd50) zoom_tens_ascii = "5";
        else if (zoom_val >= 6'd40) zoom_tens_ascii = "4";
        else if (zoom_val >= 6'd30) zoom_tens_ascii = "3";
        else if (zoom_val >= 6'd20) zoom_tens_ascii = "2";
        else if (zoom_val >= 6'd10) zoom_tens_ascii = "1";
        else                        zoom_tens_ascii = "0";
    end
endfunction

function [7:0] zoom_frac_ascii;
    input [3:0] zoom_frac;
    begin
        case (zoom_frac)
            4'd0: zoom_frac_ascii = "0";
            4'd1: zoom_frac_ascii = "1";
            4'd2: zoom_frac_ascii = "2";
            4'd3: zoom_frac_ascii = "3";
            4'd4: zoom_frac_ascii = "4";
            4'd5: zoom_frac_ascii = "5";
            4'd6: zoom_frac_ascii = "6";
            4'd7: zoom_frac_ascii = "7";
            4'd8: zoom_frac_ascii = "8";
            default: zoom_frac_ascii = "9";
        endcase
    end
endfunction

function [7:0] zoom_ones_ascii;
    input [5:0] zoom_val;
    begin
        case (zoom_val)
            6'd0, 6'd10, 6'd20, 6'd30, 6'd40, 6'd50, 6'd60: zoom_ones_ascii = "0";
            6'd1, 6'd11, 6'd21, 6'd31, 6'd41, 6'd51, 6'd61: zoom_ones_ascii = "1";
            6'd2, 6'd12, 6'd22, 6'd32, 6'd42, 6'd52, 6'd62: zoom_ones_ascii = "2";
            6'd3, 6'd13, 6'd23, 6'd33, 6'd43, 6'd53, 6'd63: zoom_ones_ascii = "3";
            6'd4, 6'd14, 6'd24, 6'd34, 6'd44, 6'd54:        zoom_ones_ascii = "4";
            6'd5, 6'd15, 6'd25, 6'd35, 6'd45, 6'd55:        zoom_ones_ascii = "5";
            6'd6, 6'd16, 6'd26, 6'd36, 6'd46, 6'd56:        zoom_ones_ascii = "6";
            6'd7, 6'd17, 6'd27, 6'd37, 6'd47, 6'd57:        zoom_ones_ascii = "7";
            6'd8, 6'd18, 6'd28, 6'd38, 6'd48, 6'd58:        zoom_ones_ascii = "8";
            default:                                        zoom_ones_ascii = "9";
        endcase
    end
endfunction

function [7:0] digit_ascii;
    input [3:0] digit;
    begin
        digit_ascii = 8'd48 + digit;
    end
endfunction

function [7:0] fps_ones_ascii;
    input [6:0] digit;
    begin
        case (digit)
            7'd0: fps_ones_ascii = "0";
            7'd1: fps_ones_ascii = "1";
            7'd2: fps_ones_ascii = "2";
            7'd3: fps_ones_ascii = "3";
            7'd4: fps_ones_ascii = "4";
            7'd5: fps_ones_ascii = "5";
            7'd6: fps_ones_ascii = "6";
            7'd7: fps_ones_ascii = "7";
            7'd8: fps_ones_ascii = "8";
            default: fps_ones_ascii = "9";
        endcase
    end
endfunction

// ---- Text content functions ----
function [255:0] fractal_line;
    input [1:0] ftype;
    begin
        fractal_line = "TYPE: MANDELBROT                ";
    end
endfunction

function [95:0] fractal_name;
    input [1:0] ftype;
    begin
        fractal_name = "Mandelbrot  ";
    end
endfunction

function [255:0] palette_line;
    input [5:0] pal;
    begin
        case (pal)
            6'd0:  palette_line = "PAL: RAINBOW                  ";
            6'd1:  palette_line = "PAL: FIRE                     ";
            6'd2:  palette_line = "PAL: OCEAN                    ";
            6'd3:  palette_line = "PAL: GRAYSCALE                ";
            6'd4:  palette_line = "PAL: SMOOTH                   ";
            6'd5:  palette_line = "PAL: NEON                     ";
            6'd6:  palette_line = "PAL: EARTH                    ";
            6'd7:  palette_line = "PAL: ICE                      ";
            6'd8:  palette_line = "PAL: SUNSET                   ";
            6'd9:  palette_line = "PAL: ELECTRIC                 ";
            6'd10: palette_line = "PAL: MATRIX                   ";
            6'd11: palette_line = "PAL: CAPPUCCINO               ";
            6'd12: palette_line = "PAL: PSYCHEDELIC              ";
            6'd13: palette_line = "PAL: MILKY WAY                ";
            6'd14: palette_line = "PAL: FUNHAUS                  ";
            6'd15: palette_line = "PAL: BUTTERMILCH              ";
            6'd16: palette_line = "PAL: INDIGO                   ";
            6'd17: palette_line = "PAL: 70S DISCO                ";
            6'd18: palette_line = "PAL: 90S TECHNO               ";
            6'd19: palette_line = "PAL: C64                      ";
            6'd20: palette_line = "PAL: MIAMI VICE               ";
            6'd21: palette_line = "PAL: GOLD SHOWER              ";
            6'd22: palette_line = "PAL: STARDUST                 ";
            6'd23: palette_line = "PAL: NEBULA                   ";
            6'd24: palette_line = "PAL: SILVERADO                ";
            6'd25: palette_line = "PAL: AKIHABARA                ";
            6'd26: palette_line = "PAL: COLORADO                 ";
            6'd27: palette_line = "PAL: XTC                      ";
            6'd28: palette_line = "PAL: PSILOCYBIN               ";
            6'd29: palette_line = "PAL: HDR                      ";
            6'd30: palette_line = "PAL: THC                      ";
            6'd31: palette_line = "PAL: BARBIE WORLD             ";
            6'd32: palette_line = "PAL: SKITTLES                 ";
            6'd33: palette_line = "PAL: PAPAGAIO                  ";
            6'd34: palette_line = "PAL: BUBBLEGUM                ";
            6'd35: palette_line = "PAL: SYNTHWAVE                ";
            6'd36: palette_line = "PAL: POP ART                  ";
            6'd37: palette_line = "PAL: TROPICAL                 ";
            6'd38: palette_line = "PAL: VAPORWAVE                ";
            6'd39: palette_line = "PAL: ACID                     ";
            6'd40: palette_line = "PAL: MORNING SUN              ";
            6'd41: palette_line = "PAL: CLOUDY                   ";
            6'd42: palette_line = "PAL: AURORA BOREALIS          ";
            6'd43: palette_line = "PAL: CREAM                    ";
            6'd44: palette_line = "PAL: PALLADIUM SILVER         ";
            6'd45: palette_line = "PAL: COMPLEMENTARY            ";
            6'd46: palette_line = "PAL: MIGRAINE AURA            ";
            default: palette_line = "PAL: UNUSED                   ";
        endcase
    end
endfunction

function [95:0] palette_name;
    input [5:0] pal;
    begin
        case (pal)
            6'd0:  palette_name = "Rainbow     ";
            6'd1:  palette_name = "Fire        ";
            6'd2:  palette_name = "Ocean       ";
            6'd3:  palette_name = "Grayscale   ";
            6'd4:  palette_name = "Smooth      ";
            6'd5:  palette_name = "Neon        ";
            6'd6:  palette_name = "Earth       ";
            6'd7:  palette_name = "Ice         ";
            6'd8:  palette_name = "Sunset      ";
            6'd9:  palette_name = "Electric    ";
            6'd10: palette_name = "Matrix      ";
            6'd11: palette_name = "Cappuccino  ";
            6'd12: palette_name = "Psychedelic ";
            6'd13: palette_name = "Milky Way   ";
            6'd14: palette_name = "Funhaus     ";
            6'd15: palette_name = "Buttermilch ";
            6'd16: palette_name = "Indigo      ";
            6'd17: palette_name = "70s Disco   ";
            6'd18: palette_name = "90s Techno  ";
            6'd19: palette_name = "C64         ";
            6'd20: palette_name = "Miami Vice  ";
            6'd21: palette_name = "Gold Shower ";
            6'd22: palette_name = "Stardust    ";
            6'd23: palette_name = "Nebula      ";
            6'd24: palette_name = "Silverado   ";
            6'd25: palette_name = "Akihabara   ";
            6'd26: palette_name = "Colorado    ";
            6'd27: palette_name = "XTC         ";
            6'd28: palette_name = "Psilocybin  ";
            6'd29: palette_name = "HDR         ";
            6'd30: palette_name = "THC         ";
            6'd31: palette_name = "Barbie World";
            6'd32: palette_name = "Skittles    ";
            6'd33: palette_name = "Papagaio    ";
            6'd34: palette_name = "Bubblegum   ";
            6'd35: palette_name = "Synthwave   ";
            6'd36: palette_name = "Pop Art     ";
            6'd37: palette_name = "Tropical    ";
            6'd38: palette_name = "Vaporwave   ";
            6'd39: palette_name = "Acid        ";
            6'd40: palette_name = "Morning Sun ";
            6'd41: palette_name = "Cloudy      ";
            6'd42: palette_name = "Aurora      ";
            6'd43: palette_name = "Cream       ";
            6'd44: palette_name = "Palladium   ";
            6'd45: palette_name = "Complement  ";
            6'd46: palette_name = "Migraine    ";
            default: palette_name = "Unused      ";
        endcase
    end
endfunction

function [255:0] target_line;
    input [1:0] ftype;
    input [4:0] idx;
    begin
        // Julia removed - Mandelbrot only
        begin
            case (idx)
                5'd0:  target_line = "SEAHORSE ENTRY                  ";
                5'd1:  target_line = "CARDIOID INTERIOR               ";
                5'd2:  target_line = "UPPER BOUNDARY                  ";
                5'd3:  target_line = "SEAHORSE VALLEY                 ";
                5'd4:  target_line = "UPPER DENDRITE                  ";
                5'd5:  target_line = "PERIOD-2 NECK                   ";
                5'd6:  target_line = "DEEP SEAHORSE                   ";
                5'd7:  target_line = "ELEPHANT EDGE                   ";
                5'd8:  target_line = "FILAMENT CROWN                  ";
                5'd9:  target_line = "NEEDLE CORRIDOR                 ";
                5'd10: target_line = "DEEP ELEPHANT                   ";
                5'd11: target_line = "HALO FILAMENTS                  ";
                5'd12: target_line = "CARDIOID EDGE                   ";
                5'd13: target_line = "SPIRAL VALLEY                   ";
                5'd14: target_line = "MINI-BROT                       ";
                5'd15: target_line = "DOUBLE SPIRAL                   ";
                5'd16: target_line = "ANTENNA TIP                     ";
                5'd17: target_line = "BABY MANDELBROT                 ";
                5'd18: target_line = "SEAHORSE TAIL                   ";
                5'd19: target_line = "ELEPHANT TRUNK                  ";
                5'd20: target_line = "TRIPLE SPIRAL                   ";
                5'd21: target_line = "DENDRITE JUNCTION               ";
                5'd22: target_line = "SWIRL                           ";
                5'd23: target_line = "LIGHTNING                       ";
                default: target_line = "STARFISH                        ";
            endcase
        end
    end
endfunction

// ---- Line data functions ----
function [255:0] line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: line_data = {"ITER: ", iter_digit_3, iter_digit_2, iter_digit_1, iter_digit_0,
                               "                      "};
            3'd1: line_data = {"Type: ", fractal_name(fractal_type), "          "};
            3'd2: line_data = BLANK_LINE;
            default: line_data = BLANK_LINE;
        endcase
    end
endfunction

function [255:0] meta_line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: meta_line_data = BLANK_LINE;
            default: meta_line_data = BLANK_LINE;
        endcase
    end
endfunction

function [127:0] help_line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: help_line_data = {fps_digit_1, fps_digit_0, "              "};
            default: help_line_data = {16{8'd32}};
        endcase
    end
endfunction

// ---- Combined POI | Palette string (48 chars) ----
function [383:0] target_poi_palette;
    input [1:0] ftype;
    input [4:0] idx;
    input [5:0] pal;
    reg [383:0] result;
    begin
        if (ftype == 2'd1) begin
            case (idx)
                5'd0:  result = {"ORIGIN | ",              palette_name(pal), "                           "};
                5'd1:  result = {"LEFT CORE | ",           palette_name(pal), "                        "};
                5'd2:  result = {"RIGHT CORE | ",          palette_name(pal), "                       "};
                5'd3:  result = {"NORTH LOBE | ",          palette_name(pal), "                       "};
                5'd4:  result = {"SOUTH LOBE | ",          palette_name(pal), "                       "};
                5'd5:  result = {"NORTHWEST FILAMENT | ",  palette_name(pal), "               "};
                5'd6:  result = {"SOUTHWEST FILAMENT | ",  palette_name(pal), "               "};
                5'd7:  result = {"INNER NORTHEAST | ",     palette_name(pal), "                  "};
                5'd8:  result = {"INNER SOUTHEAST | ",     palette_name(pal), "                  "};
                5'd9:  result = {"OUTER EAST | ",          palette_name(pal), "                       "};
                5'd10: result = {"OUTER WEST | ",          palette_name(pal), "                       "};
                5'd11: result = {"FAR NORTH | ",           palette_name(pal), "                        "};
                5'd12: result = {"FAR SOUTH | ",           palette_name(pal), "                        "};
                5'd13: result = {"NORTHEAST BRANCH | ",    palette_name(pal), "                 "};
                default: result = {"SOUTHEAST BRANCH | ",  palette_name(pal), "                 "};
            endcase
        end else begin
            case (idx)
                5'd0:  result = {"SEAHORSE ENTRY | ",      palette_name(pal), "                   "};
                5'd1:  result = {"CARDIOID INTERIOR | ",   palette_name(pal), "                "};
                5'd2:  result = {"UPPER BOUNDARY | ",      palette_name(pal), "                   "};
                5'd3:  result = {"SEAHORSE VALLEY | ",     palette_name(pal), "                  "};
                5'd4:  result = {"UPPER DENDRITE | ",      palette_name(pal), "                   "};
                5'd5:  result = {"PERIOD-2 NECK | ",       palette_name(pal), "                    "};
                5'd6:  result = {"DEEP SEAHORSE | ",       palette_name(pal), "                    "};
                5'd7:  result = {"ELEPHANT EDGE | ",       palette_name(pal), "                    "};
                5'd8:  result = {"FILAMENT CROWN | ",      palette_name(pal), "                   "};
                5'd9:  result = {"NEEDLE CORRIDOR | ",     palette_name(pal), "                  "};
                5'd10: result = {"DEEP ELEPHANT | ",       palette_name(pal), "                    "};
                5'd11: result = {"HALO FILAMENTS | ",      palette_name(pal), "                   "};
                5'd12: result = {"CARDIOID EDGE | ",       palette_name(pal), "                    "};
                5'd13: result = {"SPIRAL VALLEY | ",       palette_name(pal), "                    "};
                5'd14: result = {"MINI-BROT | ",           palette_name(pal), "                        "};
                5'd15: result = {"DOUBLE SPIRAL | ",       palette_name(pal), "                    "};
                5'd16: result = {"ANTENNA TIP | ",         palette_name(pal), "                      "};
                5'd17: result = {"BABY MANDELBROT | ",     palette_name(pal), "                  "};
                5'd18: result = {"SEAHORSE TAIL | ",       palette_name(pal), "                    "};
                5'd19: result = {"ELEPHANT TRUNK | ",      palette_name(pal), "                   "};
                5'd20: result = {"TRIPLE SPIRAL | ",       palette_name(pal), "                    "};
                5'd21: result = {"DENDRITE JUNCTION | ",   palette_name(pal), "                "};
                5'd22: result = {"SWIRL | ",               palette_name(pal), "                            "};
                5'd23: result = {"LIGHTNING | ",            palette_name(pal), "                        "};
                default: result = {"STARFISH | ",           palette_name(pal), "                         "};
            endcase
        end
        target_poi_palette = result;
    end
endfunction


function [383:0] target_line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: target_line_data = (overlay_visible || always_show_poi) ?
                  (auto_zoom_active ?
                  target_poi_palette(fractal_type, target_idx, palette_sel) :
                  {palette_name(palette_sel), "                                    "}) :
                  TARGET_BLANK_LINE;
            3'd1: target_line_data = overlay_visible ?
                  {"X:", coord_x_sign, coord_x_int, ".", coord_x_d3, coord_x_d2, coord_x_d1, coord_x_d0,
                   " Y:", coord_y_sign, coord_y_int, ".", coord_y_d3, coord_y_d2, coord_y_d1, coord_y_d0,
                   " Zoom: X2^", zoom_tens_ascii(zoom_exp), zoom_ones_ascii(zoom_exp), ".",
                   zoom_frac_ascii(zoom_frac_tenth),
                   "               "} :
                  TARGET_BLANK_LINE;
            default: target_line_data = TARGET_BLANK_LINE;
        endcase
    end
endfunction

// ---- Status text: "C: Auto/On/Off" and "I: 512" ----
function [79:0] status_line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: begin
                case (color_cycle_active)
                    2'd0: status_line_data = " CC: Off  ";
                    default: status_line_data = " CC: On   ";
                endcase
            end
            3'd1: begin
                if (max_iter >= 12'd1000)
                    status_line_data = {" IT: ", iter_digit_3, iter_digit_2, iter_digit_1, iter_digit_0, " "};
                else
                    status_line_data = {" IT: ", iter_digit_3, iter_digit_2, iter_digit_1, "  "};
            end
            default: status_line_data = {10{8'd32}};
        endcase
    end
endfunction

function [7:0] status_line_char;
    input [2:0] line;
    input [5:0] col;
    reg [79:0] line_bits;
    begin
        line_bits = status_line_data(line);
        status_line_char = (col < STATUS_LINE_LEN) ? (line_bits >> ((STATUS_LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

function [143:0] github_line_data;
    input [2:0] line;
    begin
        case (line)
            3'd0: github_line_data = {" MiSTerbrot ", `BUILD_DATE};
            3'd1: github_line_data = "GITHUB.COM/CATALLO";
            default: github_line_data = {18{8'd32}};
        endcase
    end
endfunction

// ---- Character extraction functions ----
function [7:0] line_char;
    input [2:0] line;
    input [5:0] col;
    reg [255:0] line_bits;
    begin
        line_bits = line_data(line);
        line_char = (col < LINE_LEN) ? (line_bits >> ((LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

function [7:0] help_line_char;
    input [2:0] line;
    input [5:0] col;
    reg [127:0] line_bits;
    begin
        line_bits = help_line_data(line);
        help_line_char = (col < HELP_LINE_LEN) ? (line_bits >> ((HELP_LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

function [7:0] meta_line_char;
    input [2:0] line;
    input [5:0] col;
    reg [255:0] line_bits;
    begin
        line_bits = meta_line_data(line);
        meta_line_char = (col < LINE_LEN) ? (line_bits >> ((LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

function [7:0] github_line_char;
    input [2:0] line;
    input [5:0] col;
    reg [143:0] line_bits;
    begin
        line_bits = github_line_data(line);
        github_line_char = (col < GITHUB_LINE_LEN) ? (line_bits >> ((GITHUB_LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

function [7:0] target_line_char;
    input [2:0] line;
    input [6:0] col;
    reg [383:0] line_bits;
    begin
        line_bits = target_line_data(line);
        target_line_char = (col < TARGET_LINE_LEN) ? (line_bits >> ((TARGET_LINE_LEN - 1 - col) * 8)) : 8'd32;
    end
endfunction

// ========================================================================
// 5x5 PIXEL FONT
// Each glyph: 25 bits = {row0[4:0], row1[4:0], row2[4:0], row3[4:0], row4[4:0]}
// Row 0 is top, bit 4 is leftmost pixel.
// Designed for legibility at 320x240. Key distinctions:
//   0 has diagonal slash (vs O which is plain oval)
//   B has flat left edges (vs 8 which is rounded/symmetric)
//   5 has flat top line (vs S which curves)
//   I has symmetric serifs (vs 1 which has left-top serif only)
//   2 has curved top (vs Z which has flat top)
// ========================================================================
function [24:0] glyph_bits;
    input [6:0] ch;
    begin
        case (ch)
            // Space
            7'd32:  glyph_bits = 25'b00000_00000_00000_00000_00000;
            // Punctuation
            7'd33:  glyph_bits = 25'b00100_00100_00100_00000_00100; // !
            7'd34:  glyph_bits = 25'b01010_01010_00000_00000_00000; // "
            7'd35:  glyph_bits = 25'b01010_11111_01010_11111_01010; // #
            7'd36:  glyph_bits = 25'b01110_10100_01110_00101_01110; // $
            7'd37:  glyph_bits = 25'b11001_00010_00100_01000_10011; // %
            7'd38:  glyph_bits = 25'b01000_10100_01100_10101_01010; // &
            7'd39:  glyph_bits = 25'b00100_00100_00000_00000_00000; // '
            7'd40:  glyph_bits = 25'b00100_01000_01000_01000_00100; // (
            7'd41:  glyph_bits = 25'b01000_00100_00100_00100_01000; // )
            7'd42:  glyph_bits = 25'b00000_01010_00100_01010_00000; // *
            7'd43:  glyph_bits = 25'b00000_00100_01110_00100_00000; // +
            7'd44:  glyph_bits = 25'b00000_00000_00000_00100_01000; // ,
            7'd45:  glyph_bits = 25'b00000_00000_01110_00000_00000; // -
            7'd46:  glyph_bits = 25'b00000_00000_00000_00000_00100; // .
            7'd47:  glyph_bits = 25'b00010_00010_00100_01000_01000; // /

            // Digits (0 has slash to distinguish from O)
            7'd48:  glyph_bits = 25'b01100_10110_10010_11010_01100; // 0 (slashed)
            7'd49:  glyph_bits = 25'b01000_11000_01000_01000_11100; // 1 (left serif)
            7'd50:  glyph_bits = 25'b01100_10010_00100_01000_11110; // 2 (curved top)
            7'd51:  glyph_bits = 25'b11100_00010_01100_00010_11100; // 3
            7'd52:  glyph_bits = 25'b10010_10010_11110_00010_00010; // 4
            7'd53:  glyph_bits = 25'b11110_10000_11100_00010_11100; // 5 (flat top)
            7'd54:  glyph_bits = 25'b01100_10000_11100_10010_01100; // 6
            7'd55:  glyph_bits = 25'b11110_00010_00100_01000_01000; // 7
            7'd56:  glyph_bits = 25'b01100_10010_01100_10010_01100; // 8 (rounded)
            7'd57:  glyph_bits = 25'b01100_10010_01110_00010_01100; // 9

            // Punctuation
            7'd58:  glyph_bits = 25'b00000_00100_00000_00100_00000; // :
            7'd59:  glyph_bits = 25'b00000_00100_00000_00100_01000; // ;
            7'd60:  glyph_bits = 25'b00010_00100_01000_00100_00010; // <
            7'd61:  glyph_bits = 25'b00000_01110_00000_01110_00000; // =
            7'd62:  glyph_bits = 25'b01000_00100_00010_00100_01000; // >
            7'd63:  glyph_bits = 25'b01100_10010_00100_00000_00100; // ?
            7'd64:  glyph_bits = 25'b01100_10010_10110_10000_01110; // @

            // Uppercase A-Z
            7'd65:  glyph_bits = 25'b01100_10010_11110_10010_10010; // A
            7'd66:  glyph_bits = 25'b11110_10010_11100_10010_11110; // B (flat left)
            7'd67:  glyph_bits = 25'b01110_10000_10000_10000_01110; // C
            7'd68:  glyph_bits = 25'b11100_10010_10010_10010_11100; // D
            7'd69:  glyph_bits = 25'b11110_10000_11100_10000_11110; // E
            7'd70:  glyph_bits = 25'b11110_10000_11100_10000_10000; // F
            7'd71:  glyph_bits = 25'b01110_10000_10110_10010_01110; // G
            7'd72:  glyph_bits = 25'b10010_10010_11110_10010_10010; // H
            7'd73:  glyph_bits = 25'b01110_00100_00100_00100_01110; // I (serifs)
            7'd74:  glyph_bits = 25'b00110_00010_00010_10010_01100; // J
            7'd75:  glyph_bits = 25'b10010_10100_11000_10100_10010; // K
            7'd76:  glyph_bits = 25'b10000_10000_10000_10000_11110; // L
            7'd77:  glyph_bits = 25'b10001_11011_10101_10001_10001; // M (5-wide)
            7'd78:  glyph_bits = 25'b10010_11010_10110_10010_10010; // N
            7'd79:  glyph_bits = 25'b01100_10010_10010_10010_01100; // O (no slash)
            7'd80:  glyph_bits = 25'b11100_10010_11100_10000_10000; // P
            7'd81:  glyph_bits = 25'b01100_10010_10010_10100_01010; // Q
            7'd82:  glyph_bits = 25'b11100_10010_11100_10100_10010; // R
            7'd83:  glyph_bits = 25'b01110_10000_01100_00010_11100; // S (curved)
            7'd84:  glyph_bits = 25'b11111_00100_00100_00100_00100; // T (5-wide bar)
            7'd85:  glyph_bits = 25'b10010_10010_10010_10010_01100; // U
            7'd86:  glyph_bits = 25'b10010_10010_10010_01100_00100; // V
            7'd87:  glyph_bits = 25'b10001_10001_10101_11011_01010; // W (5-wide)
            7'd88:  glyph_bits = 25'b10001_01010_00100_01010_10001; // X (5-wide)
            7'd89:  glyph_bits = 25'b10001_01010_00100_00100_00100; // Y (5-wide)
            7'd90:  glyph_bits = 25'b11110_00010_00100_01000_11110; // Z (angular)

            // Brackets and symbols
            7'd91:  glyph_bits = 25'b01100_01000_01000_01000_01100; // [
            7'd92:  glyph_bits = 25'b01000_01000_00100_00010_00010; // backslash
            7'd93:  glyph_bits = 25'b01100_00100_00100_00100_01100; // ]
            7'd94:  glyph_bits = 25'b00100_01010_00000_00000_00000; // ^
            7'd95:  glyph_bits = 25'b00000_00000_00000_00000_11110; // _

            // Lowercase a-z: map to uppercase glyphs
            7'd97:  glyph_bits = 25'b01100_10010_11110_10010_10010; // a
            7'd98:  glyph_bits = 25'b11110_10010_11100_10010_11110; // b
            7'd99:  glyph_bits = 25'b01110_10000_10000_10000_01110; // c
            7'd100: glyph_bits = 25'b11100_10010_10010_10010_11100; // d
            7'd101: glyph_bits = 25'b11110_10000_11100_10000_11110; // e
            7'd102: glyph_bits = 25'b11110_10000_11100_10000_10000; // f
            7'd103: glyph_bits = 25'b01110_10000_10110_10010_01110; // g
            7'd104: glyph_bits = 25'b10010_10010_11110_10010_10010; // h
            7'd105: glyph_bits = 25'b01110_00100_00100_00100_01110; // i
            7'd106: glyph_bits = 25'b00110_00010_00010_10010_01100; // j
            7'd107: glyph_bits = 25'b10010_10100_11000_10100_10010; // k
            7'd108: glyph_bits = 25'b10000_10000_10000_10000_11110; // l
            7'd109: glyph_bits = 25'b10001_11011_10101_10001_10001; // m
            7'd110: glyph_bits = 25'b10010_11010_10110_10010_10010; // n
            7'd111: glyph_bits = 25'b01100_10010_10010_10010_01100; // o
            7'd112: glyph_bits = 25'b11100_10010_11100_10000_10000; // p
            7'd113: glyph_bits = 25'b01100_10010_10010_10100_01010; // q
            7'd114: glyph_bits = 25'b11100_10010_11100_10100_10010; // r
            7'd115: glyph_bits = 25'b01110_10000_01100_00010_11100; // s
            7'd116: glyph_bits = 25'b11111_00100_00100_00100_00100; // t
            7'd117: glyph_bits = 25'b10010_10010_10010_10010_01100; // u
            7'd118: glyph_bits = 25'b10010_10010_10010_01100_00100; // v
            7'd119: glyph_bits = 25'b10001_10001_10101_11011_01010; // w
            7'd120: glyph_bits = 25'b10001_01010_00100_01010_10001; // x
            7'd121: glyph_bits = 25'b10001_01010_00100_00100_00100; // y
            7'd122: glyph_bits = 25'b11110_00010_00100_01000_11110; // z

            // { | } ~
            7'd123: glyph_bits = 25'b00110_00100_01000_00100_00110; // {
            7'd124: glyph_bits = 25'b00100_00100_00100_00100_00100; // |
            7'd125: glyph_bits = 25'b01100_00100_00010_00100_01100; // }
            7'd126: glyph_bits = 25'b00000_01010_10100_00000_00000; // ~

            default: glyph_bits = 25'b00000_00000_00000_00000_00000;
        endcase
    end
endfunction

// ---- Font row: returns 5 bits for a given character and row (0-4) ----
function [4:0] font_row;
    input [6:0] ch;
    input [2:0] row;
    reg [24:0] bits;
    begin
        bits = glyph_bits(ch);
        font_row = bits >> ((3'd4 - row) * 5);
    end
endfunction

// ========================================================================
// INFO REGION - glyph pixels
// ========================================================================
wire [7:0] info_current_char = line_char(info_line_idx, info_char_col);
wire [4:0] info_glyph_row_bits = font_row(info_current_char[6:0], info_glyph_row_idx);
wire info_glyph_pixel = info_glyph_row_bits[4 - info_glyph_col];
wire show_info_text = info_text_area && info_line_text_active && (info_line_idx < INFO_LINES) && (info_char_col < LINE_LEN);

// ========================================================================
// META REGION
// ========================================================================
wire [7:0] meta_current_char = meta_line_char(meta_line_idx, meta_char_col);
wire [4:0] meta_glyph_row_bits = font_row(meta_current_char[6:0], meta_glyph_row_idx);
wire meta_glyph_pixel = meta_glyph_row_bits[4 - meta_glyph_col];
wire show_meta_text = meta_text_area && meta_line_text_active && (meta_line_idx < META_LINES) && (meta_char_col < LINE_LEN);

// ========================================================================
// HELP REGION
// ========================================================================
wire [7:0] help_current_char = help_line_char(help_line_idx, help_char_col);
wire [4:0] help_glyph_row_bits = font_row(help_current_char[6:0], help_glyph_row_idx);
wire help_glyph_pixel = help_glyph_row_bits[4 - help_glyph_col];
wire show_help_text = help_text_area && help_line_text_active && (help_line_idx < HELP_LINES) && (help_char_col < HELP_LINE_LEN);

// ========================================================================
// TARGET REGION
// ========================================================================
wire [7:0] target_current_char = target_line_char(target_line_idx, target_char_col);
wire [4:0] target_glyph_row_bits = font_row(target_current_char[6:0], target_glyph_row_idx);
wire target_glyph_pixel = target_glyph_row_bits[4 - target_glyph_col];
wire show_target_text = target_text_area && target_line_text_active && (target_line_idx < TARGET_LINES) && (target_char_col < TARGET_LINE_LEN);

// ========================================================================
// GITHUB REGION
// ========================================================================
wire [7:0] github_current_char = github_line_char(github_line_idx, github_char_col);
wire [4:0] github_glyph_row_bits = font_row(github_current_char[6:0], github_glyph_row_idx);
wire github_glyph_pixel = github_glyph_row_bits[4 - github_glyph_col];
wire show_github_text = github_text_area && github_line_text_active && (github_line_idx < GITHUB_LINES) && (github_char_col < GITHUB_LINE_LEN);

// ========================================================================
// STATUS REGION (top-right: cycling mode + iterations)
// ========================================================================
wire [7:0] status_current_char = status_line_char(status_line_idx, status_char_col);
wire [4:0] status_glyph_row_bits = font_row(status_current_char[6:0], status_glyph_row_idx);
wire status_glyph_pixel = status_glyph_row_bits[4 - status_glyph_col];
wire show_status_text = status_text_area && status_line_text_active && (status_line_idx < STATUS_LINES) && (status_char_col < STATUS_LINE_LEN);

// ========================================================================
// FINAL OUTPUT MUX
// ========================================================================
wire glyph_pixel = (show_status_text && status_glyph_pixel) ||
                   (show_info_text && info_glyph_pixel) ||
                   (show_meta_text && meta_glyph_pixel) ||
                   (show_help_text && help_glyph_pixel) ||
                   (show_target_text && target_glyph_pixel) ||
                   (show_github_text && github_glyph_pixel);
assign out_r = glyph_pixel ? 8'd255 : in_r;
assign out_g = glyph_pixel ? 8'd255 : in_g;
assign out_b = glyph_pixel ? 8'd255 : in_b;

endmodule
