# MiSTerbrot Roadmap

Forward-looking design notes for the next major work cycle. The primary target is **640×480 progressive output** (with 480i as a stepping stone). Two parallel tracks lead there: frame-rate optimisation (do first, lower risk) and an SDRAM-backed framebuffer (the gating dependency).

## Vision

Native 640×480 mandelbrot output, double-buffered, at a frame rate that feels good for the auto-zoom screensaver — call it ≥2 fps at deep zoom (z25+) and ≥10 fps at shallow zoom. The MiSTer ascaler can already upscale our 240p to 480p+ with decent quality, so the win at 480p native is **fractal detail in the boundary structure**, not raw resolution numbers.

Constraints today:
- `100% DSP usage` (112/112 blocks) — no headroom for more arithmetic units
- `78% RAM blocks` (BRAM) — the framebuffer alone is ~78% of M10K
- `clk_iter = 100 MHz` with marginal positive slack
- `clk_sys = 50 MHz` — fine
- `BRAM-only framebuffer` — 640×240 × 13 bits × 2 banks ≈ 500 KB

Going to 640×480 doubles the framebuffer to ~1 MB, which doesn't fit in BRAM. Single-buffer is ruled out — visible tearing during the slow zoom looks terrible. So **SDRAM is the gating architectural change**.

## Track A — Frame-rate optimisation (do first)

Five low-risk improvements that compound. Done before resolution change, they make 480p feel viable rather than painful.

### A1. Mariani–Silver interior detection — **deferred pending sim**

Classical fractal speedup. Trace the boundary of a rectangular region of pixels; if all boundary pixels classify identically (all interior, or all exterior with similar escape count), fill the interior of the rectangle from that classification *without* iterating each pixel.

**Status (2026-05-15):** code is in `rtl/region_manager.v` (still in tree, still in `files.qip` but not instantiated by `fractal_top.v`). The shipping core does **not** use MS — it was disabled when an intermittent hang surfaced that turned out to be a top-level race in `fractal_top.v`'s render FSM, not in `region_manager` itself. The diagnosed two-line fix removes the hang on VGA but breaks HDMI scaler synchronization regardless of timing margin. Until we have a Verilator harness to debug the HDMI-side interaction, MS is off the critical path. Full investigation transcript in `docs/MR16_HANG_REPORT.md`, `docs/MR16_HANG_REPORT_V2.md`, `docs/MR16_HANG_CHATGPT_PRO.md`, `docs/MR16_HANG_CHATGPT_PRO_V2.md`.

**Reality check from v1 bench** (when MS was usable): original 5–10× estimate was too optimistic. MS dispatches the boundary, which is geometrically nearest the fractal — i.e. the pixels with the **highest** iter counts. Baseline averages those in with cheap interior (max_iter via precheck) and cheap deep-exterior; MS concentrates on the expensive subset. Net result: 2 wins out of 10 bench scenes (TRIPLE SPIRAL +83%, JULIA ISLANDS +73%), most other scenes flat or worse. See `PERF_BASELINE_TRACK_A.md` for details.

The originally-planned sub-items (kept for reference; all blocked on the MS hang resolution):

- **A1.1 ✓** — `MIN_REGION_DIM` exposed as OSD knob (16/32/64/128). Sweep showed best MR varies per-scene by 8×, no global setting works. *(Now: OSD entry removed; MR was hardcoded to 32 as the only verified-stable value before MS was disabled.)*
- **A1.2** (parked) — 4-slot region pipelining + region_id tag through `pixel_pipeline.v`. Removes iterator starvation between regions. Expected 1.3–1.5× on slow scenes.
- **A1.3** (parked) — cache parent-boundary iter results so split children skip the shared boundary pixels. Direct attack on the redundant-work overhead at deep recursion.
- **A1.4** (parked) — per-POI `prefers_ms` flag in `tools/poi_master.json`, driven by the 86-POI benchmark. MS toggles automatically per POI based on empirical data. This was the planned headline UX win.
- **A1.bench** — ~~vsync-bypass in benchmark mode so F10 reflects raw compute~~. Reverted: bypass broke HDMI + screenshots. F10 is now permanently capped at vsync (~60 fps); see `docs/PERF_BASELINE_TRACK_A.md`.
- **A1.fix** — closed clk_iter timing at +0.424 ns slack via seed sweep (Quartus seed 5).

