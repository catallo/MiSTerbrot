derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# clk_sys (PLL outclk_0, 50 MHz) and clk_iter (PLL outclk_1, 100 MHz)
# are independent. CDC at the iter_quad boundary uses toggle synchronizers.
set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Bound routing delay on the quasi-static CDC data buses.  The async clock
# groups above cut ALL cross-domain timing analysis, so without these the
# fitter is free to route CDC buses arbitrarily slowly.  The CDC contract:
# data is written and stable >=2 destination-clock cycles before the
# synchronized strobe fires (start toggle: 3-FF chain in clk_iter, 20-30 ns;
# done toggle: 3-FF chain in clk_sys, 40-60 ns).  One destination-clock
# period of net delay preserves comfortable margin.

# clk_sys -> clk_iter: per-slot coordinate buses, sampled by iter_quad when
# the synchronized start pulse fires.
set_net_delay -max 15 -from [get_registers {*u_pipeline|iter_cr[*]*}]
set_net_delay -max 15 -from [get_registers {*u_pipeline|iter_ci[*]*}]

# clk_sys -> clk_iter control (max_iter, p3_precheck_enable) is deliberately
# NOT net-delay constrained: set_net_delay requires -from and the sources are
# synthesized LUTs (muxes), not nameable registers.  A slow or skewed route
# only produces a torn sample, which the design already tolerates — the frame
# re-renders on any settings change.

# clk_iter -> clk_sys: result buses, sampled by the collect FSM after the
# synchronized done pulse.
set_net_delay -max 20 -from [get_registers {*u_quad|ctx_iter_count[*]*}]
set_net_delay -max 20 -from [get_registers {*u_quad|ctx_escaped[*]*}]

# Video path is ce_pix-cadenced, not single-cycle.  The framebuffer read
# address advances only on ce_pix ticks (every 8 clk_sys cycles in 320
# mode, every 4 in 640 mode) and the color_mapper output registers are
# enable-gated on ce_pix, so the BRAM -> 90-palette/crossfade cone ->
# color regs path genuinely has >=3 clk_sys cycles.  Without this the
# path (~24 ns after the crossfade feature) reports -5.8 ns against the
# 20 ns single-cycle default and drags fitter effort away from clk_iter.
# Real budget: BRAM data lands one clk after the address tick, capture on
# the next tick -> exactly 3 clk_sys cycles in 640 mode (7 in 320 mode).
# Narrowed to the FINAL color registers only: since the two-pass palette
# evaluation (2026-07-08), the fb -> pass-A capture registers (cidx_*_r,
# color_f*_*) are genuinely single-cycle and must stay unrelaxed.  The
# fb paths still reaching the final regs directly (escaped, band select,
# cycle_frac) retain the full 3-cycle budget.
# NOTE: constrained -from the framebuffer so the ce_pix enable path into
# the same registers stays single-cycle.
# u_fb_ddr3 (Track B): the DDR3 line-buffer read regs (Quartus merges
# rd_word_r into the altsyncram output register) feed the same color
# cone with the same ce_pix cadence — identical 3-cycle real budget.
# to_blend_q joined the -to list with the blend retiming: the iter-band
# select (cycle_frac) reaches it straight from fb data, with the same
# data-at-tick+1 -> capture-at-next-tick+1 budget as the final regs.
# The fb_ddr3 -> cidx_*_r pass-A path stays single-cycle (not in -to),
# exactly like the BRAM equivalent.
# Restaged ring (2 clks/stage, see color_mapper staging block): fb data
# lands at tick+1 and the first captures (cidx pair, band bit, escaped)
# happen at ce_d3 = tick+3 — 2 cycles real at the /4 cadence.  Direct
# fb paths into the evaluator latches (next tick's ce_d1) have >=4
# cycles; constrained at 2 conservatively.  No fb path reaches the
# blend or final stages anymore (band + escaped are pipelined copies).
set_multicycle_path -setup 2 -from [get_registers {*u_framebuffer|* *u_fb_ddr3|*}] -to [get_registers {*u_color_mapper|cidx_base_r[*]* *u_color_mapper|cidx_next_r[*]* *u_color_mapper|low_band_q *u_color_mapper|escaped_q1 *u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}]
set_multicycle_path -hold  1 -from [get_registers {*u_framebuffer|* *u_fb_ddr3|*}] -to [get_registers {*u_color_mapper|cidx_base_r[*]* *u_color_mapper|cidx_next_r[*]* *u_color_mapper|low_band_q *u_color_mapper|escaped_q1 *u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}]
# cidx regs (ce_d3) -> evaluator latches (next tick's ce_d1): the
# 90-entry palette mux gets its 2 cycles.
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|cidx_base_r[*]* *u_color_mapper|cidx_next_r[*]*}] -to [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|cidx_base_r[*]* *u_color_mapper|cidx_next_r[*]*}] -to [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}]

