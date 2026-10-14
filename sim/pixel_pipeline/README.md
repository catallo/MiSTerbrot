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

Five quads (2026-10-13, `verilator -GNI=30 ...`): same checksums, cycles
715,451 → 572,625 / 1,975,041 → 1,580,312 / 600,099 → 481,700 /
895,543 → 717,128 (−20% on every scene).  Enabled by the 27-bit DSP limbs in
iter_quad (21 → 15 DSP blocks per quad, 108 of 112 in use with five).

Eight-context quad (2026-10-14, the default `NI = 40`): same checksums,
cycles 1,580,312 → 1,533,597 / 481,700 → 448,051 / 12,569,831 → 12,509,275 /
717,128 → 661,547.  The extra gain is the end of the "priming" passes — the
old quad discarded one full pass after every state transition (load,
cardioid, bulb, period-3) although the pass already read the new operands;
`NI` must now be a multiple of 8.

118 MHz pipeline (2026-10-14 b: extra limb-combine stage S2a0, cr-1/4 in
its own context RAM, flag writeback registered in S7): same checksums,
cycles 1,533,597 → 1,542,818 / 448,051 → 456,931 / 12,509,275 → 12,517,056 /
661,547 → 672,013 (+0.1…2%: two more cycles of latency per pixel slot, the
iteration rate per context is unchanged) — paid back many times by the
108.33 → 118.18 MHz clock.