**Prerequisite for resuming A1:** Verilator harness for `fractal_top.v` + `region_manager.v` so the render-FSM race + HDMI scaler interaction can be probed cycle-accurately without burning 25-min build cycles per experiment. See `docs/SIMULATION.md`.

### A2. Real-axis symmetry (cy = 0 POIs) — **DONE 2026-05-16**

Mandelbrot is symmetric across `y = 0`. For POIs centred on the real axis we now compute only rows `y ∈ [0..120]` (top half + axis) and mirror-write rows `y ∈ [121..239]` from row `(240-y)`.

**Implementation:** `rtl/coord_generator.v` accepts a new `symmetry_active` input that's latched at frame start; when high it stops the scan at `y=120`. `rtl/fractal_top.v` detects `center_y == 0` (strict equality is intentional — auto-zoom drift to ε is not symmetric and must fall through to the full-frame path), latches per-frame, and feeds a small 32-deep mirror-write FIFO that drains into the framebuffer write port whenever the pipeline isn't producing a result. No CDC concerns — the FIFO lives entirely on `clk_sys`. ~120 lines net.

**Result on the 86-POI sweep** (vs the same shipping core minus A2):

| | Count |
|---|---|
| Real-axis POIs hitting ~2.00× | 8 |
| Real-axis POIs at 1.5–2.0× | 5 |
| Real-axis POIs at 1.34–1.99× (other bottlenecks) | 2 |
| Real-axis POIs already vsync-capped (no opportunity) | 2 |
| Non-real-axis POIs (regression check) | All ±2% (measurement noise) |
| **Geomean catalogue-wide** | **+11.3%** |

Visual: clean. The "thin horizontal line" sometimes visible at `y=120` is the actual Mandelbrot antenna along the real axis, not a rendering artefact.

### A3. Additional interior prechecks — **DONE 2026-05-16**

Period-3 bulb prechecks landed.  Implementation details:

- New state `S_BULB3` in `iter_quad.v` tests `(cr - P3_CX)² + (|ci| - P3_CY)² < r²`
  for the inscribed circle of the period-3 bulb.  Symmetry across the
  real axis (|ci|) lets one test catch both upper and lower bulbs.
- Constants: P3_CX = -0.1226, P3_CY = +0.7449 (super-attracting
  centers, non-real roots of c³+2c²+c+1=0); r = 0.075 (multiplier max
  ~0.81 inside, no false positives).
- 4 new POIs added to the catalogue (P3 BULB UPPER, P3 BULB LOWER,
  P3 LIMB FULL, P3 BULB DEEP).
- Per-POI opt-in flag (`precheck_p3` in poi_master.json) + OSD
  override (`O[26:25],P3 Bulb Precheck,Auto,On,Off;`).  Only POIs
  marked opt-in pay the precheck cost; everything else stays on the
  original path.

**Why opt-in:** initial always-on build regressed 3 shallow-escape
scenes by 17-34% (extra ~12 wallclock cycles per pixel for the
S_BULB3 prime+check is significant overhead when most pixels iterate
only ~5-20 times).  Per-POI flag eliminates the regression while
preserving the wins.

**Result:**
- P3 BULB DEEP: 2.5 → 59.7 fps (**23.9×** — vsync-capped, every
  pixel precheck-skipped)
- P3 BULB UPPER/LOWER: ~6.6 → ~12.0 fps (**1.79-1.80×**)
- P3 LIMB FULL: 19.9 → 29.8 fps (**1.50×**)
- Existing 86 POIs: -0.2% geomean (within noise)
- Catalogue (all 90): +5.2% geomean

Full per-POI table in `docs/PERF_BASELINE_TRACK_A.md` (entry
`a3-perpoi-osd`).

