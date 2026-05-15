# Verilator harness for rtl/iter_quad.v
#
# Build the simulation:   make
# Run the tests:          make run
# Trace dump (FST):       make wave (then `gtkwave obj_dir/sim.fst`)
# Clean:                  make clean

VERILATOR ?= verilator
RTL       := ../../rtl
TOP       := iter_quad
SOURCES   := $(RTL)/iter_quad.v $(RTL)/mul_trunc64.v
HARNESS   := tb_$(TOP).cpp
EXEC      := obj_dir/V$(TOP)

# Verilator flags:
#   --cc      generate C++ output
#   --exe     wrap with C++ main
#   --build   build the executable in one step
#   --trace-fst   enable FST trace dump (smaller than VCD)
#   -Wno-fatal    don't fail on warnings
#   --top-module  declare which module is top (since the file has comments etc.)
VERILATOR_FLAGS := --cc --exe --build --trace-fst \
                   -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   --top-module $(TOP)

all: $(EXEC)

$(EXEC): $(HARNESS) $(SOURCES)
	$(VERILATOR) $(VERILATOR_FLAGS) $(SOURCES) $(HARNESS)

run: $(EXEC)
	$(EXEC)

wave: $(EXEC)
	$(EXEC) +trace
	@echo "Run: gtkwave obj_dir/sim.fst"

clean:
	rm -rf obj_dir

.PHONY: all run wave clean
