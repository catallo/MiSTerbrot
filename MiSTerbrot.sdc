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
set_multicycle_path -setup 3 -from [get_registers {*u_framebuffer|* *u_fb_ddr3|*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]* *u_color_mapper|to_blend_q*}]
set_multicycle_path -hold  2 -from [get_registers {*u_framebuffer|* *u_fb_ddr3|*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]* *u_color_mapper|to_blend_q*}]

# (The earlier shared-evaluator false path fb -> color_a_*/color_b_* was
# removed with the three-evaluator restructure: every evaluator now reads
# registered inputs only, so no structural fb path to those registers
# exists.  fb's only single-cycle destination is the cidx_*_r adder path.)

# Blend cone, retimed for the 100 MHz video domain: eval regs (ce_d3)
# -> to_blend_q (ce_d1 of the next tick) -> final color regs (ce_d3 of
# the next tick).  Each hop is 2 cycles by construction at the minimum
# cadence (ce every 4 clks); the downstream consumer samples only at
# the following tick, so the later final capture is free.
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_*}] -to [get_registers {*u_color_mapper|to_blend_q*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_*}] -to [get_registers {*u_color_mapper|to_blend_q*}]
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
# NOTE for 480p (stage 2): with the ce_d3 final capture the real
# budget of color_r -> RGB_fix/dvid shrinks to 1 clk at /4 cadence —
# this setup-2 must be removed or the output re-staged before the
# 480p mode ships.  Valid today (real budget 5 clks at /8).
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|* *|dvid_* *ascal|i_pix*}]

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
set_multicycle_path -setup 2 -from [get_registers {*ascal|i_mem*}] -to [get_registers {*ascal|i_pix*}]
set_multicycle_path -hold  1 -from [get_registers {*ascal|i_mem*}] -to [get_registers {*ascal|i_pix*}]
