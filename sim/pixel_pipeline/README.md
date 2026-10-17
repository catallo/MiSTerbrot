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

Scene 1 checksum: `025d9feda50278c4` since the 26-bit-limb three-squares quad
of 2026-10-15 (`85b61ebef8d12d8a` for its 32-bit-limb first cut the same day,
`74fe0134ce1a4d66` for every engine from 2026-07 to 2026-10-14) — any
dispatch/collect change must keep it; only an arithmetic change in iter_quad
may move it, and then all scenes get new values together (scene 0
`68c4dd111749a118`, 2 `d87d47036503cbe0`, 3 `8a3f4046237621b1`, default
`463bda20ddeb55c3`).

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

Three-squares quad, eight quads (2026-10-15, `NI = 64`): the cross product
2·zr·zi is now (zr+zi)² − zr² − zi² (9 DSP per quad instead of 15, so eight
quads fit in 105 of 112 blocks).  NOT bit-identical: checksums
`85b61ebef8d12d8a` / `84f1f064fe7de454` / `0498904ef2d8b4e6` /
`278c426417ebb095`; against the previous engine 0.02–2.1% of the pixels per
scene differ (boundary points, deep zoom most), and on a 150-pixel sample of
those a 200-bit mpmath reference agrees with the old engine 17 times and the
new one 15 — the two are equally accurate, the rest are chaotic orbits
beyond 56-bit precision.  Cycles with 64 iterators: 1,545,781 → 968,988 /
458,062 → 304,196 / 12,516,819 → 7,823,645 / 673,084 → 427,717 (−34…−38%,
ideal 64/40 = −37.5%).  `+dump=<file>` in tb_pp writes one line per result
for such engine-to-engine diffs.

Slot coordinate store in the quad (2026-10-16): pixel_pipeline's per-slot
cr/ci register file became an 8 x 128 dual-clock RAM per quad (`mem_ld`,
written by the dispatcher on clk_sys, read at phase_d3) and the pixel tags
one MLAB; the start synchronizer grew to 4 FFs.  Same checksums at `NI` 64,
80 and 96; scene 1 cycles 740,634 → 740,711 (64) → 594,732 (80) → 498,608
(96), i.e. 1.25x and 1.49x for ten and twelve quads.

Bench views: `+cxraw=<hex 8.56> +cyraw=<hex> +stepraw=<hex> +maxiter=<n>
+p3=<0|1>` render any catalogue view (tools/benchmarks.json) on the DEVICE
grid — in 640-wide mode the horizontal step is step/2 and every row sits
half a row pitch off the axis, exactly as coord_generator does (the named
scenes keep the plain ±W/2·step grid their checksums were taken on).  With
`clk_iter` modelled at 130 MHz (`ITER_HALF_NS`, override with
`-GITER_HALF_NS=`), `cycles / 50 MHz` is the frame time; `-GH=480` renders
the 480-row frame.  Checked 2026-10-16: the predicted 60/N vsync rate matches
the measured bench rate on all 90 scenes (bench mode renders 640x240).
