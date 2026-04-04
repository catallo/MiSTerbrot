//============================================================================
// Color Mapper (v0.10)
//
// Converts 12-bit iteration count + escaped flag to 24-bit RGB color.
// Forty-two palettes are computed combinationally. Optional color cycling
// uses a 12-bit phase accumulator:
//   phase[11:4] = palette entry offset
//   phase[3:0]  = 4-bit blend fraction between adjacent entries
//
// Inside-set pixels (escaped=0) are always black.
//============================================================================

module color_mapper (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vblank_rise,

    input  wire        pixel_valid_in,
    input  wire [11:0] iter_count,
    input  wire        escaped,
    input  wire [5:0]  palette_sel,
    input  wire        cycle_enable,

    output reg         pixel_valid_out,
    output reg  [7:0]  color_r,
    output reg  [7:0]  color_g,
    output reg  [7:0]  color_b
);

reg [11:0] cycle_phase;
wire [7:0] cycle_idx_offset = cycle_enable ? cycle_phase[11:4] : 8'd0;
wire [3:0] cycle_frac       = cycle_enable ? cycle_phase[3:0]  : 4'd0;

wire [7:0] base_cidx = iter_count[7:0] + cycle_idx_offset;
wire [7:0] next_cidx = base_cidx + 8'd1;

reg [7:0] color_a_r, color_a_g, color_a_b;
reg [7:0] color_b_r, color_b_g, color_b_b;