# (The earlier shared-evaluator false path fb -> color_a_*/color_b_* was
# removed with the three-evaluator restructure: every evaluator now reads
# registered inputs only, so no structural fb path to those registers
# exists.  fb's only single-cycle destination is the cidx_*_r adder path.)

# Blend cone, retimed for the 100 MHz video domain: eval regs (ce_d3)
# -> to_blend_q (ce_d1 of the next tick) -> final color regs (ce_d3 of
# the next tick).  Each hop is 2 cycles by construction at the minimum
# cadence (ce every 4 clks); the downstream consumer samples only at
# the following tick, so the later final capture is free.
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|low_band_q*}] -to [get_registers {*u_color_mapper|to_blend_q*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|low_band_q*}] -to [get_registers {*u_color_mapper|to_blend_q*}]
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|to_blend_q* *u_color_mapper|color_fa_*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|to_blend_q* *u_color_mapper|color_fa_*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]

# Same cadence argument for the overlay/compositing cone: vid_pixel_*_d /
# vid_active_d update on ce_pix (fractal_top), color_mapper's output regs
# are ce_pix-enabled, and arcade_video's RGB_fix/HS/HBL capture only on
# the ce_pix rising edge (sys/arcade_video.v).  Launch and capture sit on
# the same tick grid >=4 clk_sys cycles apart.
# Raised to 3 with the 100 MHz move: the text_overlay glyph cone off
# vid_pixel_*_d measures ~25 ns and the real budget is one full tick —
# 8 clk_vid today (/8), still 4 at a future 480p (/4), so setup 3 stays
# valid in every mode.
set_multicycle_path -setup 3 -from [get_registers {*u_fractal_top|vid_pixel_x_d[*] *u_fractal_top|vid_pixel_y_d[*] *u_fractal_top|vid_active_d}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]
set_multicycle_path -hold  2 -from [get_registers {*u_fractal_top|vid_pixel_x_d[*] *u_fractal_top|vid_pixel_y_d[*] *u_fractal_top|vid_active_d}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]
# With the restaged ring the final color regs capture at ce_d1 and the
# tick sampler consumes 3 clks later even at /4 — setup 2 is valid in
# every mode including 480p.
# (gallery_palette joined 2026-07-11: pal_data latches on the ce tick
# grid from color_* through the fade scaler — same full-tick budget.)
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix* *u_gallery_palette|pal_*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix* *u_gallery_palette|pal_*}]

# ---- 100 MHz video-domain move (docs/480P_DESIGN.md) ----
# The display path (video_timing, fb read, color_mapper, text_overlay,
# arcade_video, dvid) now lives in clk_iter's clock group.  The former
# quasi-static multicycles from clk_sys sources became CROSS-DOMAIN
# paths, cut entirely by the async clock groups above — so they get
# net-delay routing bounds instead (same CDC contract as the iter
# buses: values change on keypress/vblank/frame events; a torn sample
# repaints one frame and is invisible).
set_net_delay -max 20 -from [get_registers {*u_fractal_top|benchmark_* *u_fractal_top|bench_* *u_fractal_top|last_bench_window_frames[*] *u_fractal_top|sym_overflow_sticky *u_fractal_top|overlay_visible *u_fractal_top|blank_text_override[*] *u_fractal_top|bg_dim_override[*] *u_fractal_top|fps_value[*] *u_fractal_top|boot_grace_cnt[*] *u_fractal_top|res_override*}]
set_net_delay -max 20 -from [get_registers {*u_auto_zoom|* *u_input|*}]
set_net_delay -max 20 -from [get_registers {*hps_io*|status[*]*}]
# 1-bit synchronizer feeds and the line_row quasi-static bus: bank swap
# / buffer mode / ddr mode into clk_vid, line_req toggle + row into the
# fb_ddr3 engine, vblank back into clk_sys (source is a video_timing
# output register inside u_video_timing).
set_net_delay -max 10 -from [get_registers {*u_fractal_top|bank_sel *u_fb_ddr3|req_tgl_v *u_video_timing|vblank}]
set_net_delay -max 20 -from [get_registers {*u_fb_ddr3|line_row_hold[*]}]
# Gallery fade scale into the clk_vid palette sequencer (2FF sync;
# quasi-static, one +/-3 step per vblank — same CDC contract).
set_net_delay -max 20 -from [get_registers {*u_gallery_ctl|fade_scale[*]}]

