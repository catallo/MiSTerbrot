# 640×480p + 100 MHz video domain (Design)

Status: PLANNED (2026-07-09).  Follows Track B 640×480i (see
TRACKB_DESIGN.md).  Decision: full native 640×480p via a video-domain
move — option chosen by the user over a duplicated color cone,
320×480p, or dropping 480p.

## Why a new video domain

640×480p @ ~59.5 Hz needs a 25 MHz pixel clock = one pixel every TWO
clk_sys cycles.  The display color pipeline is structurally built for
FOUR clocks per pixel (ce_d1/d2/d3 staging, tick+1 capture, and every
video SDC multicycle rests on that cadence).  At 2-clk cadence the
stages of consecutive pixels collide (data corruption, not just
timing), and the relaxed budgets halve to values the ~24 ns palette
cone can never meet at 50 MHz.

Fix: the whole display path moves to **clk_vid = 100 MHz** (physically
the existing clk_iter PLL output; no new PLL).  25 MHz ce_pix is then
again "every 4 clocks" — the proven pipeline structure and multicycle
scheme carry over unchanged, at twice the absolute speed.

## Target domain split

**clk_sys 50 MHz (unchanged):** render orchestration (coord_generator,
region_manager, pixel_pipeline collect), framebuffer WRITE side,
fb_ddr3 Avalon engine (DDRAM_CLK stays 50 MHz), input_handler,
auto_zoom/randomizer, fractal_osd decode, benchmark engine, hps_io.

**clk_vid 100 MHz (new consumers of the clk_iter clock):**
video_timing, framebuffer READ port, fb_ddr3 line-buffer READ side,
color_mapper (including cycling/crossfade state — vblank is native
here), text_overlay, compositing, arcade_video / dvid path,
CLK_VIDEO = clk_vid, CE_PIXEL generated here.

ce_pix dividers from 100 MHz: 320×240 & 320×480i /16, 640×240 &
640×480i /8, 640×480p /4.

## CDC inventory (all with established patterns)

1. **framebuffer BRAM**: true dual-clock altsyncram (write clk_sys,
   read clk_vid).  Banks separate display/render, so no data races;
   `bank_sel` crosses as a 2FF-synced quasi-static.  Single-buffer
   mode's read-during-write nondeterminism is already accepted today.
2. **fb_ddr3**: fetch engine stays clk_sys.  Line buffer becomes
   dual-clock (beat writes clk_sys, display reads clk_vid).
   `line_req` from video_timing → toggle synchronizer into clk_sys
   (a whole line period of slack); `line_row` follows the iter-CDC
   contract (stable from req until next req, ≥64 µs); the ping-pong
   select syncs back with 2FF (read side uses it half a line later).
3. **Quasi-static control into clk_vid**: OSD statics, palette
   selection, overlay text values (POI names, fps digits, telemetry).
   Direct crossing with set_net_delay bounds + multicycle, as with
   today's hps_io statics; a torn text-value sample paints one wrong
   glyph for one frame — invisible, and these values change mid-frame
   today anyway.
4. **Key pulses into clk_vid** (palette step etc.): toggle
   synchronizers.
5. **vblank back into clk_sys** (bank swap, auto_zoom pacing, boot
   grace, benchmark windows): 2FF level sync + edge detect.  Swap
   still happens deep inside vblank; the 2-3 clock sync delay is
   nothing against 22+ blank lines.

## SDC rework

Same two clocks, same async groups — but the video multicycle families
become intra-clk_vid constraints with UNCHANGED cycle counts (cadence
preserved).  New set_net_delay bounds on the CDC buses above.  Known
tight spots at 10 ns/cycle:

- fb→color cone: 3 cycles = 30 ns vs 24.86 ns measured — fits.
- **Blend cone: 2 cycles = 20 ns vs ~22 ns measured — does NOT fit.**
  Plan: one retiming register inside the blend (adds 1 clk_vid of
  latency, invisible), restoring margin.
- text_overlay glyph combinational path met 20 ns single-cycle; at
  10 ns it likely needs one pipeline register.  Same for any other
  single-cycle stragglers the first STA run surfaces.
- Placement interaction: iter quads and video logic now share the
  100 MHz domain — expect a seed lottery on first closure.

## Stages

1. **Domain move, no new mode** (the big one): display path to
   clk_vid at the existing four resolutions.  Verification: TBs with
   true async clock ratios checking frame-content equivalence and
   ce-tick-exact sync geometry (cycle-exact pair-TBs across domains
   are not meaningful); hardware 240p walkthrough regression + visual
   check.  Lands and soaks alone.
2. **480p mode** on top: video_timing 480p mux (V: 480+10+3+32 = 525
   lines, H structure unchanged at 800 → 31.25 kHz / 59.5 Hz),
   Resolution selector widens to `O[56:54]` (bit 56 is free since the
   Deinterlace move to O[58:57]; existing saved configs keep their
   meaning), J cycles five modes, overlay y-halving in 480p
   (vid_pixel_y 0..479 → glyphs keep the doubled-line look),
   vid_in_range y<480, boot grace applies (conservative: same
   progressive-first policy as 480i), scandoubler/fx forced off in
   480p (signal is already 31 kHz), new_vmode as usual.  DDR3
   framebuffer identical to 640×480i (progressive render, prefetch_row
   is already mode-aware; line budget halves to 32 µs vs 3.84 µs
   worst-case measured — 8× margin).
3. **Field-sequential 480i toggle** (see ROADMAP) — independent of
   the domain move, scheduled after 480p.

## Effort / risk

Stage 1 ~1-1.5 weeks including closure lottery; stage 2 ~2-4 days;
stage 3 separate.  Main risks: 100 MHz closure of the video cones
(mitigations above) and CDC subtleties (mitigated by the established
toggle/quasi-static patterns and async-ratio TBs).
