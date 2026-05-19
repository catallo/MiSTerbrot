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
    input  wire [6:0]  palette_sel,
    input  wire        cycle_enable,

    // Color Cycling submenu (OSD P2):
    //   speed_sel    [2:0] 0=Normal(+4),1=Glacial(+1),2=Slow(+2),3=Fast(+8),
    //                       4=VeryFast(+16),5=Strobe(+32),6=Hyper(+64),7=Insane(+128)
    //   direction    [1:0] 0=Forward, 1=Reverse, 2=Ping-Pong (3 unused → Forward)
    //   blend_hard   0=Smooth (fractional blend), 1=Hard step (no blend)
    //   band_mode    [1:0] 0=Off (unified phase), 1=Low Slow (low-iter half speed),
    //                       2=Low Fast (low-iter 2x speed), 3=Counter (low-iter reverse)
    input  wire [3:0]  cycle_speed_sel,
    input  wire [1:0]  cycle_direction,
    input  wire        cycle_blend_hard,
    input  wire [1:0]  cycle_band_mode,
    // Palette Transition:
    //   2'd0 = Instant (default, no crossfade)
    //   2'd1 = Crossfade       (~1 s, fade_counter -2 per vblank)
    //   2'd2 = Slow Crossfade  (~2 s, fade_counter -2 every other vblank)
    input  wire [1:0]  palette_transition_mode,

    output reg         pixel_valid_out,
    output reg  [7:0]  color_r,
    output reg  [7:0]  color_g,
    output reg  [7:0]  color_b
);

// Cycle speed → increment per vblank.  Normal = +4 (default, current behavior).
reg [11:0] cycle_inc;
always @(*) begin
    // Modem-speed themed labels — see MiSTerbrot.sv OSD list.
    // sel=0 is the displayed default (9600 baud = +6), so the list
    // starts with the default and then walks slow→fast for the rest.
    case (cycle_speed_sel)
        4'd0:  cycle_inc = 12'd6;    // 9600 baud   (Default)
        4'd1:  cycle_inc = 12'd1;    // Teletype    (slowest)
        4'd2:  cycle_inc = 12'd2;    // 300 baud
        4'd3:  cycle_inc = 12'd4;    // 1200 baud
        4'd4:  cycle_inc = 12'd5;    // 2400 baud
        4'd5:  cycle_inc = 12'd7;    // 14.4k
        4'd6:  cycle_inc = 12'd8;    // 28.8k
        4'd7:  cycle_inc = 12'd16;   // 33.6k
        4'd8:  cycle_inc = 12'd32;   // ISDN
        4'd9:  cycle_inc = 12'd64;   // DSL
        4'd10: cycle_inc = 12'd128;  // Fiber       (fastest)
        default: cycle_inc = 12'd6;
    endcase
end