**Original spec (kept for historical context):**

> `iter_quad.v` currently short-circuits the main cardioid + period-2 bulb. Adding the **two big period-3 bulbs** on the upper/lower 1/3 limb catches more interior without iteration.
>
> - ~5–15% catalogue-wide speedup.
> - Cost: extend the existing precheck in `iter_quad.v`, share existing DSPs.
> - Effort: **1 day**.

The "5-15% catalogue-wide" estimate was conservative.  Actual measured
result: +5.2% on the 90-POI catalogue (counts the 4 new POIs that
opt in, 86 unchanged).  Original ROADMAP estimate was based on
shape-bound ~12% of M-set being inside period-3 bulbs; in our
catalogue only 4/90 POIs are positioned to benefit, hence smaller
geomean impact.

### A4. Push `clk_iter` 100 → 110 MHz

Current slack is +0.013 to +0.07 ns. Constraint tightening + possibly retiming a couple of paths could buy 10%.

- 10% throughput.
- Cost: timing-closure work, no new logic.
- Risk: doesn't close; revert.
- Effort: **0.5–2 days**.

### A5. Multi-pass progressive refinement *(not* coarse-to-fine within a frame)

Important correction: a within-frame coarse-to-fine pass would NOT improve perceived responsiveness in our current double-buffered design. The buffer swap happens only after the back buffer is fully drawn, so the user always sees a complete previous frame frozen until the next complete frame arrives. Mid-render refinement is invisible.

**What would actually work** (more involved than originally scoped):

- **Multi-pass with intermediate buffer swaps**: render a 1/16-density coarse pass first (each computed pixel paints a 4×4 block into the back buffer), swap, then a 1/4-density pass (2×2 blocks) overwriting the back buffer, swap, then full-density refinement, swap. The user sees three displayed frames per logical frame: blocky → moderate → final. Net work is the same (or slightly more due to redundant writes), but the perceived zoom is much smoother.

Effort: ~4–5 days (render-scheduler rewrite, mask-based dilated writes, swap-policy state machine).

- **Single-buffer fallback for very slow renders**: when a frame budget exceeds ~1 second, drop to single-buffer just for that frame so the user watches refinement live with tearing. Easier (~1–2 days) but contradicts the no-tearing principle we hold for double-buffer.

**Decision: defer.** The combined gain from A1-A4 alone makes the average frame fast enough that long stalls become uncommon. Revisit only if specific deep-zoom POIs still feel choppy after Track A lands.

### A6. Framebuffer dual-port write (unblock A2's "secondary bottleneck") — **shelved**

Originally proposed as a fix for real-axis POIs that don't reach a clean 2.00× speedup after A2 (FEIGENBAUM 1.67×, EJS CAULI 1.50×, M_16,8 CASCADE 3 1.34×, etc.).  Hypothesis: the per-cycle framebuffer write port is the bottleneck once A2 doubles writes per result.

**Re-analysis shelved this item.**  The bench data is dominated by **vsync harmonic snap**: render times snap to multiples of ~16.66 ms (because the render FSM waits for vblank between frames), so observed fps values are 60/N for integer N (59.6, 29.8, 19.9, 14.9, 11.9, …).  M_16,8 CASCADE 3 at A2 19.9 fps means render takes ~50 ms (N=3 harmonic); baseline at 14.9 fps is ~67 ms (N=4).  A2's compute savings shifted between harmonic floors; the 1.34× ratio is the floor-to-floor ratio, NOT a write-port bottleneck.

For A6 to deliver any visible fps gain, it would need to (a) actually be the bottleneck and (b) save enough wall-clock time to cross a harmonic boundary.  Pipeline result rate analysis shows FB write isn't even close to the limit on those POIs (typical iter takes 30+ cycles per pixel; FB write port is 1/cycle).  And saving small amounts of time rarely crosses a harmonic for fps ≥ 20.

A6 stays here as an artifact of the original hypothesis.  Don't pursue unless we find a concrete scene with measured pipeline-saturation evidence.