wire [4:0] blend_a_weight = 5'd16 - {1'b0, cycle_frac};
wire [4:0] blend_b_weight = {1'b0, cycle_frac};

function [12:0] scale_u8_5bit;
    input [7:0] value;
    input [4:0] weight;
    reg   [12:0] accum;
    begin
        accum = 13'd0;
        if (weight[0]) accum = accum + {5'd0, value};
        if (weight[1]) accum = accum + {4'd0, value, 1'b0};
        if (weight[2]) accum = accum + {3'd0, value, 2'b0};
        if (weight[3]) accum = accum + {2'd0, value, 3'b0};
        if (weight[4]) accum = accum + {1'd0, value, 4'b0};
        scale_u8_5bit = accum;
    end
endfunction

function [7:0] blend_channel;
    input [7:0] a;
    input [7:0] b;
    input [3:0] frac;
    begin
        blend_channel = (scale_u8_5bit(a, 5'd16 - {1'b0, frac}) +
                         scale_u8_5bit(b, {1'b0, frac})) >> 4;
    end
endfunction

task palette_rgb;
    input  [5:0] pal;
    input  [7:0] idx;
    output [7:0] out_r;
    output [7:0] out_g;
    output [7:0] out_b;
    reg    [7:0] r0_t, s1_t, r1_t, s2_t, r2_t;
    reg    [9:0] phase10_t;
    reg    [2:0] seg_t;
    reg    [6:0] frac7_t;
    reg    [7:0] rise_t, fall_t;
    begin
        r0_t = 8'd0;
        s1_t = 8'd0;
        r1_t = 8'd0;
        s2_t = 8'd0;
        r2_t = 8'd0;
        phase10_t = 10'd0;
        seg_t = 3'd0;
        frac7_t = 7'd0;
        rise_t = 8'd0;
        fall_t = 8'd0;

        r0_t = {idx[6:0], 1'b0} + idx[6:0];
        s1_t = idx - 8'd86;
        r1_t = {s1_t[6:0], 1'b0} + s1_t[6:0];
        s2_t = idx - 8'd171;
        r2_t = {s2_t[6:0], 1'b0} + s2_t[6:0];

        out_r = 8'd0;
        out_g = 8'd0;
        out_b = 8'd0;

        case (pal)
            6'd0: begin // Rainbow
                phase10_t = {2'b0, idx} + {2'b0, idx} + {2'b0, idx}
                          + {2'b0, idx} + {2'b0, idx} + {2'b0, idx};
                seg_t = phase10_t[9:7];
                frac7_t = phase10_t[6:0];
                rise_t = {frac7_t, 1'b0};
                fall_t = 8'd255 - {frac7_t, 1'b0};
                case (seg_t)
                    3'd0: begin out_r = 8'd255; out_g = rise_t; out_b = 8'd0; end
                    3'd1: begin out_r = fall_t; out_g = 8'd255; out_b = 8'd0; end
                    3'd2: begin out_r = 8'd0; out_g = 8'd255; out_b = rise_t; end
                    3'd3: begin out_r = 8'd0; out_g = fall_t; out_b = 8'd255; end
                    3'd4: begin out_r = rise_t; out_g = 8'd0; out_b = 8'd255; end
                    3'd5: begin out_r = 8'd255; out_g = 8'd0; out_b = fall_t; end
                    6'd42: begin // Aurora Borealis: deep greens, teals, magentas, purples
                if (idx < 8'd42) begin
                    out_r = 8'd0;
                    out_g = 8'd10 + idx * 2;
                    out_b = 8'd15 + idx;
                end else if (idx < 8'd84) begin
                    out_r = 8'd0;
                    out_g = 8'd94 + idx[5:0];
                    out_b = 8'd57 + idx[5:0];
                end else if (idx < 8'd126) begin
                    out_r = (idx - 8'd84) * 3;
                    out_g = 8'd158 - idx[5:0];
                    out_b = 8'd130 + idx[5:1];
                end else if (idx < 8'd168) begin
                    out_r = 8'd126 + idx[5:0];
                    out_g = 8'd70 + idx[5:1];
                    out_b = 8'd180 - idx[5:1];
                end else if (idx < 8'd210) begin
                    out_r = 8'd190 + idx[5:2];
                    out_g = 8'd40 + idx[5:0];
                    out_b = 8'd155 + idx[5:1];
                end else begin
                    out_r = 8'd200 - idx[5:1];
                    out_g = 8'd100 - idx[5:1];
                    out_b = 8'd190 + idx[5:2];
                end
            end
            6'd43: begin // Cream: warm whites, ivories, light golds
                if (idx < 8'd64) begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd190 + idx[5:2];
                    out_b = 8'd150 + idx[5:1];
                end else if (idx < 8'd128) begin
                    out_r = 8'd216 + idx[5:2];
                    out_g = 8'd206 + idx[5:3];
                    out_b = 8'd182 - idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd232 + idx[5:3];
                    out_g = 8'd214 + idx[5:3];
                    out_b = 8'd140 + idx[5:1];
                end else begin
                    out_r = 8'd240 + idx[5:4];
                    out_g = 8'd222 + idx[5:3];
                    out_b = 8'd172 + idx[5:1];
                end
            end
            6'd44: begin // Palladium Silver: cool metallic silvers, steel blues
                if (idx < 8'd52) begin
                    out_r = 8'd60 + idx;
                    out_g = 8'd65 + idx;
                    out_b = 8'd75 + idx;
                end else if (idx < 8'd104) begin
                    out_r = 8'd112 + idx[5:1];
                    out_g = 8'd117 + idx[5:1];
                    out_b = 8'd132 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd140 + idx[5:1];
                    out_g = 8'd150 + idx[5:1];
                    out_b = 8'd170 + idx[5:2];
                end else if (idx < 8'd208) begin
                    out_r = 8'd180 + idx[5:2];
                    out_g = 8'd188 + idx[5:2];
                    out_b = 8'd200 + idx[5:3];
                end else begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd210 + idx[5:3];
                    out_b = 8'd218 + idx[5:3];
                end
            end
            6'd45: begin // Complementary: opposing hues for high contrast
                // Cycle through hue wheel, each band jumps to complement
                if (idx < 8'd32) begin       // Red → Cyan
                    out_r = 8'd200 + idx[4:0];
                    out_g = 8'd20 + idx[4:1];
                    out_b = 8'd20 + idx[4:1];
                end else if (idx < 8'd64) begin
                    out_r = 8'd20 + idx[4:1];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd96) begin  // Orange → Blue
                    out_r = 8'd220 + idx[4:2];
                    out_g = 8'd140 + idx[4:1];
                    out_b = 8'd10 + idx[4:2];
                end else if (idx < 8'd128) begin
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd40 + idx[4:2];
                    out_b = 8'd200 + idx[4:1];
                end else if (idx < 8'd160) begin // Yellow → Purple
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd220 + idx[4:3];
                    out_b = 8'd20 + idx[4:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd100 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd224) begin // Green → Magenta
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd30 + idx[4:2];
                end else begin
                    out_r = 8'd200 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end
            end
            6'd46: begin // Migraine Aura: shimmering whites, electric zigzag colors
                if (idx < 8'd32) begin       // Bright white shimmer
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd250;
                end else if (idx < 8'd64) begin  // Sharp electric blue
                    out_r = 8'd80 + idx[4:1];
                    out_g = 8'd120 + idx[4:0];
                    out_b = 8'd250;
                end else if (idx < 8'd96) begin  // Hot yellow flash
                    out_r = 8'd255;
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd40 + idx[4:1];
                end else if (idx < 8'd128) begin // Pulsing purple
                    out_r = 8'd180 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd220 + idx[4:2];
                end else if (idx < 8'd160) begin // Searing white
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd235 + idx[4:3];
                    out_b = 8'd245;
                end else if (idx < 8'd192) begin // Neon green zigzag
                    out_r = 8'd100 + idx[4:2];
                    out_g = 8'd255;
                    out_b = 8'd60 + idx[4:1];
                end else if (idx < 8'd224) begin // Throbbing magenta
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd30 + idx[4:2];
                    out_b = 8'd180 + idx[4:1];
                end else begin                   // Blinding white fade
                    out_r = 8'd250;
                    out_g = 8'd248;
                    out_b = 8'd255;
                end
            end
            default: begin out_r = 8'd255; out_g = 8'd255; out_b = 8'd255; end
                endcase
            end
            6'd1: begin // Fire
                if (idx < 8'd86) begin
                    out_r = r0_t; out_g = 8'd0; out_b = 8'd0;
                end else if (idx < 8'd171) begin
                    out_r = 8'd255; out_g = r1_t; out_b = 8'd0;
                end else begin
                    out_r = 8'd255; out_g = 8'd255; out_b = r2_t;
                end
            end
            6'd2: begin // Ocean
                if (idx < 8'd86) begin
                    out_r = 8'd0; out_g = 8'd0; out_b = r0_t;
                end else if (idx < 8'd171) begin
                    out_r = 8'd0; out_g = r1_t; out_b = 8'd255;
                end else begin
                    out_r = r2_t; out_g = 8'd255; out_b = 8'd255;
                end
            end
            6'd3: begin // Grayscale
                out_r = idx; out_g = idx; out_b = idx;
            end
            6'd4: begin // Electric
                if (idx < 8'd32) begin
                    out_r = {idx[4:0], 3'b0};
                    out_g = {idx[4:0], 3'b0};
                    out_b = 8'd128 + {idx[4:0], 2'b0};
                end else if (idx < 8'd96) begin
                    out_r = 8'd255;
                    out_g = 8'd200 - idx;
                    out_b = 8'd50;
                end else if (idx < 8'd160) begin
                    out_r = 8'd200 + (idx[5:0] >> 1);
                    out_g = 8'd180 + idx[5:0];
                    out_b = 8'd100 + idx[5:0];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = 8'd220 + idx[4:0];
                end
            end
            6'd5: begin // Neon
                if (idx < 8'd86) begin
                    out_r = r0_t; out_g = 8'd0; out_b = r0_t;
                end else if (idx < 8'd171) begin
                    out_r = 8'd255 - r1_t; out_g = r1_t; out_b = 8'd255 - r1_t;
                end else begin
                    out_r = 8'd0; out_g = 8'd255; out_b = r2_t;
                end
            end
            6'd6: begin // Pastel
                if (idx < 8'd86) begin
                    out_r = r0_t;
                    out_g = {1'b0, idx[6:0]};
                    out_b = 8'd0;
                end else if (idx < 8'd171) begin
                    out_r = 8'd160 - r1_t[7:1];
                    out_g = 8'd80 + r1_t[7:1];
                    out_b = 8'd0;
                end else begin
                    out_r = 8'd80 + r2_t[7:1];
                    out_g = 8'd200;
                    out_b = r2_t[7:1];
                end
            end
            6'd7: begin // Sunset (was Grayscale position - actually this is Ice)
                if (idx < 8'd86) begin
                    out_r = 8'd0; out_g = 8'd0; out_b = r0_t;
                end else if (idx < 8'd171) begin
                    out_r = r1_t[7:1]; out_g = r1_t; out_b = 8'd255;
                end else begin
                    out_r = 8'd128 + r2_t[7:1]; out_g = 8'd255; out_b = 8'd255;
                end
            end
            6'd8: begin // Aurora
                if (idx < 8'd86) begin
                    out_r = r0_t; out_g = 8'd0; out_b = r0_t[7:1];
                end else if (idx < 8'd171) begin
                    out_r = 8'd255; out_g = r1_t; out_b = 8'd128 - r1_t[7:1];
                end else begin
                    out_r = 8'd255; out_g = 8'd255; out_b = r2_t[7:1];
                end
            end
            6'd9: begin // Deep Sea
                if (idx < 8'd86) begin
                    out_r = 8'd0; out_g = r0_t[7:2]; out_b = r0_t;
                end else if (idx < 8'd171) begin
                    out_r = r1_t; out_g = 8'd64 + r1_t[7:1]; out_b = 8'd255;
                end else begin
                    out_r = 8'd255; out_g = 8'd192 + r2_t[7:2]; out_b = 8'd255;
                end
            end
            6'd10: begin // Candy
                if (idx < 8'd86) begin
                    out_r = 8'd0; out_g = {2'b00, r0_t[7:2]} + 8'd8; out_b = 8'd0;
                end else if (idx < 8'd171) begin
                    out_r = r1_t[7:3]; out_g = 8'd96 + r1_t[7:1]; out_b = r1_t[7:3];
                end else begin
                    out_r = 8'd128 + r2_t[7:2]; out_g = 8'd255; out_b = 8'd128 + r2_t[7:2];
                end
            end
            6'd11: begin // Matrix
                if (idx < 8'd86) begin
                    out_r = 8'd24 + r0_t[7:1];
                    out_g = 8'd10 + r0_t[7:2];
                    out_b = 8'd4 + r0_t[7:3];
                end else if (idx < 8'd171) begin
                    out_r = 8'd90 + r1_t[7:1];
                    out_g = 8'd54 + r1_t[7:2];
                    out_b = 8'd24 + r1_t[7:3];
                end else begin
                    out_r = 8'd180 + r2_t[7:2];
                    out_g = 8'd150 + r2_t[7:1];
                    out_b = 8'd120 + r2_t[7:1];
                end
            end
            6'd12: begin // Toxic
                phase10_t = {2'b0, idx} + {2'b0, idx} + {2'b0, idx} + {2'b0, idx} + {2'b0, idx};
                seg_t = phase10_t[9:7];
                frac7_t = phase10_t[6:0];
                rise_t = {frac7_t, 1'b0};
                fall_t = 8'd255 - {frac7_t, 1'b0};
                case (seg_t)
                    3'd0: begin out_r = 8'd255; out_g = rise_t; out_b = 8'd255 - rise_t; end
                    3'd1: begin out_r = fall_t; out_g = 8'd255; out_b = 8'd0; end
                    3'd2: begin out_r = 8'd0; out_g = 8'd255; out_b = rise_t; end
                    3'd3: begin out_r = rise_t; out_g = fall_t; out_b = 8'd255; end
                    3'd4: begin out_r = 8'd255; out_g = 8'd128 - r2_t[7:1]; out_b = fall_t; end
                    6'd42: begin // Aurora Borealis: deep greens, teals, magentas, purples
                if (idx < 8'd42) begin
                    out_r = 8'd0;
                    out_g = 8'd10 + idx * 2;
                    out_b = 8'd15 + idx;
                end else if (idx < 8'd84) begin
                    out_r = 8'd0;
                    out_g = 8'd94 + idx[5:0];
                    out_b = 8'd57 + idx[5:0];
                end else if (idx < 8'd126) begin
                    out_r = (idx - 8'd84) * 3;
                    out_g = 8'd158 - idx[5:0];
                    out_b = 8'd130 + idx[5:1];
                end else if (idx < 8'd168) begin
                    out_r = 8'd126 + idx[5:0];
                    out_g = 8'd70 + idx[5:1];
                    out_b = 8'd180 - idx[5:1];
                end else if (idx < 8'd210) begin
                    out_r = 8'd190 + idx[5:2];
                    out_g = 8'd40 + idx[5:0];
                    out_b = 8'd155 + idx[5:1];
                end else begin
                    out_r = 8'd200 - idx[5:1];
                    out_g = 8'd100 - idx[5:1];
                    out_b = 8'd190 + idx[5:2];
                end
            end
            6'd43: begin // Cream: warm whites, ivories, light golds
                if (idx < 8'd64) begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd190 + idx[5:2];
                    out_b = 8'd150 + idx[5:1];
                end else if (idx < 8'd128) begin
                    out_r = 8'd216 + idx[5:2];
                    out_g = 8'd206 + idx[5:3];
                    out_b = 8'd182 - idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd232 + idx[5:3];
                    out_g = 8'd214 + idx[5:3];
                    out_b = 8'd140 + idx[5:1];
                end else begin
                    out_r = 8'd240 + idx[5:4];
                    out_g = 8'd222 + idx[5:3];
                    out_b = 8'd172 + idx[5:1];
                end
            end
            6'd44: begin // Palladium Silver: cool metallic silvers, steel blues
                if (idx < 8'd52) begin
                    out_r = 8'd60 + idx;
                    out_g = 8'd65 + idx;
                    out_b = 8'd75 + idx;
                end else if (idx < 8'd104) begin
                    out_r = 8'd112 + idx[5:1];
                    out_g = 8'd117 + idx[5:1];
                    out_b = 8'd132 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd140 + idx[5:1];
                    out_g = 8'd150 + idx[5:1];
                    out_b = 8'd170 + idx[5:2];
                end else if (idx < 8'd208) begin
                    out_r = 8'd180 + idx[5:2];
                    out_g = 8'd188 + idx[5:2];
                    out_b = 8'd200 + idx[5:3];
                end else begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd210 + idx[5:3];
                    out_b = 8'd218 + idx[5:3];
                end
            end
            6'd45: begin // Complementary: opposing hues for high contrast
                // Cycle through hue wheel, each band jumps to complement
                if (idx < 8'd32) begin       // Red → Cyan
                    out_r = 8'd200 + idx[4:0];
                    out_g = 8'd20 + idx[4:1];
                    out_b = 8'd20 + idx[4:1];
                end else if (idx < 8'd64) begin
                    out_r = 8'd20 + idx[4:1];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd96) begin  // Orange → Blue
                    out_r = 8'd220 + idx[4:2];
                    out_g = 8'd140 + idx[4:1];
                    out_b = 8'd10 + idx[4:2];
                end else if (idx < 8'd128) begin
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd40 + idx[4:2];
                    out_b = 8'd200 + idx[4:1];
                end else if (idx < 8'd160) begin // Yellow → Purple
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd220 + idx[4:3];
                    out_b = 8'd20 + idx[4:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd100 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd224) begin // Green → Magenta
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd30 + idx[4:2];
                end else begin
                    out_r = 8'd200 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end
            end
            6'd46: begin // Migraine Aura: shimmering whites, electric zigzag colors
                if (idx < 8'd32) begin       // Bright white shimmer
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd250;
                end else if (idx < 8'd64) begin  // Sharp electric blue
                    out_r = 8'd80 + idx[4:1];
                    out_g = 8'd120 + idx[4:0];
                    out_b = 8'd250;
                end else if (idx < 8'd96) begin  // Hot yellow flash
                    out_r = 8'd255;
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd40 + idx[4:1];
                end else if (idx < 8'd128) begin // Pulsing purple
                    out_r = 8'd180 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd220 + idx[4:2];
                end else if (idx < 8'd160) begin // Searing white
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd235 + idx[4:3];
                    out_b = 8'd245;
                end else if (idx < 8'd192) begin // Neon green zigzag
                    out_r = 8'd100 + idx[4:2];
                    out_g = 8'd255;
                    out_b = 8'd60 + idx[4:1];
                end else if (idx < 8'd224) begin // Throbbing magenta
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd30 + idx[4:2];
                    out_b = 8'd180 + idx[4:1];
                end else begin                   // Blinding white fade
                    out_r = 8'd250;
                    out_g = 8'd248;
                    out_b = 8'd255;
                end
            end
            default: begin out_r = 8'd180; out_g = 8'd0; out_b = 8'd255; end
                endcase
            end
            6'd13: begin // Frozen
                if (idx < 8'd86) begin
                    out_r = r0_t[7:3]; out_g = 8'd0; out_b = 8'd16 + r0_t[7:2];
                end else if (idx < 8'd171) begin
                    out_r = 8'd20 + r1_t[7:2];
                    out_g = r1_t[7:3];
                    out_b = 8'd70 + r1_t[7:1];
                end else begin
                    out_r = (idx[2:0] == 3'b000) ? 8'd255 : 8'd80 + r2_t[7:2];
                    out_g = (idx[2:0] == 3'b000) ? 8'd255 : 8'd80 + r2_t[7:2];
                    out_b = (idx[2:0] == 3'b000) ? 8'd255 : 8'd120 + r2_t[7:1];
                end
            end
            6'd14: begin // Lava
                if (idx < 8'd64) begin
                    out_r = 8'd255; out_g = r0_t[7:1]; out_b = 8'd0;
                end else if (idx < 8'd128) begin
                    out_r = 8'd255 - r1_t[7:1]; out_g = 8'd255; out_b = r1_t[7:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd0; out_g = 8'd120 - r2_t[7:2]; out_b = 8'd255;
                end else begin
                    out_r = idx[5:0]; out_g = 8'd255; out_b = 8'd0;
                end
            end
            6'd15: begin // Earth
                if (idx < 8'd86) begin
                    out_r = 8'd180 + r0_t[7:2];
                    out_g = 8'd170 + r0_t[7:2];
                    out_b = 8'd110 + r0_t[7:3];
                end else if (idx < 8'd171) begin
                    out_r = 8'd210 + r1_t[7:3];
                    out_g = 8'd200 + r1_t[7:3];
                    out_b = 8'd150 + r1_t[7:2];
                end else begin
                    out_r = 8'd240 + r2_t[7:4];
                    out_g = 8'd220 + r2_t[7:3];
                    out_b = 8'd210 + r2_t[7:3];
                end
            end
            6'd16: begin // Indigo
                if (idx < 8'd86) begin
                    out_r = 8'd20 + r0_t[7:2];
                    out_g = 8'd0;
                    out_b = 8'd80 + r0_t[7:1];
                end else if (idx < 8'd171) begin
                    out_r = 8'd40 + r1_t[7:2];
                    out_g = 8'd30 + r1_t[7:3];
                    out_b = 8'd160 + r1_t[7:1];
                end else begin
                    out_r = 8'd170 + r2_t[7:2];
                    out_g = 8'd150 + r2_t[7:2];
                    out_b = 8'd220 + r2_t[7:2];
                end
            end
            6'd17: begin // 70s Retro
                if (idx < 8'd86) begin
                    out_r = 8'd120 + r0_t[7:1];
                    out_g = 8'd90 + r0_t[7:1];
                    out_b = 8'd0;
                end else if (idx < 8'd171) begin
                    out_r = 8'd255;
                    out_g = 8'd80 + r1_t[7:1];
                    out_b = 8'd80 + r1_t[7:2];
                end else begin
                    out_r = 8'd180 + r2_t[7:2];
                    out_g = 8'd80 + r2_t[7:3];
                    out_b = 8'd180 + r2_t[7:1];
                end
            end
            6'd18: begin // 90s Rave
                if (idx < 8'd64) begin
                    out_r = 8'd0;
                    out_g = 8'd255;
                    out_b = r0_t[7:2];
                end else if (idx < 8'd128) begin
                    out_r = r1_t[7:2];
                    out_g = 8'd96 + r1_t[7:3];
                    out_b = 8'd255;
                end else if (idx < 8'd192) begin
                    out_r = 8'd255;
                    out_g = 8'd0;
                    out_b = 8'd180 + r2_t[7:2];
                end else begin
                    out_r = 8'd255 - {idx[5:0], 2'b00};
                    out_g = 8'd255 - {idx[5:0], 2'b00};
                    out_b = 8'd255 - {idx[5:0], 2'b00};
                end
            end
            // Amiga removed - C64 shifts from 20 to 19
            6'd19: begin // C64
                case (idx[3:0])
                    4'h0: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    4'h1: begin out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF; end
                    4'h2: begin out_r = 8'h88; out_g = 8'h39; out_b = 8'h32; end
                    4'h3: begin out_r = 8'h67; out_g = 8'hB6; out_b = 8'hBD; end
                    4'h4: begin out_r = 8'h8B; out_g = 8'h3F; out_b = 8'h96; end
                    4'h5: begin out_r = 8'h55; out_g = 8'hA0; out_b = 8'h49; end
                    4'h6: begin out_r = 8'h40; out_g = 8'h31; out_b = 8'h8D; end
                    4'h7: begin out_r = 8'hBF; out_g = 8'hCE; out_b = 8'h72; end
                    4'h8: begin out_r = 8'h8B; out_g = 8'h54; out_b = 8'h29; end
                    4'h9: begin out_r = 8'h57; out_g = 8'h42; out_b = 8'h00; end
                    4'hA: begin out_r = 8'hB8; out_g = 8'h69; out_b = 8'h62; end
                    4'hB: begin out_r = 8'h50; out_g = 8'h50; out_b = 8'h50; end
                    4'hC: begin out_r = 8'h78; out_g = 8'h78; out_b = 8'h78; end
                    4'hD: begin out_r = 8'h94; out_g = 8'hE0; out_b = 8'h89; end
                    4'hE: begin out_r = 8'h78; out_g = 8'h69; out_b = 8'hC4; end
                    6'd42: begin // Aurora Borealis: deep greens, teals, magentas, purples
                if (idx < 8'd42) begin
                    out_r = 8'd0;
                    out_g = 8'd10 + idx * 2;
                    out_b = 8'd15 + idx;
                end else if (idx < 8'd84) begin
                    out_r = 8'd0;
                    out_g = 8'd94 + idx[5:0];
                    out_b = 8'd57 + idx[5:0];
                end else if (idx < 8'd126) begin
                    out_r = (idx - 8'd84) * 3;
                    out_g = 8'd158 - idx[5:0];
                    out_b = 8'd130 + idx[5:1];
                end else if (idx < 8'd168) begin
                    out_r = 8'd126 + idx[5:0];
                    out_g = 8'd70 + idx[5:1];
                    out_b = 8'd180 - idx[5:1];
                end else if (idx < 8'd210) begin
                    out_r = 8'd190 + idx[5:2];
                    out_g = 8'd40 + idx[5:0];
                    out_b = 8'd155 + idx[5:1];
                end else begin
                    out_r = 8'd200 - idx[5:1];
                    out_g = 8'd100 - idx[5:1];
                    out_b = 8'd190 + idx[5:2];
                end
            end
            6'd43: begin // Cream: warm whites, ivories, light golds
                if (idx < 8'd64) begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd190 + idx[5:2];
                    out_b = 8'd150 + idx[5:1];
                end else if (idx < 8'd128) begin
                    out_r = 8'd216 + idx[5:2];
                    out_g = 8'd206 + idx[5:3];
                    out_b = 8'd182 - idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd232 + idx[5:3];
                    out_g = 8'd214 + idx[5:3];
                    out_b = 8'd140 + idx[5:1];
                end else begin
                    out_r = 8'd240 + idx[5:4];
                    out_g = 8'd222 + idx[5:3];
                    out_b = 8'd172 + idx[5:1];
                end
            end
            6'd44: begin // Palladium Silver: cool metallic silvers, steel blues
                if (idx < 8'd52) begin
                    out_r = 8'd60 + idx;
                    out_g = 8'd65 + idx;
                    out_b = 8'd75 + idx;
                end else if (idx < 8'd104) begin
                    out_r = 8'd112 + idx[5:1];
                    out_g = 8'd117 + idx[5:1];
                    out_b = 8'd132 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd140 + idx[5:1];
                    out_g = 8'd150 + idx[5:1];
                    out_b = 8'd170 + idx[5:2];
                end else if (idx < 8'd208) begin
                    out_r = 8'd180 + idx[5:2];
                    out_g = 8'd188 + idx[5:2];
                    out_b = 8'd200 + idx[5:3];
                end else begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd210 + idx[5:3];
                    out_b = 8'd218 + idx[5:3];
                end
            end
            6'd45: begin // Complementary: opposing hues for high contrast
                // Cycle through hue wheel, each band jumps to complement
                if (idx < 8'd32) begin       // Red → Cyan
                    out_r = 8'd200 + idx[4:0];
                    out_g = 8'd20 + idx[4:1];
                    out_b = 8'd20 + idx[4:1];
                end else if (idx < 8'd64) begin
                    out_r = 8'd20 + idx[4:1];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd96) begin  // Orange → Blue
                    out_r = 8'd220 + idx[4:2];
                    out_g = 8'd140 + idx[4:1];
                    out_b = 8'd10 + idx[4:2];
                end else if (idx < 8'd128) begin
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd40 + idx[4:2];
                    out_b = 8'd200 + idx[4:1];
                end else if (idx < 8'd160) begin // Yellow → Purple
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd220 + idx[4:3];
                    out_b = 8'd20 + idx[4:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd100 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd224) begin // Green → Magenta
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd30 + idx[4:2];
                end else begin
                    out_r = 8'd200 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end
            end
            6'd46: begin // Migraine Aura: shimmering whites, electric zigzag colors
                if (idx < 8'd32) begin       // Bright white shimmer
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd250;
                end else if (idx < 8'd64) begin  // Sharp electric blue
                    out_r = 8'd80 + idx[4:1];
                    out_g = 8'd120 + idx[4:0];
                    out_b = 8'd250;
                end else if (idx < 8'd96) begin  // Hot yellow flash
                    out_r = 8'd255;
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd40 + idx[4:1];
                end else if (idx < 8'd128) begin // Pulsing purple
                    out_r = 8'd180 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd220 + idx[4:2];
                end else if (idx < 8'd160) begin // Searing white
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd235 + idx[4:3];
                    out_b = 8'd245;
                end else if (idx < 8'd192) begin // Neon green zigzag
                    out_r = 8'd100 + idx[4:2];
                    out_g = 8'd255;
                    out_b = 8'd60 + idx[4:1];
                end else if (idx < 8'd224) begin // Throbbing magenta
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd30 + idx[4:2];
                    out_b = 8'd180 + idx[4:1];
                end else begin                   // Blinding white fade
                    out_r = 8'd250;
                    out_g = 8'd248;
                    out_b = 8'd255;
                end
            end
            default: begin out_r = 8'h9F; out_g = 8'h9F; out_b = 8'h9F; end
                endcase
            end
            6'd20: begin // Miami
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = 8'd110 + idx[5:0];
                    out_b = 8'd199 + (idx[5:0] >> 1);
                end else if (idx < 8'd128) begin
                    out_r = 8'd255 - {idx[5:0], 2'b00};
                    out_g = 8'd255;
                    out_b = 8'd255;
                end else if (idx < 8'd192) begin
                    out_r = idx[5:0] << 2;
                    out_g = 8'd128 + idx[5:0];
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd64 + idx[5:0];
                    out_b = 8'd255 - idx[5:0];
                end
            end
            6'd21: begin // Gold
                if (idx < 8'd64) begin
                    out_r = 8'd139 + idx[5:0];
                    out_g = 8'd105 + (idx[5:0] << 1);
                    out_b = 8'd20 + idx[5:0];
                end else if (idx < 8'd128) begin
                    out_r = 8'd255;
                    out_g = 8'd215 + (idx[5:0] >> 1);
                    out_b = 8'd0 + idx[5:0];
                end else if (idx < 8'd192) begin
                    out_r = 8'd255;
                    out_g = 8'd236 + (idx[5:0] >> 1);
                    out_b = 8'd139 + idx[5:0];
                end else begin
                    out_r = 8'd255 - idx[5:0];
                    out_g = 8'd255 - (idx[5:0] >> 1);
                    out_b = 8'd240 - idx[5:0];
                end
            end
            6'd22: begin // Starlight
                if (idx < 8'd96) begin
                    out_r = 8'd10 + idx[6:1];
                    out_g = 8'd10 + idx[6:2];
                    out_b = 8'd42 + idx[6:0];
                end else if (idx < 8'd176) begin
                    out_r = 8'd45 + idx[6:1];
                    out_g = 8'd27 + idx[6:2];
                    out_b = 8'd105 + idx[6:0];
                end else if (idx[2:0] == 3'b000) begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd176 + idx[5:0];
                    out_g = 8'd196 + (idx[5:0] >> 1);
                    out_b = 8'd222 + (idx[5:0] >> 1);
                end
            end
            6'd23: begin // Nebula
                if (idx < 8'd52) begin
                    out_r = 8'd75 + idx[5:0];
                    out_g = idx[5:1];
                    out_b = 8'd130 + idx[5:1];
                end else if (idx < 8'd104) begin
                    out_r = 8'd255;
                    out_g = idx[5:0];
                    out_b = 8'd255;
                end else if (idx < 8'd156) begin
                    out_r = 8'd0;
                    out_g = 8'd128 + idx[5:0];
                    out_b = 8'd128 + (idx[5:0] >> 1);
                end else if (idx < 8'd208) begin
                    out_r = 8'd255;
                    out_g = 8'd99 + idx[5:0];
                    out_b = 8'd71 - idx[5:1];
                end else begin
                    out_r = 8'd139;
                    out_g = 8'd0 + idx[5:1];
                    out_b = idx[5:1];
                end
            end
            6'd24: begin // Silver
                if (idx < 8'd52) begin
                    out_r = 8'd47 + idx[5:1];
                    out_g = 8'd79 + idx[5:1];
                    out_b = 8'd79 + idx[5:1];
                end else if (idx < 8'd104) begin
                    out_r = 8'd112 + idx[5:1];
                    out_g = 8'd128 + idx[5:1];
                    out_b = 8'd144 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd192 + idx[5:0];
                    out_g = 8'd192 + idx[5:0];
                    out_b = 8'd192 + idx[5:0];
                end else if (idx < 8'd208) begin
                    out_r = 8'd232 + (idx[5:0] >> 1);
                    out_g = 8'd232 + (idx[5:0] >> 1);
                    out_b = 8'd232 + (idx[5:0] >> 1);
                end else begin
                    out_r = 8'd176 + idx[5:0];
                    out_g = 8'd224 + (idx[5:0] >> 1);
                    out_b = 8'd230;
                end
            end
            6'd25: begin // Akihabara
                if (idx < 8'd52) begin
                    out_r = 8'd13 + idx[5:1];
                    out_g = 8'd2 + idx[5:2];
                    out_b = 8'd33 + idx[5:1];
                end else if (idx < 8'd104) begin
                    out_r = 8'd255;
                    out_g = 8'd42 + idx[5:1];
                    out_b = 8'd109 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = idx[5:1];
                    out_g = 8'd255;
                    out_b = 8'd245;
                end else if (idx < 8'd208) begin
                    out_r = 8'd57 + idx[5:1];
                    out_g = 8'd255;
                    out_b = 8'd20 + idx[5:1];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd102 + idx[5:1];
                    out_b = 8'd0 + idx[5:2];
                end
            end
            6'd26: begin // Colorado
                if (idx < 8'd43) begin
                    out_r = 8'd63 + idx[5:1];
                    out_g = idx[5:2];
                    out_b = 8'd113 + idx[5:1];
                end else if (idx < 8'd86) begin
                    out_r = 8'd255;
                    out_g = 8'd20 + idx[5:1];
                    out_b = 8'd147;
                end else if (idx < 8'd129) begin
                    out_r = 8'd0;
                    out_g = 8'd206 + idx[5:1];
                    out_b = 8'd209;
                end else if (idx < 8'd172) begin
                    out_r = 8'd50 + idx[5:0];
                    out_g = 8'd205 + idx[5:1];
                    out_b = 8'd50 - idx[5:2];
                end else if (idx < 8'd215) begin
                    out_r = 8'd255;
                    out_g = 8'd69 + idx[5:1];
                    out_b = 8'd0;
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd215 + idx[5:1];
                    out_b = idx[5:2];
                end
            end
            6'd27: begin // XTC
                if (idx < 8'd43) begin
                    out_r = 8'd255;
                    out_g = 8'd182 + idx[5:1];
                    out_b = 8'd193 + idx[5:2];
                end else if (idx < 8'd86) begin
                    out_r = 8'd255;
                    out_g = 8'd215 + idx[5:1];
                    out_b = 8'd0 + idx[5:2];
                end else if (idx < 8'd129) begin
                    out_r = 8'd181;
                    out_g = 8'd126 + idx[5:1];
                    out_b = 8'd220 + idx[5:1];
                end else if (idx < 8'd172) begin
                    out_r = 8'd135 + idx[5:1];
                    out_g = 8'd206 + idx[5:1];
                    out_b = 8'd235;
                end else if (idx < 8'd215) begin
                    out_r = 8'd255;
                    out_g = 8'd218 + idx[5:1];
                    out_b = 8'd185 + idx[5:1];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd105 + idx[5:1];
                    out_b = 8'd180 + idx[5:1];
                end
            end
            6'd28: begin // Psilocybin
                if (idx < 8'd43) begin
                    out_r = 8'd11 + idx[5:2];
                    out_g = 8'd61 + idx[5:1];
                    out_b = 8'd11 + idx[5:2];
                end else if (idx < 8'd86) begin
                    out_r = 8'd123 + idx[5:1];
                    out_g = 8'd45 + idx[5:2];
                    out_b = 8'd139 + idx[5:1];
                end else if (idx < 8'd129) begin
                    out_r = 8'd139 + idx[5:1];
                    out_g = 8'd69 + idx[5:2];
                    out_b = 8'd19 + idx[5:2];
                end else if (idx < 8'd172) begin
                    out_r = 8'd0 + idx[5:2];
                    out_g = 8'd255;
                    out_b = 8'd127 + idx[5:2];
                end else if (idx < 8'd215) begin
                    out_r = 8'd255;
                    out_g = 8'd191 + idx[5:1];
                    out_b = 8'd0 + idx[5:2];
                end else begin
                    out_r = idx[5:2];
                    out_g = 8'd128 + idx[5:1];
                    out_b = 8'd128 + idx[5:1];
                end
            end
            6'd29: begin // HDR
                if (idx < 8'd43) begin
                    out_r = 8'd5 + idx[5:2];
                    out_g = 8'd5 + idx[5:2];
                    out_b = 8'd5 + idx[5:2];
                end else if (idx < 8'd86) begin
                    out_r = idx[5:2];
                    out_g = idx[5:2];
                    out_b = 8'd255;
                end else if (idx < 8'd129) begin
                    out_r = idx[5:2];
                    out_g = 8'd255;
                    out_b = idx[5:2];
                end else if (idx < 8'd172) begin
                    out_r = 8'd255;
                    out_g = idx[5:2];
                    out_b = idx[5:2];
                end else if (idx < 8'd215) begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = idx[5:2];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = 8'd255;
                end
            end
            6'd30: begin // THC
                if (idx < 8'd64) begin
                    out_r = 8'd8 + idx[5:2];
                    out_g = 8'd28 + idx[5:0];
                    out_b = 8'd6 + idx[5:3];
                end else if (idx < 8'd128) begin
                    out_r = 8'd64 + idx[5:1];
                    out_g = 8'd180 + idx[5:1];
                    out_b = 8'd24 + idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd210 + idx[5:1];
                    out_g = 8'd140 + idx[5:2];
                    out_b = 8'd40 + idx[5:3];
                end else begin
                    out_r = 8'd96 + idx[5:1];
                    out_g = 8'd24 + idx[5:3];
                    out_b = 8'd120 + idx[5:1];
                end
            end
            // ---- New palettes (31-41) ----
            6'd31: begin // Barbie World: hot pink -> magenta -> white -> baby blue -> pink
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = 8'd16 + idx[5:0];
                    out_b = 8'd80 + idx[5:0];
                end else if (idx < 8'd128) begin
                    out_r = 8'd255;
                    out_g = 8'd80 + {idx[5:0], 1'b0};
                    out_b = 8'd144 + idx[5:0];
                end else if (idx < 8'd192) begin
                    out_r = 8'd255 - idx[5:0];
                    out_g = 8'd208 + idx[5:1];
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd192 + idx[5:0];
                    out_g = 8'd128 - idx[5:0];
                    out_b = 8'd255 - idx[5:1];
                end
            end
            6'd32: begin // Skittles: bold saturated primaries
                if (idx < 8'd43) begin
                    out_r = 8'd255;
                    out_g = r0_t[7:2];
                    out_b = 8'd0;
                end else if (idx < 8'd86) begin
                    out_r = 8'd255 - r1_t;
                    out_g = 8'd255;
                    out_b = 8'd0;
                end else if (idx < 8'd128) begin
                    out_r = 8'd0;
                    out_g = 8'd255;
                    out_b = r2_t;
                end else if (idx < 8'd171) begin
                    out_r = 8'd0;
                    out_g = 8'd255 - r0_t;
                    out_b = 8'd255;
                end else if (idx < 8'd214) begin
                    out_r = r1_t[7:1];
                    out_g = 8'd0;
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd255;
                    out_g = r2_t[7:1];
                    out_b = 8'd255 - r2_t;
                end
            end
            6'd33: begin // Papagei (Parrot): scarlet -> cobalt -> emerald -> sun yellow
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = idx[5:1];
                    out_b = idx[5:2];
                end else if (idx < 8'd128) begin
                    out_r = 8'd255 - {idx[5:0], 2'b0};
                    out_g = idx[5:1];
                    out_b = 8'd64 + {idx[5:0], 1'b0};
                end else if (idx < 8'd192) begin
                    out_r = 8'd0;
                    out_g = 8'd64 + {idx[5:0], 1'b0};
                    out_b = 8'd255 - {idx[5:0], 1'b0};
                end else begin
                    out_r = {idx[5:0], 2'b0};
                    out_g = 8'd200 + idx[5:2];
                    out_b = 8'd128 - idx[5:0];
                end
            end
            6'd34: begin // Bubblegum: soft pastels pink -> mint -> baby blue -> lavender -> lemon
                if (idx < 8'd52) begin
                    out_r = 8'd255;
                    out_g = 8'd182 + idx[5:1];
                    out_b = 8'd193 + idx[5:1];
                end else if (idx < 8'd104) begin
                    out_r = 8'd255 - {idx[5:0], 1'b0};
                    out_g = 8'd230 + idx[5:2];
                    out_b = 8'd220 + idx[5:2];
                end else if (idx < 8'd156) begin
                    out_r = 8'd128 + idx[5:1];
                    out_g = 8'd200 + idx[5:2];
                    out_b = 8'd255;
                end else if (idx < 8'd208) begin
                    out_r = 8'd180 + idx[5:1];
                    out_g = 8'd160 + idx[5:1];
                    out_b = 8'd240 + idx[5:3];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = 8'd180 + idx[5:1];
                end
            end
            6'd35: begin // Synthwave: dark purple -> neon magenta -> cyan -> purple
                if (idx < 8'd64) begin
                    out_r = 8'd20 + {idx[5:0], 1'b0};
                    out_g = 8'd0;
                    out_b = 8'd40 + {idx[5:0], 1'b0};
                end else if (idx < 8'd128) begin
                    out_r = 8'd148 + idx[5:0];
                    out_g = 8'd0 + idx[5:1];
                    out_b = 8'd168 + idx[5:0];
                end else if (idx < 8'd192) begin
                    out_r = 8'd255 - {idx[5:0], 2'b0};
                    out_g = 8'd32 + {idx[5:0], 2'b0};
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd80 - idx[5:1];
                    out_g = 8'd255 - {idx[5:0], 1'b0};
                    out_b = 8'd255 - idx[5:0];
                end
            end
            6'd36: begin // Pop Art: bold red -> yellow -> blue -> black (Warhol-style)
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = {idx[5:0], 2'b0};
                    out_b = 8'd0;
                end else if (idx < 8'd128) begin
                    out_r = 8'd255;
                    out_g = 8'd255;
                    out_b = 8'd0;
                end else if (idx < 8'd192) begin
                    out_r = 8'd255 - {idx[5:0], 2'b0};
                    out_g = 8'd255 - {idx[5:0], 2'b0};
                    out_b = {idx[5:0], 2'b0};
                end else begin
                    out_r = 8'd0;
                    out_g = 8'd0;
                    out_b = 8'd255 - {idx[5:0], 2'b0};
                end
            end
            6'd37: begin // Tropical: hibiscus pink -> mango -> palm green -> ocean blue
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = 8'd50 + {idx[5:0], 1'b0};
                    out_b = 8'd100 + idx[5:0];
                end else if (idx < 8'd128) begin
                    out_r = 8'd255;
                    out_g = 8'd178 + idx[5:0];
                    out_b = 8'd164 - {idx[5:0], 1'b0};
                end else if (idx < 8'd192) begin
                    out_r = 8'd255 - {idx[5:0], 2'b0};
                    out_g = 8'd242 - idx[5:0];
                    out_b = 8'd36 + idx[5:0];
                end else begin
                    out_r = 8'd0;
                    out_g = 8'd178 - idx[5:0];
                    out_b = 8'd100 + {idx[5:0], 1'b0};
                end
            end
            6'd38: begin // Vaporwave: pastel pink -> turquoise -> lavender with white
                if (idx < 8'd64) begin
                    out_r = 8'd255;
                    out_g = 8'd150 + idx[5:0];
                    out_b = 8'd200 + idx[5:1];
                end else if (idx < 8'd128) begin
                    out_r = 8'd255 - {idx[5:0], 1'b0};
                    out_g = 8'd214 + idx[5:2];
                    out_b = 8'd232 + idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd128 + idx[5:0];
                    out_g = 8'd230 + idx[5:2];
                    out_b = 8'd255;
                end else begin
                    out_r = 8'd192 + idx[5:1];
                    out_g = 8'd160 + idx[5:0];
                    out_b = 8'd255;
                end
            end
            6'd39: begin // Acid: neon green -> neon yellow -> neon pink on dark
                if (idx < 8'd64) begin
                    out_r = 8'd0;
                    out_g = {idx[5:0], 2'b0};
                    out_b = 8'd0;
                end else if (idx < 8'd128) begin
                    out_r = {idx[5:0], 2'b0};
                    out_g = 8'd255;
                    out_b = 8'd0;
                end else if (idx < 8'd192) begin
                    out_r = 8'd255;
                    out_g = 8'd255 - {idx[5:0], 2'b0};
                    out_b = {idx[5:0], 1'b0};
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd0;
                    out_b = 8'd128 + idx[5:0];
                end
            end
            6'd40: begin // Morning Sun: deep navy -> rose -> peach -> golden -> white
                if (idx < 8'd52) begin
                    out_r = 8'd10 + idx[5:1];
                    out_g = 8'd5 + idx[5:2];
                    out_b = 8'd40 + {idx[5:0], 1'b0};
                end else if (idx < 8'd104) begin
                    out_r = 8'd36 + {idx[5:0], 2'b0};
                    out_g = 8'd18 + idx[5:1];
                    out_b = 8'd144 - idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd255;
                    out_g = 8'd50 + {idx[5:0], 1'b0};
                    out_b = 8'd112 + idx[5:1];
                end else if (idx < 8'd208) begin
                    out_r = 8'd255;
                    out_g = 8'd178 + idx[5:1];
                    out_b = 8'd144 + idx[5:0];
                end else begin
                    out_r = 8'd255;
                    out_g = 8'd210 + idx[5:1];
                    out_b = 8'd208 + idx[5:1];
                end
            end
            6'd41: begin // Cloudy: cool grays with blue/purple tints
                if (idx < 8'd52) begin
                    out_r = 8'd30 + idx[5:0];
                    out_g = 8'd32 + idx[5:0];
                    out_b = 8'd40 + idx[5:0];
                end else if (idx < 8'd104) begin
                    out_r = 8'd82 + idx[5:1];
                    out_g = 8'd90 + idx[5:1];
                    out_b = 8'd110 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd130 + idx[5:0];
                    out_g = 8'd138 + idx[5:0];
                    out_b = 8'd158 + idx[5:0];
                end else if (idx < 8'd208) begin
                    out_r = 8'd194 + idx[5:1];
                    out_g = 8'd202 + idx[5:1];
                    out_b = 8'd222 + idx[5:2];
                end else begin
                    out_r = 8'd226 + idx[5:2];
                    out_g = 8'd220 + idx[5:1];
                    out_b = 8'd240 + idx[5:3];
                end
            end
            6'd42: begin // Aurora Borealis: deep greens, teals, magentas, purples
                if (idx < 8'd42) begin
                    out_r = 8'd0;
                    out_g = 8'd10 + idx * 2;
                    out_b = 8'd15 + idx;
                end else if (idx < 8'd84) begin
                    out_r = 8'd0;
                    out_g = 8'd94 + idx[5:0];
                    out_b = 8'd57 + idx[5:0];
                end else if (idx < 8'd126) begin
                    out_r = (idx - 8'd84) * 3;
                    out_g = 8'd158 - idx[5:0];
                    out_b = 8'd130 + idx[5:1];
                end else if (idx < 8'd168) begin
                    out_r = 8'd126 + idx[5:0];
                    out_g = 8'd70 + idx[5:1];
                    out_b = 8'd180 - idx[5:1];
                end else if (idx < 8'd210) begin
                    out_r = 8'd190 + idx[5:2];
                    out_g = 8'd40 + idx[5:0];
                    out_b = 8'd155 + idx[5:1];
                end else begin
                    out_r = 8'd200 - idx[5:1];
                    out_g = 8'd100 - idx[5:1];
                    out_b = 8'd190 + idx[5:2];
                end
            end
            6'd43: begin // Cream: warm whites, ivories, light golds
                if (idx < 8'd64) begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd190 + idx[5:2];
                    out_b = 8'd150 + idx[5:1];
                end else if (idx < 8'd128) begin
                    out_r = 8'd216 + idx[5:2];
                    out_g = 8'd206 + idx[5:3];
                    out_b = 8'd182 - idx[5:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd232 + idx[5:3];
                    out_g = 8'd214 + idx[5:3];
                    out_b = 8'd140 + idx[5:1];
                end else begin
                    out_r = 8'd240 + idx[5:4];
                    out_g = 8'd222 + idx[5:3];
                    out_b = 8'd172 + idx[5:1];
                end
            end
            6'd44: begin // Palladium Silver: cool metallic silvers, steel blues
                if (idx < 8'd52) begin
                    out_r = 8'd60 + idx;
                    out_g = 8'd65 + idx;
                    out_b = 8'd75 + idx;
                end else if (idx < 8'd104) begin
                    out_r = 8'd112 + idx[5:1];
                    out_g = 8'd117 + idx[5:1];
                    out_b = 8'd132 + idx[5:1];
                end else if (idx < 8'd156) begin
                    out_r = 8'd140 + idx[5:1];
                    out_g = 8'd150 + idx[5:1];
                    out_b = 8'd170 + idx[5:2];
                end else if (idx < 8'd208) begin
                    out_r = 8'd180 + idx[5:2];
                    out_g = 8'd188 + idx[5:2];
                    out_b = 8'd200 + idx[5:3];
                end else begin
                    out_r = 8'd200 + idx[5:2];
                    out_g = 8'd210 + idx[5:3];
                    out_b = 8'd218 + idx[5:3];
                end
            end
            6'd45: begin // Complementary: opposing hues for high contrast
                // Cycle through hue wheel, each band jumps to complement
                if (idx < 8'd32) begin       // Red → Cyan
                    out_r = 8'd200 + idx[4:0];
                    out_g = 8'd20 + idx[4:1];
                    out_b = 8'd20 + idx[4:1];
                end else if (idx < 8'd64) begin
                    out_r = 8'd20 + idx[4:1];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd96) begin  // Orange → Blue
                    out_r = 8'd220 + idx[4:2];
                    out_g = 8'd140 + idx[4:1];
                    out_b = 8'd10 + idx[4:2];
                end else if (idx < 8'd128) begin
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd40 + idx[4:2];
                    out_b = 8'd200 + idx[4:1];
                end else if (idx < 8'd160) begin // Yellow → Purple
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd220 + idx[4:3];
                    out_b = 8'd20 + idx[4:2];
                end else if (idx < 8'd192) begin
                    out_r = 8'd100 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end else if (idx < 8'd224) begin // Green → Magenta
                    out_r = 8'd20 + idx[4:2];
                    out_g = 8'd180 + idx[4:0];
                    out_b = 8'd30 + idx[4:2];
                end else begin
                    out_r = 8'd200 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd180 + idx[4:0];
                end
            end
            6'd46: begin // Migraine Aura: shimmering whites, electric zigzag colors
                if (idx < 8'd32) begin       // Bright white shimmer
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd250;
                end else if (idx < 8'd64) begin  // Sharp electric blue
                    out_r = 8'd80 + idx[4:1];
                    out_g = 8'd120 + idx[4:0];
                    out_b = 8'd250;
                end else if (idx < 8'd96) begin  // Hot yellow flash
                    out_r = 8'd255;
                    out_g = 8'd240 + idx[4:3];
                    out_b = 8'd40 + idx[4:1];
                end else if (idx < 8'd128) begin // Pulsing purple
                    out_r = 8'd180 + idx[4:1];
                    out_g = 8'd20 + idx[4:2];
                    out_b = 8'd220 + idx[4:2];
                end else if (idx < 8'd160) begin // Searing white
                    out_r = 8'd230 + idx[4:3];
                    out_g = 8'd235 + idx[4:3];
                    out_b = 8'd245;
                end else if (idx < 8'd192) begin // Neon green zigzag
                    out_r = 8'd100 + idx[4:2];
                    out_g = 8'd255;
                    out_b = 8'd60 + idx[4:1];
                end else if (idx < 8'd224) begin // Throbbing magenta
                    out_r = 8'd240 + idx[4:3];
                    out_g = 8'd30 + idx[4:2];
                    out_b = 8'd180 + idx[4:1];
                end else begin                   // Blinding white fade
                    out_r = 8'd250;
                    out_g = 8'd248;
                    out_b = 8'd255;
                end
            end
            default: begin
                out_r = idx;
                out_g = idx;
                out_b = idx;
            end
        endcase
    end
endtask

always @(*) begin
    palette_rgb(palette_sel, base_cidx, color_a_r, color_a_g, color_a_b);
    palette_rgb(palette_sel, next_cidx, color_b_r, color_b_g, color_b_b);
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_phase      <= 12'd0;
        pixel_valid_out  <= 1'b0;
        color_r          <= 8'd0;
        color_g          <= 8'd0;
        color_b          <= 8'd0;
    end else begin
        if (cycle_enable) begin
            if (vblank_rise)
                cycle_phase <= cycle_phase + 12'd4;
        end else begin
            cycle_phase <= 12'd0;
        end

        pixel_valid_out <= pixel_valid_in;

        if (pixel_valid_in) begin
            if (escaped) begin
                color_r <= blend_channel(color_a_r, color_b_r, cycle_frac);
                color_g <= blend_channel(color_a_g, color_b_g, cycle_frac);
                color_b <= blend_channel(color_a_b, color_b_b, cycle_frac);
            end else begin
                color_r <= 8'd0;
                color_g <= 8'd0;
                color_b <= 8'd0;
            end
        end
    end
end

endmodule
