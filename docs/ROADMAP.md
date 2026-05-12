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

### A1. Mariani–Silver interior detection — biggest single win

Classical fractal speedup. Trace the boundary of a rectangular region of pixels; if all boundary pixels classify identically (all interior, or all exterior with similar escape count), fill the interior of the rectangle from that classification *without* iterating each pixel.

At deep zoom where the set's interior fills large connected regions of the framebuffer, this can be **5–10× faster** because we stop wasting DSP cycles on bulb interiors.

- Implementation: recursive region splitter in `clk_sys`, dispatches boundary-only pixel coords to the existing iterator pipeline, fills the interior in the framebuffer write path.
- Cost: ~500 lines new logic, no new DSPs.
- Risk: regions misclassified at boundary precision (mitigation: minimum region size threshold).
- Effort: **3–5 days**.

### A2. Real-axis symmetry (cy = 0 POIs)

Mandelbrot is symmetric across `y = 0`. For POIs centred on the real axis (Feigenbaum cascade, antenna POIs, half the Seahorse Valley descent — ~20+ entries in our 86-POI catalogue) we compute only `y ≥ 0` and mirror-write `y < 0`.

- ~1.9× faster for applicable POIs.
- Implementation: detect `cy ≈ 0` in `coord_generator.v`, skip lower-half dispatch, framebuffer write mirroring.
- Cost: ~50 lines but careful CDC across `clk_sys` / `clk_iter`.
- Effort: **1–2 days**.

### A3. Additional interior preches

`iter_quad.v` currently short-circuits the main cardioid + period-2 bulb. Adding the **two big period-3 bulbs** on the upper/lower 1/3 limb catches more interior without iteration.

- ~5–15% catalogue-wide speedup.
- Cost: extend the existing precheck in `iter_quad.v`, share existing DSPs.
- Effort: **1 day**.

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

### Combined Track A target

| Combination | Gain at z10-15 | Gain at z25 |
|---|---|---|
| A1 Mariani-Silver | 5-10× | 3-5× |
| A2 Symmetry (applicable POIs) | 1.9× | 1.9× |
| A3 Period-3 bulbs | 1.1× | 1.05× |
| A4 Higher iter clock | 1.1× | 1.1× |
| **Stacked (A1-A4)** | **~10×** | **~6×** |

Roughly **1.5–2 weeks total** for a 5–10× framerate boost — and crucially, no architectural changes. The core remains BRAM-only, double-buffered, 240p. We just compute frames faster.

## Track B — SDRAM-backed framebuffer + 480i then 480p

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

## Variety enhancements (secondary track)

Independent of resolution/framerate work. Worth pursuing whenever Track A/B has spare capacity. Ranked impact-vs-cost:

1. **Pan-during-zoom** — drift sideways while zooming, instead of straight-in. ~20 lines in `auto_zoom.v`. Dramatic dynamic feel.
2. **Variable zoom speed** — sigmoid pacing (fast away, slow near target).
3. **Dwell-time variation per POI** — longer dwell at deeper zoom for appreciation.
4. **Periodic zoom-out interludes** — every Nth POI, zoom out to overview for context.
5. **Palette crossfade between POIs** — instead of instant swap, blend over 30-60 frames. ~200 ALMs.
6. **Variable color-cycling speed per palette** — per-palette `cycle_rate` lookup; some palettes (Disco Floor) work fast, others (Cream, Pearlescent) work slow.
7. **Color-cycling direction reversal** — flip cycling direction periodically.

**Not pursuing:**

- **Rotation** during zoom — beautiful but DSP-bound (we're at 100%).
- **Perturbation theory / series approximation** for deep zoom (z40+) — 100× faster at extreme depth but weeks of work and a complete iterator rewrite. Not worth it for a screensaver currently capped at z29.85.
- **Same-palette + no-cycling testing mode** — verified separately that the current `tools/poi_compare_score.py` already catches all impactful issues. Adding reproducible-color test mode is diminishing returns.

## Recommended sequencing

1. **Track A first** (frame-rate optimisations). Cheap, no architectural change, immediate quality improvement. **1.5–2 weeks.**
2. **Track B 480i** on top of Track A. Single PLL output, simpler timing. **~2 weeks.**
3. **Track B 480p** as a final step. Adds PLL reconfig and 31 kHz timing. **~1 week on top of 480i.**
4. **Variety enhancements** interleaved as recovery sprints between tracks.

Total: **~5 weeks** of focused work to land 480p with Mariani-Silver + symmetry savings.

## Out of scope

- Rotation
- Audio output (would be a fun secondary feature but unrelated)
- Multi-fractal modes (Burning Ship, Tricorn) — explicitly removed earlier
- Stereoscopic / 3D output
- Network/cloud features
- Save/load coordinates beyond the POI catalogue
