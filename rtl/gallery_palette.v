// Gallery palette sequencer (docs/GALLERY_DESIGN.md, stage 3).
//
// In gallery mode the framework displays the DDR3 index buffer through
// ascal; the core-side video output is ignored, so the display color
// pipeline (color_mapper) idles.  This module hijacks it: it feeds
// iter=k, escaped=1 for k=1..255 into the fb pixel mux (mux lives in
// fractal_top) at the ce_pix cadence, captures the pipelined
// color_r/g/b outputs at the matching ticks, and streams them to the
// framework palette (FB_PAL).  Entry k therefore reproduces the
// per-pixel color math BIT-EXACTLY — cycling phase, band split,
// smooth/hard blend and palette crossfades all keep animating at
// 60 Hz through palette rewrites alone.
//
// One sweep per core vblank, started at vblank_rise (the same edge
// color_mapper steps its cycling phase, so the sweep always samples a
// coherent phase).  255 entries + pipeline drain ~ 258 ticks ~ 10 us
// — comfortably inside vblank.  Entry 0 (interior) is written black
// at sweep start.
//
// Capture alignment (color_mapper's restaged ring, see its staging
// comment): the index loaded into inj_k at tick edge N is presented
// during [N, N+1) and its color lands in color_r/g/b at tick(N+2)+1,
// stable through tick N+3 — so at any tick edge T the outputs hold
// the color of the index loaded at T-3.  With the nonblocking shift
// below, the PRE-edge value of cap_d2 at edge T is exactly that
// index (first cut tapped one stage deeper and produced a clean
// entry[k] = color[k+1] shift — caught by the golden-model TB).
//
// fade_scale (0..63, 63 = full brightness) scales the captured RGB —
// the O[59]-Off transition fades the palette to black, flips FB_BASE
// while the screen is uniformly black (tear-free by construction),
// and fades back in.  At 63 the scale is exact passthrough
// (value * 64 / 64), keeping the bit-exactness claim.
//
// clk = clk_vid (the color_mapper domain).  FB_PAL writes leave on
// this clock; gallery_fb forwards it as fb_pal_clk.

module gallery_palette (
    input  wire        clk,          // clk_vid
    input  wire        rst_n,
    input  wire        gallery_en,   // vid-domain synced gallery_mode
    input  wire        ce_pix,
    input  wire        vblank_rise,
    input  wire [5:0]  fade_scale,   // 63 = full, 0 = black

    // injection into the display color path (fractal_top muxes this
    // into color_mapper's iter/escaped inputs while gallery_en)
    output wire [7:0]  inj_iter,

    // captured pipeline output (color_mapper's registered outputs)
    input  wire [7:0]  color_r,
    input  wire [7:0]  color_g,
    input  wire [7:0]  color_b,

    // palette stream (into gallery_fb pass-through -> FB_PAL_*)
    output reg         pal_wr,
    output reg  [7:0]  pal_addr,
    output reg  [23:0] pal_data
);

// ---- sweep sequencing ----
// inj_k runs 1..255 then parks; the delay line drains 3 more ticks.
reg  [8:0] inj_k;        // 9 bits: 256+ = parked
reg  [8:0] cap_d1, cap_d2;
wire       sweeping = (inj_k <= 9'd255);

assign inj_iter = inj_k[7:0];   // parked value (256) presents iter 0 — inert

// exact 6-bit brightness scale: value * (fade_scale + 1) / 64.
// fade_scale 63 -> *64/64 = passthrough.
function [7:0] scale_fade;
    input [7:0] value;
    input [5:0] fs;
    reg   [14:0] acc;
    reg   [6:0]  w;
    begin
        w = {1'b0, fs} + 7'd1;
        acc = 15'd0;
        if (w[0]) acc = acc + {7'd0, value};
        if (w[1]) acc = acc + {6'd0, value, 1'b0};
        if (w[2]) acc = acc + {5'd0, value, 2'b0};
        if (w[3]) acc = acc + {4'd0, value, 3'b0};
        if (w[4]) acc = acc + {3'd0, value, 4'b0};
        if (w[5]) acc = acc + {2'd0, value, 5'b0};
        if (w[6]) acc = acc + {1'd0, value, 6'b0};
        scale_fade = acc[13:6];
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        inj_k    <= 9'd256;
        cap_d1   <= 9'd256;
        cap_d2   <= 9'd256;
        pal_wr   <= 1'b0;
        pal_addr <= 8'd0;
        pal_data <= 24'd0;
    end else begin
        pal_wr <= 1'b0;
        if (!gallery_en) begin
            inj_k  <= 9'd256;
            cap_d1 <= 9'd256;
            cap_d2 <= 9'd256;
        end else if (vblank_rise) begin
            // start a sweep; entry 0 = interior black, written directly
            // (also correct during fades: black stays black)
            inj_k    <= 9'd1;
            cap_d1   <= 9'd256;
            cap_d2   <= 9'd256;
            pal_wr   <= 1'b1;
            pal_addr <= 8'd0;
            pal_data <= 24'h000000;
        end else if (ce_pix) begin
            // nonblocking shift: capture reads the PRE-edge cap_d2 =
            // the index loaded 3 tick edges ago, whose color the
            // color_mapper outputs hold right now
            cap_d2 <= cap_d1;
            cap_d1 <= inj_k;
            if (sweeping) inj_k <= inj_k + 9'd1;
            if (cap_d2 <= 9'd255 && cap_d2 != 9'd0) begin
                pal_wr   <= 1'b1;
                pal_addr <= cap_d2[7:0];
                pal_data <= {scale_fade(color_r, fade_scale),
                             scale_fade(color_g, fade_scale),
                             scale_fade(color_b, fade_scale)};
            end
        end
    end
end

endmodule
