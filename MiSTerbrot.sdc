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
set_multicycle_path -setup 3 -from [get_registers {*u_framebuffer|*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]
set_multicycle_path -hold  2 -from [get_registers {*u_framebuffer|*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]

# (The earlier shared-evaluator false path fb -> color_a_*/color_b_* was
# removed with the three-evaluator restructure: every evaluator now reads
# registered inputs only, so no structural fb path to those registers
# exists.  fb's only single-cycle destination is the cidx_*_r adder path.)

# Blend cone: evaluator-output registers (latched on ce_d3) -> final color
# registers (latched on ce_d1 of the NEXT tick, i.e. tick+1) = 2 clk_sys
# cycles by construction.  This cone was the consistent -1.4..-2.5 ns
# placement casualty when analyzed single-cycle.
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_a_* *u_color_mapper|color_b_* *u_color_mapper|color_fa_*}] -to [get_registers {*u_color_mapper|color_r[*]* *u_color_mapper|color_g[*]* *u_color_mapper|color_b[*]*}]

# Same cadence argument for the overlay/compositing cone: vid_pixel_*_d /
# vid_active_d update on ce_pix (fractal_top), color_mapper's output regs
# are ce_pix-enabled, and arcade_video's RGB_fix/HS/HBL capture only on
# the ce_pix rising edge (sys/arcade_video.v).  Launch and capture sit on
# the same tick grid >=4 clk_sys cycles apart.
set_multicycle_path -setup 2 -from [get_registers {*u_fractal_top|vid_pixel_x_d[*] *u_fractal_top|vid_pixel_y_d[*] *u_fractal_top|vid_active_d}] -to [get_registers {*u_arcade_video|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_fractal_top|vid_pixel_x_d[*] *u_fractal_top|vid_pixel_y_d[*] *u_fractal_top|vid_active_d}] -to [get_registers {*u_arcade_video|*}]
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|color_*}] -to [get_registers {*u_arcade_video|*}]

# Quasi-static control registers feeding the same compositing cone:
# benchmark mode/scene/telemetry (change on keypress or 10 s window),
# auto_zoom outputs and input_handler state (change per frame at most),
# color_mapper cycling/crossfade phase regs (change on vblank), and the
# OSD status bits from hps_io (change on menu interaction).  A one-tick-
# late settle of any of these into a ce_pix-sampled capture is invisible;
# none of these groups contain the ce_pix counter, so register enables
# stay single-cycle.
set_multicycle_path -setup 2 -from [get_registers {*u_fractal_top|benchmark_* *u_fractal_top|bench_* *u_fractal_top|last_bench_window_frames[*] *u_fractal_top|sym_overflow_sticky *u_fractal_top|overlay_visible *u_fractal_top|blank_text_override[*] *u_fractal_top|bg_dim_override[*] *u_fractal_top|fps_value[*] *u_fractal_top|bank_sel}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_fractal_top|benchmark_* *u_fractal_top|bench_* *u_fractal_top|last_bench_window_frames[*] *u_fractal_top|sym_overflow_sticky *u_fractal_top|overlay_visible *u_fractal_top|blank_text_override[*] *u_fractal_top|bg_dim_override[*] *u_fractal_top|fps_value[*] *u_fractal_top|bank_sel}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -setup 2 -from [get_registers {*u_auto_zoom|* *u_input|*}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_auto_zoom|* *u_input|*}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -setup 2 -from [get_registers {*u_color_mapper|cycle_phase* *u_color_mapper|pal_* *u_color_mapper|fade_* *u_color_mapper|ping_dir}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_color_mapper|cycle_phase* *u_color_mapper|pal_* *u_color_mapper|fade_* *u_color_mapper|ping_dir}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -setup 2 -from [get_registers {*hps_io*|status[*]*}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]
set_multicycle_path -hold  1 -from [get_registers {*hps_io*|status[*]*}] -to [get_registers {*u_arcade_video|* *u_color_mapper|*}]

# auto_zoom's step register roots a deep combinational cone (step_msb
# priority tree -> zoom_exp -> zoom_level_x10 -> pacing -> step_delta)
# whose captures are all vblank_rise / keypress-pulse gated — step itself
# changes at most once per display frame.  Only the step-rooted cone is
# relaxed: free_counter / LFSR / shuffle logic runs full-rate every cycle
# and must stay single-cycle.
set_multicycle_path -setup 2 -from [get_registers {*u_auto_zoom|step[*]}] -to [get_registers {*u_auto_zoom|*}]
set_multicycle_path -hold  1 -from [get_registers {*u_auto_zoom|step[*]}] -to [get_registers {*u_auto_zoom|*}]