# Cycling/crossfade phase regs are clk_vid-local now (color_mapper
# moved wholesale): keep their relaxation into the vid compositing
# cone, same one-tick-late-settle argument as before.
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|cycle_phase* *u_color_mapper|pal_* *u_color_mapper|fade_* *u_color_mapper|ping_dir}] -to [get_registers {*u_arcade_video|* *u_color_mapper|* *|dvid_*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|cycle_phase* *u_color_mapper|pal_* *u_color_mapper|fade_* *u_color_mapper|ping_dir}] -to [get_registers {*u_arcade_video|* *u_color_mapper|* *|dvid_*}]

# auto_zoom's step register roots a deep combinational cone (step_msb
# priority tree -> zoom_exp -> zoom_level_x10 -> pacing -> step_delta)
# whose captures are all vblank_rise / keypress-pulse gated — step itself
# changes at most once per display frame.  Only the step-rooted cone is
# relaxed: free_counter / LFSR / shuffle logic runs full-rate every cycle
# and must stay single-cycle.
set_multicycle_path -setup 2 -from [get_registers {*u_auto_zoom|step[*]}] -to [get_registers {*u_auto_zoom|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_auto_zoom|step[*]}] -to [get_registers {*u_auto_zoom|*}]

# ascal input downscaler (framework): the C1..C5 stages including the
# i_mem line-RAM -> i_pix bilinear cone all advance under i_pce (the
# CE tick, sys/ascal.vhd) — launch at tick+1 (RAM output register),
# capture at the next tick+1.  Multicycle-2 holds at every ce_pix
# cadence incl. a future 480p (/4).  Only this cone is relaxed; the
# rest of ascal's input stage stays single-cycle.
# (extended for the 480p closure round: the h/v fraction and hpix
# chain registers live in the same i_pce-gated pipeline)
set_multicycle_path -setup 2 -from [get_registers {*ascal|i_mem* *ascal|i_v_frac* *ascal|i_h_frac* *ascal|i_hpix* *ascal|i_ldrm*}] -to [get_registers {*ascal|i_pix* *ascal|i_hpix* *ascal|i_h_bil*}]
set_multicycle_path -hold  1 -from [get_registers {*ascal|i_mem* *ascal|i_v_frac* *ascal|i_h_frac* *ascal|i_hpix* *ascal|i_ldrm*}] -to [get_registers {*ascal|i_pix* *ascal|i_hpix* *ascal|i_h_bil*}]