// Ping-pong direction state — flips on every cycle_phase wrap when in
// Ping-Pong mode.  Forward/Reverse modes ignore this.
reg ping_dir;  // 0 = going forward, 1 = going reverse
wire forward_now = (cycle_direction == 2'd0) ? 1'b1 :
                   (cycle_direction == 2'd1) ? 1'b0 :
                   (cycle_direction == 2'd2) ? ~ping_dir : 1'b1;

// High-band phase counter (also used for Off and Counter band modes).
reg  [11:0] cycle_phase;
wire [12:0] phase_fwd = {1'b0, cycle_phase} + {1'b0, cycle_inc};
wire [12:0] phase_rev = {1'b0, cycle_phase} - {1'b0, cycle_inc};
wire        phase_overflow  = forward_now & phase_fwd[12];
wire        phase_underflow = ~forward_now & phase_rev[12];

// Low-band increment magnitude — runs in its own counter for Low Slow / Low Fast
// so that low-band pixels traverse the FULL 256-entry palette range at the
// chosen rate (rather than wrapping at 128 mid-cycle, which produced the
// "flickering" the user reported).  Counter mode reuses the high-band phase
// via inversion (~cycle_phase) so no extra counter is needed there.
reg [11:0] cycle_inc_lo;
always @(*) begin
    case (cycle_band_mode)
        2'd1: cycle_inc_lo = (cycle_inc == 12'd1) ? 12'd1 : (cycle_inc >> 1);  // Low Slow (clamped to min 1)
        2'd2: cycle_inc_lo = {cycle_inc[10:0], 1'b0};                          // Low Fast (×2; bit-shift, may saturate)
        default: cycle_inc_lo = cycle_inc;
    endcase
end
reg  [11:0] cycle_phase_lo;
wire [12:0] phase_lo_fwd = {1'b0, cycle_phase_lo} + {1'b0, cycle_inc_lo};
wire [12:0] phase_lo_rev = {1'b0, cycle_phase_lo} - {1'b0, cycle_inc_lo};
wire        phase_lo_overflow  = forward_now & phase_lo_fwd[12];
wire        phase_lo_underflow = ~forward_now & phase_lo_rev[12];

// Iter-band split: pick a phase value per pixel based on its iter band.
// "Low band" = iter_count[7]==0 (iter < 128).
wire is_low_band = ~iter_count[7];
reg [11:0] phase_for_pixel;
always @(*) begin
    case (cycle_band_mode)
        2'd0: phase_for_pixel = cycle_phase;                                          // Off — unified
        2'd1: phase_for_pixel = is_low_band ? cycle_phase_lo : cycle_phase;           // Low Slow — separate slower counter
        2'd2: phase_for_pixel = is_low_band ? cycle_phase_lo : cycle_phase;           // Low Fast — separate faster counter
        2'd3: phase_for_pixel = is_low_band ? ~cycle_phase   : cycle_phase;           // Counter — low band inverted
        default: phase_for_pixel = cycle_phase;
    endcase
end

wire [7:0] cycle_idx_offset = cycle_enable ? phase_for_pixel[11:4]                       : 8'd0;
wire [3:0] cycle_frac       = (cycle_enable & ~cycle_blend_hard) ? phase_for_pixel[3:0] : 4'd0;

wire [7:0] base_cidx = iter_count[7:0] + cycle_idx_offset;
wire [7:0] next_cidx = base_cidx + 8'd1;

// Palette Transition (crossfade) state.  pal_to is the current target
// palette (latches palette_sel); pal_from is the previous one, blended
// out as fade_counter decrements 127 → 0.
reg  [6:0] pal_from, pal_to;
reg  [6:0] fade_counter;
reg        fade_tick_div;       // halves the decrement rate for Slow Crossfade
wire       fade_active = (fade_counter != 7'd0);
// 64-level crossfade: use top 6 bits of fade_counter as the weight.  With
// dec=2 per vblank, the weight changes by 1 every vblank → 60 Hz step
// rate, visually smooth (the previous 16-step ladder ran at ~16 Hz step
// rate which read as ~10 fps choppiness).
wire [5:0] crossfade_frac = fade_counter[6:1];   // 63 → 0 across the fade

// Look up each pixel's color from BOTH palettes (FROM and TO) so we
// can crossfade.  When fade is inactive (pal_from == pal_to or
// fade_counter == 0) the FROM lookup output is unused — synthesis will
// usually optimise it away.
reg [7:0] color_a_r, color_a_g, color_a_b;          // TO   palette, base entry
reg [7:0] color_b_r, color_b_g, color_b_b;          // TO   palette, next entry
reg [7:0] color_fa_r, color_fa_g, color_fa_b;       // FROM palette, base entry
reg [7:0] color_fb_r, color_fb_g, color_fb_b;       // FROM palette, next entry

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

// 7-bit-weight scaler — used by the wider crossfade blend below.
function [14:0] scale_u8_7bit;
    input [7:0] value;
    input [6:0] weight;
    reg   [14:0] accum;
    begin
        accum = 15'd0;
        if (weight[0]) accum = accum + {7'd0, value};
        if (weight[1]) accum = accum + {6'd0, value, 1'b0};
        if (weight[2]) accum = accum + {5'd0, value, 2'b0};
        if (weight[3]) accum = accum + {4'd0, value, 3'b0};
        if (weight[4]) accum = accum + {3'd0, value, 4'b0};
        if (weight[5]) accum = accum + {2'd0, value, 5'b0};
        if (weight[6]) accum = accum + {1'd0, value, 6'b0};
        scale_u8_7bit = accum;
    end
endfunction

// 64-step crossfade blend.  frac=0 → all `a` (the TO palette),
// frac=63 → mostly `b` (the FROM palette).  Used by the palette
// transition; 4× more blend levels than blend_channel for smooth
// fades.
function [7:0] blend_channel_64;
    input [7:0] a;
    input [7:0] b;
    input [5:0] frac;
    begin
        blend_channel_64 = (scale_u8_7bit(a, 7'd64 - {1'b0, frac}) +
                            scale_u8_7bit(b, {1'b0, frac})) >> 6;
    end
endfunction

task palette_rgb;
    input  [6:0] pal;
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
            6'd3: begin // Oil Slick: iridescent film — black, violet, petrol, teal, magenta, toxic green, gold
                if (idx < 8'd42) begin                // Black -> Deep violet
                    out_r = idx;
                    out_g = 8'd0;
                    out_b = idx + idx;
                end else if (idx < 8'd86) begin       // Deep violet -> Petrol
                    out_r = 8'd50 - (idx - 8'd42);
                    out_g = 8'd10 + (idx - 8'd42);
                    out_b = 8'd82;
                end else if (idx < 8'd128) begin      // Petrol -> Teal
                    out_r = 8'd6;
                    out_g = 8'd54 + (idx - 8'd86) + (idx - 8'd86);
                    out_b = 8'd82 + (idx - 8'd86);
                end else if (idx < 8'd172) begin      // Teal -> Magenta
                    out_r = (idx - 8'd128) + (idx - 8'd128) + (idx - 8'd128) + (idx - 8'd128);
                    out_g = 8'd130 - (idx - 8'd128) - (idx - 8'd128) - (idx - 8'd128);
                    out_b = 8'd124 + ((idx - 8'd128) >> 1);
                end else if (idx < 8'd214) begin      // Magenta -> Toxic green
                    out_r = 8'd200 - (idx - 8'd172) - (idx - 8'd172);
                    out_g = 8'd30 + ((idx - 8'd172) << 2);
                    out_b = 8'd150 - (idx - 8'd172) - (idx - 8'd172);
                end else begin                         // Toxic green -> Muted gold
                    out_r = 8'd100 + (idx - 8'd214);
                    out_g = 8'd220 - (idx - 8'd214);
                    out_b = 8'd50;
                end
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
                    out_g = 8'd215;
                    out_b = 8'd0;
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
            // ---------------------------------------------------------------------
            // New palettes 47-74 (user-requested batch). Each is a 4-band gradient
            // (64 idx values per band, idx[5:0] is band-local position).
            // ---------------------------------------------------------------------
            7'd47: begin // Radioactive Glass
                if (idx < 8'd64) begin              // black -> dark green
                    out_r = 8'd0;
                    out_g = idx[5:0];
                    out_b = 8'd0;
                end else if (idx < 8'd128) begin    // dark green -> acid green
                    out_r = idx[5:0] >> 1;
                    out_g = 8'd64 + (idx[5:0] << 1);
                    out_b = idx[5:0] >> 2;
                end else if (idx < 8'd192) begin    // acid green -> yellow-green
                    out_r = 8'd32 + idx[5:0] + idx[5:0];
                    out_g = 8'd192 + (idx[5:0] >> 1);
                    out_b = 8'd16 + (idx[5:0] >> 1);
                end else begin                       // yellow-green -> pale white
                    out_r = 8'd160 + idx[5:0];
                    out_g = 8'd224 + (idx[5:0] >> 2);
                    out_b = 8'd48 + idx[5:0] + idx[5:0];
                end
            end
            7'd48: begin // Cathedral Window
                if (idx < 8'd64) begin              // ruby -> sapphire
                    out_r = 8'd200 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = idx[5:0] + idx[5:0] + idx[5:0];
                end else if (idx < 8'd128) begin    // sapphire -> emerald
                    out_r = idx[5:0] >> 2;
                    out_g = idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd200 - idx[5:0] - idx[5:0];
                end else if (idx < 8'd192) begin    // emerald -> amber
                    out_r = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd192 - idx[5:0];
                    out_b = 8'd60 - (idx[5:0] >> 1);
                end else begin                       // amber -> violet
                    out_r = 8'd208 - idx[5:0] - idx[5:0];
                    out_g = 8'd128 - idx[5:0] - idx[5:0];
                    out_b = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                end
            end
            7'd49: begin // CRT Phosphor
                if (idx < 8'd64) begin              // black -> dark phosphor
                    out_r = 8'd0;
                    out_g = idx[5:0];
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd128) begin    // dark -> phosphor green
                    out_r = idx[5:0] >> 2;
                    out_g = 8'd64 + idx[5:0] + idx[5:0];
                    out_b = 8'd8 + (idx[5:0] >> 2);
                end else if (idx < 8'd192) begin    // phosphor -> cyan-green
                    out_r = 8'd16 + (idx[5:0] >> 1);
                    out_g = 8'd192 + (idx[5:0] >> 2);
                    out_b = 8'd24 + idx[5:0] + idx[5:0];
                end else begin                       // cyan-green -> faded white
                    out_r = 8'd48 + idx[5:0] + idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 2);
                    out_b = 8'd152 + (idx[5:0] >> 1);
                end
            end
            7'd50: begin // Deep Sea Bioluminescence
                if (idx < 8'd64) begin              // near-black navy -> deep blue
                    out_r = 8'd0;
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd16 + (idx[5:0] << 1);
                end else if (idx < 8'd128) begin    // deep blue -> cyan
                    out_r = idx[5:0] >> 2;
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = 8'd144 + (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // cyan -> turquoise/green
                    out_r = 8'd16 + (idx[5:0] >> 1);
                    out_g = 8'd144 + idx[5:0];
                    out_b = 8'd176 - (idx[5:0] >> 1);
                end else begin                       // turquoise -> white spark
                    out_r = 8'd48 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 2);
                    out_b = 8'd144 + idx[5:0] + idx[5:0];
                end
            end
            7'd51: begin // Rust & Copper
                if (idx < 8'd64) begin              // dark brown -> rust red
                    out_r = 8'd40 + (idx[5:0] << 1);
                    out_g = 8'd16 + (idx[5:0] >> 1);
                    out_b = 8'd8;
                end else if (idx < 8'd128) begin    // rust -> orange copper
                    out_r = 8'd168 + (idx[5:0] >> 1);
                    out_g = 8'd48 + idx[5:0];
                    out_b = 8'd8 + (idx[5:0] >> 2);
                end else if (idx < 8'd192) begin    // copper -> tarnished gold
                    out_r = 8'd200 - (idx[5:0] >> 1);
                    out_g = 8'd112 + (idx[5:0] >> 1);
                    out_b = 8'd24 + (idx[5:0] >> 1);
                end else begin                       // gold -> patina green
                    out_r = 8'd168 - idx[5:0] - idx[5:0];
                    out_g = 8'd144 + (idx[5:0] >> 2);
                    out_b = 8'd56 + (idx[5:0] >> 1);
                end
            end
            7'd52: begin // Cyberpunk Noir
                if (idx < 8'd64) begin              // black -> dark purple
                    out_r = idx[5:0] >> 1;
                    out_g = 8'd0;
                    out_b = idx[5:0];
                end else if (idx < 8'd128) begin    // purple -> neon pink
                    out_r = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = idx[5:0];
                    out_b = 8'd64 + idx[5:0];
                end else if (idx < 8'd192) begin    // pink -> electric blue
                    out_r = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd64 + idx[5:0];
                    out_b = 8'd128 + idx[5:0] + idx[5:0];
                end else begin                       // blue -> cyan w/ green accent
                    out_r = 8'd32 + (idx[5:0] >> 1);
                    out_g = 8'd128 + idx[5:0] + idx[5:0];
                    out_b = 8'd255 - (idx[5:0] >> 2);
                end
            end
            7'd53: begin // Bone & Ink
                if (idx < 8'd64) begin              // black -> sepia
                    out_r = idx[5:0];
                    out_g = idx[5:0] >> 1;
                    out_b = idx[5:0] >> 2;
                end else if (idx < 8'd128) begin    // sepia -> ash gray
                    out_r = 8'd64 + (idx[5:0] >> 1);
                    out_g = 8'd32 + idx[5:0];
                    out_b = 8'd16 + idx[5:0] + idx[5:0];
                end else if (idx < 8'd192) begin    // ash -> ivory
                    out_r = 8'd112 + idx[5:0];
                    out_g = 8'd96 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd80 + idx[5:0];
                end else begin                       // ivory -> bone white
                    out_r = 8'd232 + (idx[5:0] >> 3);
                    out_g = 8'd224 + (idx[5:0] >> 3);
                    out_b = 8'd200 + (idx[5:0] >> 2);
                end
            end
            7'd54: begin // Solar Flare
                if (idx < 8'd64) begin              // dark red-brown -> crimson
                    out_r = 8'd60 + (idx[5:0] << 1);
                    out_g = 8'd8 + (idx[5:0] >> 2);
                    out_b = 8'd16 - (idx[5:0] >> 3);
                end else if (idx < 8'd128) begin    // crimson -> orange
                    out_r = 8'd188 + idx[5:0];
                    out_g = 8'd24 + idx[5:0] + idx[5:0];
                    out_b = 8'd8 + (idx[5:0] >> 3);
                end else if (idx < 8'd192) begin    // orange -> yellow
                    out_r = 8'd252;
                    out_g = 8'd152 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd16 + idx[5:0];
                end else begin                       // yellow -> white + violet edge
                    out_r = 8'd252 - (idx[5:0] >> 3);
                    out_g = 8'd248 + (idx[5:0] >> 4);
                    out_b = 8'd80 + idx[5:0] + idx[5:0];
                end
            end
            7'd55: begin // Arctic Plasma
                if (idx < 8'd64) begin              // midnight blue -> icy blue
                    out_r = idx[5:0] >> 1;
                    out_g = 8'd16 + idx[5:0];
                    out_b = 8'd64 + idx[5:0] + idx[5:0];
                end else if (idx < 8'd128) begin    // icy blue -> pale cyan
                    out_r = 8'd32 + idx[5:0];
                    out_g = 8'd80 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd192 + (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // pale cyan -> white
                    out_r = 8'd96 + idx[5:0] + idx[5:0];
                    out_g = 8'd176 + idx[5:0];
                    out_b = 8'd224 + (idx[5:0] >> 2);
                end else begin                       // white -> mint w/ faint violet
                    out_r = 8'd224 - (idx[5:0] >> 1);
                    out_g = 8'd240 + (idx[5:0] >> 4);
                    out_b = 8'd240 - (idx[5:0] >> 2);
                end
            end
            7'd56: begin // Toxic Candy
                if (idx < 8'd64) begin              // dark purple -> hot pink
                    out_r = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd48 + idx[5:0];
                end else if (idx < 8'd128) begin    // pink -> lime
                    out_r = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd112 - idx[5:0];
                end else if (idx < 8'd192) begin    // lime -> cyan
                    out_r = 8'd32 + (idx[5:0] >> 1);
                    out_g = 8'd208 - (idx[5:0] >> 2);
                    out_b = 8'd48 + idx[5:0] + idx[5:0] + idx[5:0];
                end else begin                       // cyan -> yellow/orange
                    out_r = 8'd64 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd192 + (idx[5:0] >> 2);
                    out_b = 8'd240 - idx[5:0] - idx[5:0] - idx[5:0];
                end
            end
            7'd57: begin // Old Terminal Amber
                if (idx < 8'd64) begin              // black -> dark brown
                    out_r = idx[5:0] + (idx[5:0] >> 1);
                    out_g = idx[5:0] >> 1;
                    out_b = 8'd0;
                end else if (idx < 8'd128) begin    // dark brown -> amber
                    out_r = 8'd96 + idx[5:0] + idx[5:0];
                    out_g = 8'd32 + idx[5:0];
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd192) begin    // amber -> orange bright
                    out_r = 8'd220 + (idx[5:0] >> 2);
                    out_g = 8'd96 + idx[5:0];
                    out_b = 8'd8 + (idx[5:0] >> 2);
                end else begin                       // orange -> warm cream
                    out_r = 8'd232 + (idx[5:0] >> 3);
                    out_g = 8'd160 + idx[5:0];
                    out_b = 8'd24 + idx[5:0] + idx[5:0];
                end
            end
            7'd58: begin // Alien Coral Reef
                if (idx < 8'd64) begin              // black-blue -> coral red
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd64 - idx[5:0];
                end else if (idx < 8'd128) begin    // coral -> turquoise
                    out_r = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] + idx[5:0];
                end else if (idx < 8'd192) begin    // turquoise -> purple
                    out_r = 8'd16 + idx[5:0] + idx[5:0];
                    out_g = 8'd144 - idx[5:0];
                    out_b = 8'd128 + idx[5:0];
                end else begin                       // purple -> yellow-green w/ cyan
                    out_r = 8'd144 - (idx[5:0] >> 1);
                    out_g = 8'd80 + idx[5:0] + idx[5:0];
                    out_b = 8'd192 - (idx[5:0] >> 1);
                end
            end
            7'd59: begin // Black Hole Accretion
                if (idx < 8'd64) begin              // black -> deep violet
                    out_r = idx[5:0] >> 1;
                    out_g = idx[5:0] >> 2;
                    out_b = idx[5:0];
                end else if (idx < 8'd128) begin    // violet -> hot orange
                    out_r = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = 8'd64 - idx[5:0];
                end else if (idx < 8'd192) begin    // orange -> white
                    out_r = 8'd224 + (idx[5:0] >> 2);
                    out_g = 8'd144 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = idx[5:0] + idx[5:0] + idx[5:0];
                end else begin                       // white -> electric blue / red edge
                    out_r = 8'd240 - idx[5:0] - idx[5:0];
                    out_g = 8'd240 - idx[5:0] - idx[5:0];
                    out_b = 8'd192 + (idx[5:0] >> 1);
                end
            end
            7'd60: begin // Infrared Camera
                if (idx < 8'd64) begin              // black -> violet
                    out_r = idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = idx[5:0] + idx[5:0];
                end else if (idx < 8'd128) begin    // violet -> red
                    out_r = 8'd64 + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 1;
                    out_b = 8'd128 - idx[5:0];
                end else if (idx < 8'd192) begin    // red -> orange/yellow
                    out_r = 8'd192 + (idx[5:0] >> 2);
                    out_g = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] >> 3;
                end else begin                       // yellow -> white
                    out_r = 8'd224 + (idx[5:0] >> 2);
                    out_g = 8'd224 + (idx[5:0] >> 3);
                    out_b = 8'd8 + idx[5:0] + idx[5:0] + idx[5:0];
                end
            end
            7'd61: begin // Pearlescent
                if (idx < 8'd64) begin              // pearl white -> pale rose
                    out_r = 8'd240 + (idx[5:0] >> 4);
                    out_g = 8'd224 - (idx[5:0] >> 2);
                    out_b = 8'd216 - (idx[5:0] >> 2);
                end else if (idx < 8'd128) begin    // rose -> mint
                    out_r = 8'd248 - idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 1);
                    out_b = 8'd200 + (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // mint -> light blue
                    out_r = 8'd184 - (idx[5:0] >> 1);
                    out_g = 8'd240 - (idx[5:0] >> 2);
                    out_b = 8'd232 + (idx[5:0] >> 3);
                end else begin                       // blue -> soft gold/silver
                    out_r = 8'd152 + idx[5:0];
                    out_g = 8'd224 - (idx[5:0] >> 3);
                    out_b = 8'd248 - idx[5:0];
                end
            end
            7'd62: begin // Data Center Night
                if (idx < 8'd64) begin              // black -> slate blue
                    out_r = idx[5:0] >> 2;
                    out_g = idx[5:0] >> 1;
                    out_b = 8'd16 + idx[5:0];
                end else if (idx < 8'd128) begin    // slate -> cold gray
                    out_r = 8'd16 + idx[5:0];
                    out_g = 8'd32 + idx[5:0];
                    out_b = 8'd80 + (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // gray -> LED green
                    out_r = 8'd80 - (idx[5:0] >> 1);
                    out_g = 8'd96 + idx[5:0] + idx[5:0];
                    out_b = 8'd112 - idx[5:0];
                end else begin                       // green -> status cyan / white
                    out_r = 8'd48 + idx[5:0] + idx[5:0];
                    out_g = 8'd224 + (idx[5:0] >> 3);
                    out_b = 8'd48 + idx[5:0] + idx[5:0] + idx[5:0];
                end
            end
            7'd63: begin // Lava Lamp
                if (idx < 8'd64) begin              // dark purple -> red
                    out_r = 8'd48 + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd64 - idx[5:0];
                end else if (idx < 8'd128) begin    // red -> orange
                    out_r = 8'd176 + (idx[5:0] >> 1);
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd192) begin    // orange -> pink
                    out_r = 8'd208 + (idx[5:0] >> 2);
                    out_g = 8'd144 - (idx[5:0] >> 1);
                    out_b = 8'd8 + idx[5:0] + idx[5:0];
                end else begin                       // pink -> cream / muted yellow
                    out_r = 8'd224 + (idx[5:0] >> 3);
                    out_g = 8'd112 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd136 - idx[5:0];
                end
            end
            7'd64: begin // Monochrome Brutalist
                if (idx < 8'd64) begin              // black -> charcoal
                    out_r = idx[5:0];
                    out_g = idx[5:0];
                    out_b = idx[5:0];
                end else if (idx < 8'd128) begin    // charcoal -> gray
                    out_r = 8'd64 + idx[5:0];
                    out_g = 8'd64 + idx[5:0];
                    out_b = 8'd64 + idx[5:0];
                end else if (idx < 8'd192) begin    // gray -> light gray (with subtle magenta accent)
                    out_r = 8'd128 + idx[5:0];
                    out_g = 8'd128 + idx[5:0] - (idx[5:0] >> 3);
                    out_b = 8'd128 + idx[5:0];
                end else begin                       // light -> white
                    out_r = 8'd192 + (idx[5:0] >> 1);
                    out_g = 8'd192 + (idx[5:0] >> 1);
                    out_b = 8'd192 + (idx[5:0] >> 1);
                end
            end
            7'd65: begin // Event Horizon
                if (idx < 8'd64) begin              // absolute black -> violet
                    out_r = idx[5:0] >> 2;
                    out_g = 8'd0;
                    out_b = idx[5:0];
                end else if (idx < 8'd128) begin    // violet -> blue-white
                    out_r = 8'd16 + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] + idx[5:0];
                    out_b = 8'd64 + idx[5:0] + idx[5:0];
                end else if (idx < 8'd192) begin    // blue-white -> orange
                    out_r = 8'd144 + idx[5:0] + idx[5:0];
                    out_g = 8'd128 + (idx[5:0] >> 1);
                    out_b = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                end else begin                       // orange -> red collapse
                    out_r = 8'd232 - (idx[5:0] >> 1);
                    out_g = 8'd160 - idx[5:0] - idx[5:0];
                    out_b = idx[5:0] >> 3;
                end
            end
            7'd66: begin // Psychedelic Circuit
                if (idx < 8'd64) begin              // black -> neon green
                    out_r = 8'd0;
                    out_g = idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] >> 2;
                end else if (idx < 8'd128) begin    // green -> purple
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_b = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                end else if (idx < 8'd192) begin    // purple -> cyan
                    out_r = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd208 + (idx[5:0] >> 2);
                end else begin                       // cyan -> magenta / white
                    out_r = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd192 - idx[5:0];
                    out_b = 8'd255 - (idx[5:0] >> 3);
                end
            end
            7'd67: begin // Desert Mirage
                if (idx < 8'd64) begin              // dark umber -> sand
                    out_r = 8'd40 + idx[5:0] + idx[5:0];
                    out_g = 8'd24 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd16 + idx[5:0];
                end else if (idx < 8'd128) begin    // sand -> gold
                    out_r = 8'd168 + (idx[5:0] >> 1);
                    out_g = 8'd120 + idx[5:0];
                    out_b = 8'd80 - (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // gold -> dusty rose
                    out_r = 8'd200 + (idx[5:0] >> 2);
                    out_g = 8'd184 - idx[5:0];
                    out_b = 8'd48 + idx[5:0] + idx[5:0];
                end else begin                       // rose -> pale blue / white heat
                    out_r = 8'd216 - (idx[5:0] >> 1);
                    out_g = 8'd120 + idx[5:0] + idx[5:0];
                    out_b = 8'd176 + (idx[5:0] >> 1);
                end
            end
            7'd68: begin // Blood Moon
                if (idx < 8'd64) begin              // black -> dark maroon
                    out_r = idx[5:0] + (idx[5:0] >> 1);
                    out_g = idx[5:0] >> 3;
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd128) begin    // maroon -> crimson
                    out_r = 8'd96 + idx[5:0] + idx[5:0];
                    out_g = 8'd8 + (idx[5:0] >> 2);
                    out_b = 8'd8 + (idx[5:0] >> 3);
                end else if (idx < 8'd192) begin    // crimson -> copper red
                    out_r = 8'd224 + (idx[5:0] >> 3);
                    out_g = 8'd24 + idx[5:0] + (idx[5:0] >> 1);
                    out_b = 8'd16 + (idx[5:0] >> 1);
                end else begin                       // copper -> pale moon-gray
                    out_r = 8'd224 - (idx[5:0] >> 2);
                    out_g = 8'd120 + idx[5:0];
                    out_b = 8'd48 + idx[5:0] + idx[5:0];
                end
            end
            7'd69: begin // Quantum Foam
                if (idx < 8'd64) begin              // black -> electric blue
                    out_r = idx[5:0] >> 2;
                    out_g = idx[5:0];
                    out_b = idx[5:0] + idx[5:0] + idx[5:0];
                end else if (idx < 8'd128) begin    // blue -> cyan/pale green
                    out_r = 8'd16 + idx[5:0];
                    out_g = 8'd64 + idx[5:0] + idx[5:0];
                    out_b = 8'd192 - (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // cyan -> violet
                    out_r = 8'd80 + idx[5:0] + idx[5:0];
                    out_g = 8'd192 - idx[5:0] - idx[5:0];
                    out_b = 8'd160 + idx[5:0];
                end else begin                       // violet -> white spark
                    out_r = 8'd208 + (idx[5:0] >> 2);
                    out_g = 8'd64 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd224 + (idx[5:0] >> 3);
                end
            end
            7'd70: begin // Hypernova Candy
                if (idx < 8'd64) begin              // black -> hot pink
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd32 + idx[5:0] + (idx[5:0] >> 1);
                end else if (idx < 8'd128) begin    // pink -> laser cyan
                    out_r = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd128 + idx[5:0] + (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // cyan -> electric yellow
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 2);
                    out_b = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                end else begin                       // yellow -> neon orange / white
                    out_r = 8'd192 + idx[5:0];
                    out_g = 8'd224 - idx[5:0];
                    out_b = 8'd32 + idx[5:0] + idx[5:0];
                end
            end
            7'd71: begin // Cyber Dragon
                if (idx < 8'd64) begin              // black -> emerald green
                    out_r = idx[5:0] >> 2;
                    out_g = idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] >> 1;
                end else if (idx < 8'd128) begin    // emerald -> toxic lime
                    out_r = 8'd16 + idx[5:0] + idx[5:0];
                    out_g = 8'd192 + (idx[5:0] >> 2);
                    out_b = 8'd32 - (idx[5:0] >> 3);
                end else if (idx < 8'd192) begin    // lime -> violet
                    out_r = 8'd144 + (idx[5:0] >> 1);
                    out_g = 8'd208 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_b = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                end else begin                       // violet -> magenta / orange flare
                    out_r = 8'd176 + idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                end
            end
            7'd72: begin // Laser Carnival
                if (idx < 8'd64) begin              // deep purple -> neon red
                    out_r = 8'd64 + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd64 - (idx[5:0] >> 1);
                end else if (idx < 8'd128) begin    // red -> cyan
                    out_r = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                end else if (idx < 8'd192) begin    // cyan -> lime
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 2);
                    out_b = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                end else begin                       // lime -> yellow / white
                    out_r = 8'd192 + (idx[5:0] >> 1);
                    out_g = 8'd240 + (idx[5:0] >> 4);
                    out_b = 8'd32 + idx[5:0] + idx[5:0];
                end
            end
            7'd73: begin // Glitch Prism
                if (idx < 8'd64) begin              // black -> RGB red
                    out_r = idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = idx[5:0] >> 3;
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd128) begin    // red -> RGB green (sharp transition)
                    out_r = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = idx[5:0] + idx[5:0] + idx[5:0];
                    out_b = idx[5:0] >> 3;
                end else if (idx < 8'd192) begin    // green -> RGB blue
                    out_r = idx[5:0] >> 3;
                    out_g = 8'd192 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_b = idx[5:0] + idx[5:0] + idx[5:0];
                end else begin                       // blue -> magenta / white
                    out_r = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd16 + idx[5:0] + idx[5:0];
                    out_b = 8'd192 + (idx[5:0] >> 1);
                end
            end
            7'd74: begin // Plasma Rave
                if (idx < 8'd64) begin              // black -> ultraviolet / neon blue
                    out_r = idx[5:0] + (idx[5:0] >> 1);
                    out_g = idx[5:0] >> 2;
                    out_b = idx[5:0] + idx[5:0] + idx[5:0];
                end else if (idx < 8'd128) begin    // blue -> hot pink
                    out_r = 8'd96 + idx[5:0] + idx[5:0];
                    out_g = 8'd16 + idx[5:0];
                    out_b = 8'd192 - (idx[5:0] >> 1);
                end else if (idx < 8'd192) begin    // pink -> acid green
                    out_r = 8'd224 - idx[5:0] - idx[5:0] - idx[5:0];
                    out_g = 8'd80 + idx[5:0] + idx[5:0];
                    out_b = 8'd160 - idx[5:0] - idx[5:0];
                end else begin                       // green -> bright orange / white
                    out_r = 8'd32 + idx[5:0] + idx[5:0] + idx[5:0];
                    out_g = 8'd208 + (idx[5:0] >> 2);
                    out_b = 8'd32 + idx[5:0];
                end
            end
            // ---------------------------------------------------------------------
            // Hard-LUT palettes 75-89 — C64-style discrete colour tables.
            // Lookup by idx[1:0]/[2:0]/[3:0] for 4/8/16-step jumps (no blending).
            // ---------------------------------------------------------------------
            7'd75: begin // Game Boy: 4 olive shades
                case (idx[1:0])
                    2'd0: begin out_r = 8'h0F; out_g = 8'h38; out_b = 8'h0F; end
                    2'd1: begin out_r = 8'h30; out_g = 8'h62; out_b = 8'h30; end
                    2'd2: begin out_r = 8'h8B; out_g = 8'hAC; out_b = 8'h0F; end
                    2'd3: begin out_r = 8'h9B; out_g = 8'hBC; out_b = 8'h0F; end
                endcase
            end
            7'd76: begin // NES Castlevania
                case (idx[3:0])
                    4'h0: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    4'h1: begin out_r = 8'h44; out_g = 8'h00; out_b = 8'h60; end
                    4'h2: begin out_r = 8'hA8; out_g = 8'h10; out_b = 8'h00; end
                    4'h3: begin out_r = 8'h78; out_g = 8'h78; out_b = 8'h78; end
                    4'h4: begin out_r = 8'hF8; out_g = 8'hF8; out_b = 8'hF8; end
                    4'h5: begin out_r = 8'h6C; out_g = 8'h00; out_b = 8'h00; end
                    4'h6: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h6C; end
                    4'h7: begin out_r = 8'h80; out_g = 8'h20; out_b = 8'h20; end
                    4'h8: begin out_r = 8'h20; out_g = 8'h00; out_b = 8'h40; end
                    4'h9: begin out_r = 8'hC0; out_g = 8'h40; out_b = 8'h00; end
                    4'hA: begin out_r = 8'h40; out_g = 8'h40; out_b = 8'h40; end
                    4'hB: begin out_r = 8'hA0; out_g = 8'hA0; out_b = 8'hA0; end
                    4'hC: begin out_r = 8'h60; out_g = 8'h00; out_b = 8'h20; end
                    4'hD: begin out_r = 8'h00; out_g = 8'h40; out_b = 8'h00; end
                    4'hE: begin out_r = 8'h40; out_g = 8'h20; out_b = 8'h00; end
                    4'hF: begin out_r = 8'h10; out_g = 8'h10; out_b = 8'h10; end
                endcase
            end
            7'd77: begin // Embers: smooth red->amber + 1-in-16 white spark
                if (idx[3:0] == 4'h0) begin
                    out_r = 8'hFF; out_g = 8'hF8; out_b = 8'hD0;
                end else if (idx < 8'd96) begin
                    out_r = 8'd20 + idx + idx;
                    out_g = idx >> 2;
                    out_b = 8'h00;
                end else if (idx < 8'd180) begin
                    out_r = 8'hFF;
                    out_g = (idx - 8'd96) + (idx - 8'd96) + (idx - 8'd96);
                    out_b = idx >> 4;
                end else begin
                    out_r = 8'hFF;
                    out_g = 8'hC0 + ((idx - 8'd180) >> 1);
                    out_b = 8'd16 + (idx - 8'd180);
                end
            end
            7'd78: begin // ZX Spectrum (8 std + 8 bright)
                case (idx[3:0])
                    4'h0: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    4'h1: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'hD7; end
                    4'h2: begin out_r = 8'hD7; out_g = 8'h00; out_b = 8'h00; end
                    4'h3: begin out_r = 8'hD7; out_g = 8'h00; out_b = 8'hD7; end
                    4'h4: begin out_r = 8'h00; out_g = 8'hD7; out_b = 8'h00; end
                    4'h5: begin out_r = 8'h00; out_g = 8'hD7; out_b = 8'hD7; end
                    4'h6: begin out_r = 8'hD7; out_g = 8'hD7; out_b = 8'h00; end
                    4'h7: begin out_r = 8'hD7; out_g = 8'hD7; out_b = 8'hD7; end
                    4'h8: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    4'h9: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'hFF; end
                    4'hA: begin out_r = 8'hFF; out_g = 8'h00; out_b = 8'h00; end
                    4'hB: begin out_r = 8'hFF; out_g = 8'h00; out_b = 8'hFF; end
                    4'hC: begin out_r = 8'h00; out_g = 8'hFF; out_b = 8'h00; end
                    4'hD: begin out_r = 8'h00; out_g = 8'hFF; out_b = 8'hFF; end
                    4'hE: begin out_r = 8'hFF; out_g = 8'hFF; out_b = 8'h00; end
                    4'hF: begin out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF; end
                endcase
            end
            7'd79: begin // CGA Magenta (4 colours)
                case (idx[1:0])
                    2'd0: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    2'd1: begin out_r = 8'h55; out_g = 8'hFF; out_b = 8'hFF; end
                    2'd2: begin out_r = 8'hFF; out_g = 8'h55; out_b = 8'hFF; end
                    2'd3: begin out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF; end
                endcase
            end
            7'd80: begin // Strobe Police: dark navy + 1-in-8 red + 1-in-16 blue + 1-in-32 white
                if (idx[2:0] == 3'b000) begin
                    out_r = 8'hFF; out_g = 8'h10; out_b = 8'h10;
                end else if (idx[3:0] == 4'b0100) begin
                    out_r = 8'h20; out_g = 8'h30; out_b = 8'hFF;
                end else if (idx[4:0] == 5'd11) begin
                    out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF;
                end else begin
                    out_r = 8'd16 + (idx >> 3);
                    out_g = 8'd16 + (idx >> 3);
                    out_b = 8'd40 + (idx >> 1);
                end
            end
            7'd81: begin // Halloween Strobe: purple->orange smooth + 2-in-8 lime double-pulse + 1-in-32 white skeleton
                if (idx[2:0] == 3'b000 || idx[2:0] == 3'b001) begin
                    out_r = 8'h40; out_g = 8'hFF; out_b = 8'h00;
                end else if (idx[4:0] == 5'd17) begin
                    out_r = 8'hFF; out_g = 8'hF8; out_b = 8'hF0;
                end else if (idx < 8'd128) begin
                    out_r = 8'd32 + (idx >> 2);
                    out_g = idx >> 4;
                    out_b = 8'd40 + (idx >> 1);
                end else begin
                    out_r = 8'hC0 + ((idx - 8'd128) >> 2);
                    out_g = 8'd40 + ((idx - 8'd128) >> 1);
                    out_b = 8'd80 - ((idx - 8'd128) >> 2);
                end
            end
            7'd82: begin // Traffic Lights: dim base + 1-in-8 bright flash, colour follows band
                if (idx[2:0] == 3'b000) begin
                    if (idx < 8'd86) begin
                        out_r = 8'hFF; out_g = 8'h10; out_b = 8'h10;
                    end else if (idx < 8'd171) begin
                        out_r = 8'hFF; out_g = 8'hE0; out_b = 8'h00;
                    end else begin
                        out_r = 8'h10; out_g = 8'hE0; out_b = 8'h10;
                    end
                end else if (idx < 8'd86) begin
                    out_r = 8'd60 + (idx >> 1);
                    out_g = 8'd10 + (idx >> 4);
                    out_b = idx >> 4;
                end else if (idx < 8'd171) begin
                    out_r = 8'd80 + ((idx - 8'd86) >> 2);
                    out_g = 8'd60 + ((idx - 8'd86) >> 1);
                    out_b = idx >> 5;
                end else begin
                    out_r = idx >> 5;
                    out_g = 8'd80 + ((idx - 8'd171) >> 1);
                    out_b = (idx - 8'd171) >> 4;
                end
            end
            7'd83: begin // SMPTE Color Bars
                case (idx[2:0])
                    3'd0: begin out_r = 8'hC0; out_g = 8'hC0; out_b = 8'hC0; end
                    3'd1: begin out_r = 8'hC0; out_g = 8'hC0; out_b = 8'h00; end
                    3'd2: begin out_r = 8'h00; out_g = 8'hC0; out_b = 8'hC0; end
                    3'd3: begin out_r = 8'h00; out_g = 8'hC0; out_b = 8'h00; end
                    3'd4: begin out_r = 8'hC0; out_g = 8'h00; out_b = 8'hC0; end
                    3'd5: begin out_r = 8'hC0; out_g = 8'h00; out_b = 8'h00; end
                    3'd6: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'hC0; end
                    3'd7: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                endcase
            end
            7'd84: begin // Pixel Sprite (8-bit hero)
                case (idx[2:0])
                    3'd0: begin out_r = 8'h00; out_g = 8'h00; out_b = 8'h00; end
                    3'd1: begin out_r = 8'hF8; out_g = 8'hB8; out_b = 8'h88; end
                    3'd2: begin out_r = 8'hD8; out_g = 8'h28; out_b = 8'h00; end
                    3'd3: begin out_r = 8'h78; out_g = 8'h08; out_b = 8'h00; end
                    3'd4: begin out_r = 8'h28; out_g = 8'h28; out_b = 8'hA8; end
                    3'd5: begin out_r = 8'h08; out_g = 8'h08; out_b = 8'h48; end
                    3'd6: begin out_r = 8'h78; out_g = 8'h38; out_b = 8'h00; end
                    3'd7: begin out_r = 8'hF8; out_g = 8'hF8; out_b = 8'hF8; end
                endcase
            end
            7'd85: begin // Vintage Poster: avocado->burnt orange smooth + 1-in-32 mustard burst
                if (idx[4:0] == 5'b00000) begin
                    out_r = 8'hF0; out_g = 8'hC0; out_b = 8'h20;
                end else if (idx < 8'd128) begin
                    out_r = 8'd80 + (idx[5:0] >> 1);
                    out_g = 8'd100 + idx[5:0];
                    out_b = 8'd20 + (idx[5:0] >> 2);
                end else begin
                    out_r = 8'd180 + ((idx - 8'd128) >> 2);
                    out_g = 8'd80 + ((idx - 8'd128) >> 1);
                    out_b = 8'd20 + ((idx - 8'd128) >> 3);
                end
            end
            7'd86: begin // Casino Slots: gold base + 1-in-8 cherry red + 1-in-16 white jackpot
                if (idx[3:0] == 4'b0000) begin
                    out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF;
                end else if (idx[2:0] == 3'b100) begin
                    out_r = 8'hE0; out_g = 8'h00; out_b = 8'h20;
                end else begin
                    out_r = 8'd180 + (idx[5:0] >> 1);
                    out_g = 8'd140 + (idx[5:0] >> 1);
                    out_b = 8'd16 + (idx[5:0] >> 3);
                end
            end
            7'd87: begin // Neon Tubes: dark blue->hot pink smooth + 1-in-4 cyan flash
                if (idx[1:0] == 2'b00) begin
                    out_r = 8'h00; out_g = 8'hFF; out_b = 8'hF8;
                end else if (idx < 8'd128) begin
                    out_r = 8'd16 + (idx[5:0] >> 1);
                    out_g = idx[5:0] >> 2;
                    out_b = 8'd80 + idx[5:0];
                end else begin
                    out_r = 8'd200 + ((idx - 8'd128) >> 3);
                    out_g = 8'd24 + ((idx - 8'd128) >> 2);
                    out_b = 8'd120 - ((idx - 8'd128) >> 3);
                end
            end
            7'd88: begin // Stained Glass Hard
                case (idx[2:0])
                    3'd0: begin out_r = 8'hC8; out_g = 8'h0C; out_b = 8'h2C; end
                    3'd1: begin out_r = 8'h0A; out_g = 8'h0A; out_b = 8'h0A; end
                    3'd2: begin out_r = 8'h12; out_g = 8'h38; out_b = 8'hC0; end
                    3'd3: begin out_r = 8'h0A; out_g = 8'h0A; out_b = 8'h0A; end
                    3'd4: begin out_r = 8'h0C; out_g = 8'hA8; out_b = 8'h50; end
                    3'd5: begin out_r = 8'h0A; out_g = 8'h0A; out_b = 8'h0A; end
                    3'd6: begin out_r = 8'hF8; out_g = 8'hB8; out_b = 8'h20; end
                    3'd7: begin out_r = 8'h80; out_g = 8'h20; out_b = 8'hC0; end
                endcase
            end
            7'd89: begin // Disco Floor: rainbow smooth + 1-in-16 white peak + 1-in-2 black void (strobing dots)
                if (idx[3:0] == 4'b0000) begin
                    out_r = 8'hFF; out_g = 8'hFF; out_b = 8'hFF;
                end else if (idx[0] == 1'b0) begin
                    out_r = 8'h00; out_g = 8'h00; out_b = 8'h00;
                end else if (idx < 8'd86) begin
                    out_r = 8'hFF - (idx + idx);
                    out_g = idx + idx;
                    out_b = 8'h00;
                end else if (idx < 8'd171) begin
                    out_r = 8'h00;
                    out_g = 8'hFF - ((idx - 8'd86) + (idx - 8'd86));
                    out_b = (idx - 8'd86) + (idx - 8'd86);
                end else begin
                    out_r = (idx - 8'd171) + (idx - 8'd171);
                    out_g = 8'h00;
                    out_b = 8'hFF - ((idx - 8'd171) + (idx - 8'd171));
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
    palette_rgb(pal_to,   base_cidx, color_a_r,  color_a_g,  color_a_b);
    palette_rgb(pal_to,   next_cidx, color_b_r,  color_b_g,  color_b_b);
    palette_rgb(pal_from, base_cidx, color_fa_r, color_fa_g, color_fa_b);
    palette_rgb(pal_from, next_cidx, color_fb_r, color_fb_g, color_fb_b);
end

// Cycling blend within each palette
wire [7:0] to_blend_r   = blend_channel(color_a_r,  color_b_r,  cycle_frac);
wire [7:0] to_blend_g   = blend_channel(color_a_g,  color_b_g,  cycle_frac);
wire [7:0] to_blend_b   = blend_channel(color_a_b,  color_b_b,  cycle_frac);
wire [7:0] from_blend_r = blend_channel(color_fa_r, color_fb_r, cycle_frac);
wire [7:0] from_blend_g = blend_channel(color_fa_g, color_fb_g, cycle_frac);
wire [7:0] from_blend_b = blend_channel(color_fa_b, color_fb_b, cycle_frac);

// Crossfade blend.  When inactive, output the TO palette directly.
// blend_channel_64(a, b, frac): a=TO, b=FROM, weights add to 64.
// crossfade_frac = 63 at start of fade → mostly FROM; 0 at end → fully TO.
wire [7:0] crossfade_r = fade_active ? blend_channel_64(to_blend_r, from_blend_r, crossfade_frac) : to_blend_r;
wire [7:0] crossfade_g = fade_active ? blend_channel_64(to_blend_g, from_blend_g, crossfade_frac) : to_blend_g;
wire [7:0] crossfade_b = fade_active ? blend_channel_64(to_blend_b, from_blend_b, crossfade_frac) : to_blend_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cycle_phase      <= 12'd0;
        cycle_phase_lo   <= 12'd0;
        ping_dir         <= 1'b0;
        pal_from         <= 7'd0;
        pal_to           <= 7'd0;
        fade_counter     <= 7'd0;
        fade_tick_div    <= 1'b0;
        pixel_valid_out  <= 1'b0;
        color_r          <= 8'd0;
        color_g          <= 8'd0;
        color_b          <= 8'd0;
    end else begin
        // Palette change detector — runs every cycle (not gated on vblank)
        // so we catch the change as soon as palette_sel updates.
        if (palette_sel != pal_to) begin
            pal_from     <= pal_to;
            pal_to       <= palette_sel;
            // Instant mode skips the fade entirely; the other modes start
            // a full fade from the new pal_from to pal_to.
            fade_counter <= (palette_transition_mode == 2'd0) ? 7'd0 : 7'd127;
            fade_tick_div<= 1'b0;
        end else if (vblank_rise && fade_counter > 7'd0) begin
            case (palette_transition_mode)
                2'd1: fade_counter <= (fade_counter > 7'd2) ? (fade_counter - 7'd2) : 7'd0;  // ~1 s
                2'd2: begin                                                                    // ~2 s
                    if (fade_tick_div)
                        fade_counter <= (fade_counter > 7'd2) ? (fade_counter - 7'd2) : 7'd0;
                    fade_tick_div <= ~fade_tick_div;
                end
                default: fade_counter <= 7'd0;  // Instant
            endcase
        end
        if (cycle_enable) begin
            if (vblank_rise) begin
                // High-band phase update.  Ping-Pong CLAMPS at the boundary
                // and reverses direction instead of wrapping around — wrapping
                // would land at the opposite end and immediately wrap again,
                // causing the phase to oscillate near the boundary and look
                // frozen ("ping-pong stops cycling" bug).
                if (cycle_direction == 2'd2) begin
                    if (phase_overflow) begin
                        cycle_phase <= 12'd4095;
                        ping_dir    <= 1'b1;
                    end else if (phase_underflow) begin
                        cycle_phase <= 12'd0;
                        ping_dir    <= 1'b0;
                    end else begin
                        cycle_phase <= forward_now ? phase_fwd[11:0]
                                                   : phase_rev[11:0];
                    end
                end else begin
                    // Forward / Reverse — wrap naturally.
                    cycle_phase <= forward_now ? phase_fwd[11:0]
                                               : phase_rev[11:0];
                end

                // Low-band phase update — same shape, independent counter.
                // When band_mode is Off / Counter, keep cycle_phase_lo
                // tracking cycle_phase so a later mode change starts
                // smoothly.
                if (cycle_band_mode == 2'd1 || cycle_band_mode == 2'd2) begin
                    if (cycle_direction == 2'd2) begin
                        if (phase_lo_overflow) begin
                            cycle_phase_lo <= 12'd4095;
                        end else if (phase_lo_underflow) begin
                            cycle_phase_lo <= 12'd0;
                        end else begin
                            cycle_phase_lo <= forward_now ? phase_lo_fwd[11:0]
                                                          : phase_lo_rev[11:0];
                        end
                    end else begin
                        cycle_phase_lo <= forward_now ? phase_lo_fwd[11:0]
                                                      : phase_lo_rev[11:0];
                    end
                end else begin
                    // Off / Counter — keep low-band counter in sync with high.
                    cycle_phase_lo <= cycle_phase;
                end
            end
        end else begin
            cycle_phase    <= 12'd0;
            cycle_phase_lo <= 12'd0;
            ping_dir       <= 1'b0;
        end

        pixel_valid_out <= pixel_valid_in;

        if (pixel_valid_in) begin
            if (escaped) begin
                color_r <= crossfade_r;
                color_g <= crossfade_g;
                color_b <= crossfade_b;
            end else begin
                color_r <= 8'd0;
                color_g <= 8'd0;
                color_b <= 8'd0;
            end
        end
    end
end

endmodule
