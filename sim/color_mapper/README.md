# color_mapper equivalence bench

`tb_cm_equiv.sv` drives the committed, evaluator-based `color_mapper_old.v`
(frozen snapshot of rtl/color_mapper.v as of e18e857, module renamed) and the
current rtl/color_mapper.v with identical inputs and compares the colour
outputs pixel for pixel: 10 palettes, cycling on/off, band modes, hard blend,
ping-pong direction, crossfade and instant transitions.

Two documented differences are excluded: the frame before the first vblank
(BRAM tables are undefined until the first fill) and the first frame after a
palette change (the BRAM design applies the change at the next vblank, the
old one mid-frame).  Everything else must be bit-identical.

```
cd sim/color_mapper
verilator --binary --timing -Wno-fatal -Wno-WIDTH --top tb_cm_equiv tb_cm_equiv.sv color_mapper_old.v ../../rtl/color_mapper.v -o tb -j 6
./obj_dir/tb      # expect: compared=123488 ... mismatches=0 / TB PASS
```
