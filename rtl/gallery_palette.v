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
// One sweep per SCALER vblank (FB_VBL rising edge, synced by the
// caller): ascal scans the FB asynchronously to the core video, so a
// core-vblank-triggered sweep rewrites the palette mid-scanout — at
// fast cycling speeds the old/new palette seam shows as a horizontal
// tear line (user-visible, testing round 2).  Sweeping in the scaler's
// blanking (255 entries + drain ~ 10 us against ~450 us of 1080p
// vblank) removes the seam.  The cycling phase still steps on the
// CORE vblank; in the rare frame where that lands mid-sweep
// (~10 us / 16.7 ms), part of one sweep is a phase ahead — a subtle
// one-frame inconsistency, not a spatial seam.  Entry 0 (interior) is
// written black at sweep start.
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
// blank (level, from gallery_ctl via 2FF) forces every entry to black
// while the activation clear runs, so the wipe is never visible.
// (The O[59] fade-flip path with its 6-bit brightness scaler was
// removed 2026-10-20 — gallery renders live only.)
//
// clk = clk_vid (the color_mapper domain).  FB_PAL writes leave on
// this clock; gallery_fb forwards it as fb_pal_clk.

module gallery_palette (
    input  wire        clk,          // clk_vid
    input  wire        rst_n,
    input  wire        gallery_en,   // vid-domain synced gallery_mode
    input  wire        ce_pix,
    input  wire        sweep_start,   // scaler-vblank rise (FB_VBL)
    input  wire        blank,        // 1 = write all entries black

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
// The start request is latched and the sweep begins ON the next ce
// tick edge: FB_VBL is not aligned to the ce grid (the old core-vblank
// trigger accidentally was, via video_timing), and an unaligned load
// presents the first index in a torn tick — the pipeline samples the
// parked value and entry 1 captures a stale color (caught by the
// golden-model TB the moment the trigger moved).
reg        sweep_pend;
reg  [8:0] inj_k;        // 9 bits: 256+ = parked
reg  [8:0] cap_d1, cap_d2;
wire       sweeping = (inj_k <= 9'd255);

assign inj_iter = inj_k[7:0];   // parked value (256) presents iter 0 — inert

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sweep_pend <= 1'b0;
        inj_k    <= 9'd256;
        cap_d1   <= 9'd256;
        cap_d2   <= 9'd256;
        pal_wr   <= 1'b0;
        pal_addr <= 8'd0;
        pal_data <= 24'd0;
    end else begin
        pal_wr <= 1'b0;
        if (sweep_start) sweep_pend <= 1'b1;
        if (!gallery_en) begin
            sweep_pend <= 1'b0;
            inj_k  <= 9'd256;
            cap_d1 <= 9'd256;
            cap_d2 <= 9'd256;
        end else if (sweep_pend && ce_pix) begin
            // tick-aligned sweep start; entry 0 = interior black,
            // written directly
            sweep_pend <= 1'b0;
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
                pal_data <= blank ? 24'h000000 : {color_r, color_g, color_b};
            end
        end
    end
end

endmodule