### A7. Per-POI `max_iter` tuning — **DONE 2026-05-17 + 2026-05-18 follow-up**

Per-POI `max_iter` is now a first-class catalogue field (`max_iter` in `tools/poi_master.json`) that feeds both:
1. **Bench mode**: `tools/gen_full_benchmarks.py` honours the override → `tools/bench_encode.py` → `rtl/benchmark_generated.vh` → `bench_max_iter` in `fractal_top.v`.
2. **Normal auto-zoom playback**: `tools/poi_encode.py` emits a `POI_ITER_CASES` macro into `rtl/poi_generated.vh`; `rtl/auto_zoom.v` exposes a `target_max_iter` output driven by the case block; `rtl/fractal_top.v` muxes it as `auto_iter_choice = auto_zoom_active ? az_max_iter : auto_max_iter` so OSD=Auto on a locked target POI uses the per-POI value instead of the zoom-tier ladder.

Profiler pipeline (FPGA-driven, not software pre-pass):
- `tools/profile_max_iter.py` — orchestrator. For each of 6 iter settings (Auto/128/256/512/1024/2048) it reloads the core, cycles the OSD to the target iter via I-key presses, runs the full 90-POI benchmark sweep via `bench_run.py`, and saves screenshots + telemetry per setting. ~110 min total.
- `tools/analyze_max_iter.py` — classifies each POI as PERF_WIN / NO_CHANGE / QUALITY_BUMP / QUALITY_FIX using a structural-diff metric (fraction of pixels that report interior at the low-iter setting but escaped at the reference) — the user's "highest iter at the max-fps plateau" rule. Falls back to lowest-diff if no setting hits visually-identical quality.
- `tools/compose_iter_grid.py` — builds per-POI 2×3 review grids for visual signoff, REC tag on the recommended setting.

**Result on sweep #2** (after applying the analyzer's rule, before the cy=0 fix): 65 per-POI overrides applied, 25 NO_CHANGE.

**Sweep #3 in progress** (2026-05-18) — re-run on the build with the cy=0 deep-zoom artifact fix.  Deep cy=0 POIs (MERCATOR P189, MERCATOR P38, EJS CAULI, R2T P6/P7, SH CUSP FINE) had spurious escape behavior masking real iter requirements; the new sweep should refine the recommendations for those.

### A8. Period detection in `iter_quad.v`