# text_overlay registers into the tick-sampled video captures: every
# register in the module is either frame-static display text (coord/
# zoom/fps digit latches — a one-tick-late settle repaints one glyph
# pixel a tick late, invisible) or tick-cadenced pixel-path state.
# Multicycle-2 into the ce-gated targets is valid for both classes.
set_multicycle_path -setup 2 -from [get_registers {*u_text_overlay|*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]
set_multicycle_path -hold  1 -from [get_registers {*u_text_overlay|*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]

# HQ2x blender (framework scandoubler): every register in the Blend
# stage advances under clk_en (= the scandoubler pixel CE,
# sys/hq2x.sv) — the df_rule -> i30 multiply cone is tick-cadenced
# with >=4 clk_vid between captures in every mode that runs the
# scandoubler.  Narrowly scoped to the blender.
set_multicycle_path -setup 2 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}] -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold  1 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}] -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
# ...same cadence for the ce_in-gated pixel-window registers feeding the
# pattern compare and the blender inputs (one pixel per CE tick; the
# scandoubler never runs above the /8 cadence).  The 1-clk pulse regs
# (wrout_en/wrin_en) are deliberately NOT relaxed.
set_multicycle_path -setup 2 -from [get_registers {*|Hq2x:Hq2x|Prev0* *|Hq2x:Hq2x|Curr0* *|Hq2x:Hq2x|Next0* *|Hq2x:Hq2x|Prev1* *|Hq2x:Hq2x|Curr1* *|Hq2x:Hq2x|Next1* *|Hq2x:Hq2x|Prev2* *|Hq2x:Hq2x|Curr2* *|Hq2x:Hq2x|Next2* *|Hq2x:Hq2x|patt*}] -to [get_registers {*|Hq2x:Hq2x|nextpatt* *|Hq2x:Hq2x|patt* *|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold  1 -from [get_registers {*|Hq2x:Hq2x|Prev0* *|Hq2x:Hq2x|Curr0* *|Hq2x:Hq2x|Next0* *|Hq2x:Hq2x|Prev1* *|Hq2x:Hq2x|Curr1* *|Hq2x:Hq2x|Next1* *|Hq2x:Hq2x|Prev2* *|Hq2x:Hq2x|Curr2* *|Hq2x:Hq2x|Next2* *|Hq2x:Hq2x|patt*}] -to [get_registers {*|Hq2x:Hq2x|nextpatt* *|Hq2x:Hq2x|patt* *|Hq2x:Hq2x|Blend:blender|*}]

# pixel counters -> framebuffer/line-buffer address inputs: the RAM
# address ports re-read every clock; downstream only consumes the data
# present >=2 clocks after the ce tick (d2/d3 capture enables), so a
# one-clock-late address settle is invisible.
set_multicycle_path -setup 2 -from [get_registers {*u_video_timing|pixel_x[*] *u_video_timing|pixel_y[*]}] -to [get_registers {*u_framebuffer|* *u_fb_ddr3|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_video_timing|pixel_x[*] *u_video_timing|pixel_y[*]}] -to [get_registers {*u_framebuffer|* *u_fb_ddr3|*}]

# Vid-side 2FF syncs of quasi-static mode/bank controls (m480p_vs,
# ddr_mode_vs, bank_sel_vs, single_buf_vs): they feed pixel-path muxes
# (overlay row halving, fb source select, display bank select) whose
# consumers all capture on the ce tick grid.  The sources change once
# per OSD/key event — a one-tick-late settle repaints one frame's
# worth of pixels a tick late, invisible.  Multicycle-3 (the overlay
# y-mux feeds the same ~25 ns glyph cone that put vid_pixel_*_d at 3;
# real budget is a full tick, 4 clks minimum) into every tick-sampled
# capture rank.
# (gallery_vs joined the family 2026-07-11: same quasi-static OSD-event
# cadence; it feeds the color_mapper injection mux, the analog blanking
# mux and gallery_palette's enable — all tick-sampled consumers.)
set_multicycle_path -setup 3 -from [get_registers {*u_fractal_top|m480p_vs* *u_fractal_top|ddr_mode_vs* *u_fractal_top|bank_sel_vs* *u_fractal_top|single_buf_vs* *u_fractal_top|gallery_vs* *u_fractal_top|fade_vs*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix* *u_color_mapper|* *u_text_overlay|* *u_framebuffer|* *u_fb_ddr3|* *u_gallery_palette|*}]
set_multicycle_path -hold  2 -from [get_registers {*u_fractal_top|m480p_vs* *u_fractal_top|ddr_mode_vs* *u_fractal_top|bank_sel_vs* *u_fractal_top|single_buf_vs* *u_fractal_top|gallery_vs* *u_fractal_top|fade_vs*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix* *u_color_mapper|* *u_text_overlay|* *u_framebuffer|* *u_fb_ddr3|* *u_gallery_palette|*}]
