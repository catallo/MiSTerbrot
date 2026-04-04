##============================================================================
## Verilator Simulation Makefile
##
## Targets:
##   test_iter_pair - Build and run iter_pair testbench (active)
##   clean          - Remove build artifacts
##
## Disabled targets (stale, need update for current RTL):
##   test_iterator  - Was: mandelbrot_iterator unit test (missing mul_trunc64)
##   test_pipeline  - Was: pixel_pipeline integration (wrong iterator module)
##============================================================================

VERILATOR   = verilator
RTL_DIR     = ../rtl
VFLAGS      = --cc --exe --build -Wall -Wno-UNUSED -Wno-UNDRIVEN \
              -CFLAGS "-std=c++14 -O2"

.PHONY: all test_iter_pair clean

all: test_iter_pair

## iter_pair testbench (current active iterator)
test_iter_pair: obj_dir_pair/Viter_pair
	@echo ""
	@echo "========================================"
	@echo "Running iter_pair Testbench"
	@echo "========================================"
	@./obj_dir_pair/Viter_pair

obj_dir_pair/Viter_pair: tb_iter_pair.cpp $(RTL_DIR)/iter_pair.v
	$(VERILATOR) $(VFLAGS) \
		--Mdir obj_dir_pair \
		-o Viter_pair \
		$(RTL_DIR)/iter_pair.v \
		tb_iter_pair.cpp

## --- DISABLED: stale targets from pre-iter_pair architecture ---
## Iterator testbench (mandelbrot_iterator.v depends on removed mul_trunc64)
#test_iterator: obj_dir_iter/Vmandelbrot_iterator
#	@./obj_dir_iter/Vmandelbrot_iterator
#obj_dir_iter/Vmandelbrot_iterator: tb_iterator.cpp $(RTL_DIR)/mandelbrot_iterator.v
#	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_iter -o Vmandelbrot_iterator \
#		$(RTL_DIR)/mandelbrot_iterator.v tb_iterator.cpp

## Pipeline testbench (pixel_pipeline now uses iter_pair, not mandelbrot_iterator)
#test_pipeline: obj_dir_pipe/Vpixel_pipeline
#	@./obj_dir_pipe/Vpixel_pipeline
#obj_dir_pipe/Vpixel_pipeline: tb_pipeline.cpp $(RTL_DIR)/pixel_pipeline.v $(RTL_DIR)/coord_generator.v $(RTL_DIR)/mandelbrot_iterator.v
#	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_pipe -o Vpixel_pipeline \
#		-GN_ITERATORS=4 -GH_RES=8 -GV_RES=8 \
#		$(RTL_DIR)/pixel_pipeline.v $(RTL_DIR)/coord_generator.v \
#		$(RTL_DIR)/mandelbrot_iterator.v tb_pipeline.cpp

clean:
	rm -rf obj_dir_iter obj_dir_pipe obj_dir_pair obj_dir_pair_check
