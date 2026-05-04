derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# clk_sys (PLL outclk_0, 50 MHz) and clk_iter (PLL outclk_1, 75 MHz)
# are independent. CDC at the iter_quad boundary uses toggle synchronizers.
set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