The cardioid + period-2 bulb prechecks (and A3's period-3 bulbs) catch interior points that fall inside known-shape regions. But many interior points sit OUTSIDE all those regions and converge to a long-period attractor — the iteration runs to `max_iter` even though `z` is visiting a small loop after the first dozen steps.

A period-detection check tracks `|z_n - z_{n-k}|` for some small `k` (e.g., 4, 8, 16) and declares interior the moment a near-cycle is detected. Saves the rest of the iteration budget for those points.

- Expected gain: highest on **deep-zoom and near-boundary POIs** where many pixels converge to long-period attractors but aren't precheck-able by shape. Could be 1.3–2× on those scenes; near-zero on POIs dominated by fast-escape pixels.
- Cost: extra registers per iter_quad context to hold `z_{n-k}` history. Comparator + magnitude check on the difference. Probably ~50–100 ALMs per quad. Tight DSP budget so the magnitude approximation needs to be cheap (Manhattan distance, or `|zr - zr_old| + |zi - zi_old|` instead of squared euclidean).
- Risk: false positives (declaring interior on a near-cycle that would eventually escape) → visible coloring errors near boundaries. Period detection is approximate by nature; tuning `k` and threshold requires iteration.
- Effort: **3–5 days** including hardware bring-up and tuning.

### Combined Track A target — revised after A1 v1 data

Original estimates assumed MS would deliver 5–10× as a global win. The
bench data showed that's only true for a subset of POIs. Revised targets:

| Combination | Mechanism | Expected gain |
|---|---|---|
| A1 MS (per-POI, with pipelining + caching) | Per-POI flag picks the win path; no losses | ~1.5–2× on the MS-friendly half of POIs, no regression on the rest |
| A2 Symmetry (applicable POIs) — **DONE** | Compute only y≥0, mirror y<0 | Measured: clean 2.00× on 8 POIs, 1.34–1.99× on 7 more (limited by **vsync harmonic snap** — render times snap to 16.66 ms multiples, the 1.34-1.79× POIs are at a 16.66 ms harmonic edge); **+12.6% catalogue geomean** |
| A3 Period-3 bulbs | Skip the two extra interior precheck-able bulbs | ~5–15% catalogue-wide |
| A4 Higher iter clock | Constraint tightening 100→110 MHz | 10% throughput |
| A6 FB dual-port write | **Shelved** — bottleneck is vsync harmonic snap, not FB write | ~0 (re-analysed) |
| A7 Per-POI iter caps | Avoid over-iterating POIs the auto-tier ladder over-budgets | scene-dependent, 1.5–2× on under-tuned POIs; ~5–10% geomean |
| A8 Period detection | Skip rest-of-iteration when z hits a near-cycle | 1.3–2× on long-period interior POIs; near-zero on fast-escape scenes |
| **Stacked, MS-friendly POI** | A1+A2+A3+A4+A7+A8 | ~3–5× |
| **Stacked, MS-neutral POI** | A2+A3+A4+A7+A8 only | ~1.4–1.8× |

The shift from "uniform 5–10× win" to "per-POI 2–4× win + per-POI 1.2–1.5× win"
is the honest revision. **The core stays BRAM-only, double-buffered, 240p.**
We compute frames faster on the POIs that allow it, and don't regress
elsewhere.

## Track B — SDRAM-backed framebuffer + 480i then 480p

> **SUPERSEDED (2026-07-09): see `docs/TRACKB_DESIGN.md`.**  320×480i
> shipped BRAM-only (see `docs/480I_DESIGN.md`); Track B is now scoped
> as 640×480i via DDR3.  The B1-B8 sections below predate the memory
> decision and are kept for the record — the bandwidth math and the
> line-prefetch architecture carried over, the SDRAM controller
> selection did not.

**Memory decision (2026-07-09): DDR3 via f2sdram, not the SDRAM addon.**
User has a 128 MB SDRAM module (as most MiSTer setups do), but DDR3 wins
on integration and strategy: (1) the f2sdram bridge + sysmem_lite +
safe_terminator already live in sys/ and serve the ascal today — no
custom SDRAM controller, no external-pin IO timing; (2) our bandwidth
need (~37 MB/s display reads + modest render writes) is trivial against
DDR3's >1 GB/s, and the variable shared-bus latency is absorbed by line
FIFOs we need anyway (we are a framebuffer, not a cycle-accurate memory
model — the classic pro-SDRAM determinism argument does not apply);
(3) DDR3 is shared ARM<->FPGA memory, which is exactly the Track C
perturbation scenario: the ARM computes high-precision reference orbits
in software and the core reads them directly.


Once Track A is in, resolution becomes the next gate. SDRAM unlocks 640×480 (single-buffer was rejected — tearing during the slow zoom is unacceptable).

### B1. Hardware choice

**External MiSTer SDRAM module** (DDR1, 128 MB, optional addon, dedicated to FPGA) — not HPS DDR3 via H2F. The MiSTer docs explicitly say the SDRAM module exists because HPS DDR3 has high latency and shared with Linux. For a deterministic framebuffer scan, dedicated SDRAM wins.

Side-effect: cores using the SDRAM module *require* the user to have it installed. Most enthusiast MiSTers do; some don't. **Decision: accept that limit** in exchange for clean performance.

### B2. Controller selection

Reviewed candidates:

| Controller | Verdict | Reason |
|---|---|---|
| MiSTer-PSX SDRAM/HPS path | **Avoid** | Too tied to PSX-specific HPS/DDR/Avalon infrastructure; designed for 1 MB VRAM with many ports |
| MiSTer-NeoGeo SDRAM | **Avoid** | Mature but optimised for cartridge ROM + sprite + 68k interleaved access — opposite of our linear framebuffer pattern |
| Simple Sorgelig `sdram.sv` (Amstrad-PCW, smaller cores) | Conservative base | MiSTer-native, simple, but no useful burst by default — would need extension for scanline prefetch |
| **`agg23/sdram_burst.sv`** | **Best conceptual match** | Already burst-oriented, single port, MIT-licensed, includes a full-page burst-mode controller. Less battle-tested but exactly the interface we want. |
| Roll our own minimal framebuffer DMA controller | **Probably best final form** | Our access pattern is simple enough that a custom two-client arbiter (scanline prefetch + iterator write FIFO) is straightforward |

**Recommendation:** start from `agg23/sdram_burst.sv` as the conceptual base, but keep integration MiSTer-native and minimal. If complexity gets unwieldy, fall back to extending Sorgelig's `sdram.sv` with burst-read support.

### B3. Architecture

```
Iterator core (clk_iter, 100 MHz)
    │ writes pixels (irregular rate)
    ▼
Write FIFO / burst coalescer  ◄── stages writes into burst-aligned chunks
    │
    ▼
External SDRAM framebuffer        ◄── 640×480 × 16 bit × 2 buffers ≈ 1.17 MB
    │
    ▼
Line prefetch DMA                  ◄── reads next scanline during current scanline
    │
    ▼
Ping-pong BRAM line buffers        ◄── 2 × 640 × 13 bits in BRAM
    │
    ▼
Video scanout / color_mapper       ◄── always reads from BRAM, zero SDRAM stalls
```

**Display path never reads SDRAM directly.** It reads BRAM line buffers only.

**Arbitration priority:**
1. Refresh
2. Scanline prefetch read burst
3. Iterator write bursts (drains write FIFO)

### B4. Bandwidth math — the HBLANK trap

Earlier scoping mistakenly suggested prefetching the next scanline during HBLANK. **That's wrong for 480p**:

```
640×480p ≈ VGA timing:
  pixel clock    : 25.175 MHz
  line period    : 31.77 µs
  HBLANK         : ~6.35 µs

Fetch 640 pixels (16-bit words, 1280 bytes) during HBLANK only:
  1280 / 6.35 µs ≈ 201 MB/s
```

That's at or above the **theoretical limit of 16-bit SDR SDRAM at 100 MHz** (200 MB/s). No safety margin, breaks under any real-world overhead.

**Correct design: prefetch during the entire previous scanline period.**

```
while displaying cached line N from BRAM:
    prefetch line N+1 from SDRAM into the other BRAM line buffer

Effective fetch budget:
  1280 / 31.77 µs ≈ 40 MB/s
```

40 MB/s is trivial — leaves ~160 MB/s for iterator writes and refresh.

For 480i the line period is roughly 2× longer, so it's even easier.

### B5. Framebuffer word layout

Use **16-bit framebuffer words**, not packed 13-bit. The 3 wasted bits per pixel are cheap; simpler addressing, byte-lanes, bursts, and line strides are worth more than the bits.

```
pixel word = {3'b0, escaped, iter[11:0]}   // 16 bits

framebuffer footprint:
  640 × 480 × 16 bit × 2 buffers = 1.17 MB     ← trivial for 128 MB SDRAM
```

### B6. Video timing extensions

**480i**:
- Line rate stays 15.625 kHz (same as current 240p) — no new PLL output needed
- Interlace state machine in `video_timing.v` alternating fields
- Field 0 = even lines, field 1 = odd lines
- Both fields read from the SAME framebuffer (different rows)

**480p**:
- Line rate 31.25 kHz (2× current)
- Pixel clock ~25.175 MHz (new PLL output, plus needs PLL reconfig if shared with 12.5 MHz)
- Otherwise structurally same as 480i

Both modes via new OSD bits or by extending `O[22]`.

### B7. Effort estimate

| Step | Effort |
|---|---|
| SDRAM controller selection + compile integration | 1–2 days |
| BRAM line buffers + read-prefetch DMA | 2–4 days |
| Iterator write FIFO + burst coalescer | 2–4 days |
| Double-buffer address mapping + VBLANK swap rules | 1–2 days |
| 480i video timing integration | 1–2 days |
| 480p video timing integration (new PLL output) | 1–2 days |
| On-hardware debugging + timing closure | 3–7 days |

**Realistic total: 2–3 weeks.** Best case ~1.5 weeks (controller is reusable, timing closes first try). Worst case ~4 weeks (timing closure pain or controller substitution).

### B8. Open questions

- Does our existing `iter_quad.v` `clk_iter` need to align with the new SDRAM clock domain? Probably yes — adds CDC.
- How does the SDRAM-backed framebuffer interact with single-buffer mode (`O[18]`)? Probably: single-buffer goes back to BRAM (240p single-buffer survives), double-buffer 480 uses SDRAM. Keep both paths alive.
- Does `auto_zoom.v`'s framebuffer sampling (`fb_rd_data`, `fb_rd_addr`) still work transparently? Yes — it just reads via the same line-cache path the display uses.
- What's the visible behaviour at SDRAM module absent? Either: graceful fallback to 240p BRAM, or boot-time failure with a clear OSD message. Decide before integration.

### Field-sequential rendering — TRIED AND REJECTED (2026-07-10)

Implemented, silicon-verified (including a parity-association bug
found and fixed on hardware), and then **rejected on sight by the
user** — correctly.  The fatal flaw, obvious in hindsight:

**The "2x temporal rate" benefit only exists while the render keeps
pace with the field rate (60/s).**  At the 10-20 fps of real deep
zooms, each 240-row field snapshot comes from a DIFFERENT zoom moment,
and the display slowly alternates between two temporally incoherent
half-pictures — it looks like a smeared 640x256, strictly worse than
whole-frame 480i, whose 2x render cost buys exactly the property that
both fields come from the same instant.

The whole-frame-render 480i (Track B) is therefore the keeper, along
with the Weave/Bob/Off deinterlace selector.  Do not revisit
field-sequential rendering unless a mode guarantees render >= field
rate (e.g. a capped-shallow attract preset) — and even then the
static-view case needs continuous re-rendering to keep both parities
fresh (a bank pair can never hold both fields without fresh passes).

For the record, the implementation lessons live in the git history of
2026-07-10 (three reverted commits, branchless): per-field ci ladder
(240p pitch, odd field offset step/2 — bit-exact vs the whole-480
ladder), parity via pure per-pass toggle + swap gated to the matching
field's vblank, and mandatory continuous re-render in field mode.

## Variety enhancements (secondary track)

Independent of resolution/framerate work. Worth pursuing whenever Track A/B has spare capacity. Ranked impact-vs-cost:

1. **Pan-during-zoom** — drift sideways while zooming, instead of straight-in. ~20 lines in `auto_zoom.v`. Dramatic dynamic feel.
2. **Variable zoom speed** — sigmoid pacing (fast away, slow near target).
3. **Dwell-time variation per POI** — longer dwell at deeper zoom for appreciation.
4. **Palette crossfade between POIs** — instead of instant swap, blend over 30-60 frames. ~200 ALMs.
5. **Variable color-cycling speed per palette** — per-palette `cycle_rate` lookup; some palettes (Disco Floor) work fast, others (Cream, Pearlescent) work slow.
6. **Color-cycling direction reversal** — flip cycling direction periodically.

**Already implemented (for reference):**
- Periodic zoom-out interludes — the auto-zoom state machine includes `S_ZOOM_OUT` between every POI (`rtl/auto_zoom.v`).

**Not pursuing:**

- **Rotation** during zoom — beautiful but DSP-bound (we're at 100%).
- **Perturbation theory / series approximation** for deep zoom (z40+) — 100× faster at extreme depth but weeks of work and a complete iterator rewrite. Not worth it for a screensaver currently capped at z29.85.
- **Same-palette + no-cycling testing mode** — verified separately that the current `tools/poi_compare_score.py` already catches all impactful issues. Adding reproducible-color test mode is diminishing returns.

## Recommended sequencing

Project releases follow a three-release plan with MiSTer-convention CalVer tags (`MiSTerbrot_YYYYMMDD.rbf`):

### Release 2 — polished 640×240 (current cycle)

A2 + A3 + the coord_generator frame-snapshot fix are shipped on `main`.  Remaining + done items this cycle:

- ✓ **A7** (per-POI `max_iter` override + auto-zoom playback path)
- ✓ **Color Depth selector** (`O[28:27]`, 6/8/5/4-bit output mask, default 6-bit matches the MiSTer Analog I/O R-2R DAC so HDMI = CRT)
- ✓ **Attract Mode submenu** (Zoom In/Out toggles + Wait on POI with 22 options including N-color-cycle durations; wall-clock dwell)
- ✓ **cy=0 deep-zoom artifact fixed** in iter_quad (negative-square clamp; root cause was truncated multiplier producing tiny-negative `z²` results whose sign extension into the upper bits triggered spurious overflow → spurious escape at iter=1..2 → uniform pink band on deep cy=0 POIs)
- ⏳ **A7 sweep #3** running on the build with the cy=0 fix — recommendations for the 5-7 affected deep-zoom POIs may shift.
- ⏳ **Cardioid precheck clamp** (apply the same negative-clamp protection to `ctx_cardioid_ci_sq` storage; small perf fix for deep cy=0 POIs whose cardioid precheck was firing less than it should).
- ⏳ **Other polish items the user has noticed** — TBD list.
- ⏳ **Final full bench sweep** to capture the v2 baseline.
- ⏳ **Update README, ROADMAP, PERF_BASELINE_TRACK_A** at release time.
- ⏳ **Tag the release.**

### Release 3 — Verilator harness, MS revival, then SDRAM/480i

The Verilator harness for `fractal_top + region_manager` is the gating dependency for **both** A1 (Mariani-Silver) and Track B (SDRAM).  Doing them in the same release amortises the harness investment.

1. **Verilator harness** for `fractal_top + region_manager` (~2–4 days).  Goal: reproduce the MR=16 hang deterministically + verify the ChatGPT Pro two-line fix removes it + investigate why the fix breaks HDMI scaler synchronisation by diff'ing waveforms.
2. **A1 (MS revival)** with sim-driven debug (~2–3 days on top of the harness).  Includes A1.4 (per-POI `prefers_ms` flag, same pattern as A3's per-POI flag).
3. **A4** (clk_iter 100→110 MHz) — opportunistic.  Tight harmonic-snap budget, may not deliver visible fps gain.  Try if it's quick.
4. **A8** (period detection) — biggest individual logic addition.  Schedule late in this release if there's budget.

### Release 4 — SDRAM-backed 480i then 480p (Track B)

After Release 3's harness is proven on MS, Track B becomes tractable:

1. **Track B 480i** on top of Release 3.  Same line rate (15.625 kHz), 15-kHz-CRT-compatible.  **~2 weeks.**
2. **Track B 480p** as a final step.  Adds PLL reconfig and 31 kHz timing — breaks strict 15 kHz CRT support.  **~1 week on top of 480i.**
3. **Variety enhancements** interleaved as recovery sprints between tracks.

### Shelved / deprioritised

- **A6** (FB dual-port write): re-analysis showed the bottleneck on A2-residual POIs is vsync harmonic snap, not FB write port.  Don't pursue unless we find concrete pipeline-saturation evidence on a specific scene.

### Total budget

End-to-end (R2 + R3 + R4): **~5–7 weeks** of focused work to land 480p with the full Track A stack, MS, and SDRAM.

## Out of scope

- Rotation
- Audio output (would be a fun secondary feature but unrelated)
- Multi-fractal modes (Burning Ship, Tricorn) — explicitly removed earlier
- Stereoscopic / 3D output
- Network/cloud features
- Save/load coordinates beyond the POI catalogue
