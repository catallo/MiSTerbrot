# pixel_pipeline frame-time bench

`tb_pp.sv` streams one 640x240 frame of catalogue coordinates through
`pixel_pipeline` (dispatch/collect + four `iter_quad`s) in scan order and
prints the clk_sys cycles to `frame_done` plus an order-independent checksum
of every result.  Use it to judge a dispatch/collect change for speed AND
bit-identity before spending a Quartus build.

```
cd sim/pixel_pipeline
verilator --binary --timing -Wno-fatal -Wno-WIDTH -I../../rtl --top tb_pp \
    tb_pp.sv ../../rtl/pixel_pipeline.v ../../rtl/iter_quad.v ../../rtl/mul_trunc64.v -o tb_pp -j 6
./obj_dir/tb_pp +scene=1
```

Scenes: 0 P3 ISLAND z5 · 1 SEAHORSE BODY z7 · 2 JULIA ISLANDS z4 ·
3 SAT HEAD z22 (interior-bound, ~1 min) · 4 ANTENNA BAND MERGE z3.

Reference (2026-10-12, round-robin collect → first-pending priority collect,
checksums identical on all five scenes):

| scene | cycles before | cycles after | gain |
|------:|--------------:|-------------:|-----:|
| 0 | 799,119 | 715,451 | 10.5% |
| 1 | 2,038,185 | 1,975,041 | 3.1% |
| 2 | 627,330 | 600,099 | 4.3% |
| 3 | 15,807,903 | 15,712,847 | 0.6% |
| 4 | 943,820 | 895,543 | 5.1% |

Scene 1 checksum: `74fe0134ce1a4d66` — any dispatch/collect change must keep it.
