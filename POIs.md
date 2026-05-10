# MiSTerbrot POI System

How the auto-zoom Point-Of-Interest playlist is sourced, verified, encoded into the FPGA, and displayed. Distilled from the work that took the playlist from 25 hand-typed coords (many mislabeled) to 74 cross-validated canonical POIs.

## 1. The numeric model

The core does fractal math in **64-bit signed fixed-point, `8.56` format**: 8 integer bits, 56 fractional bits, two's complement.

| Quantity | Value |
|---|---|
| LSB | `2⁻⁵⁶` ≈ `1.39 × 10⁻¹⁷` |
| Max representable | `+127.999…` |
| Min representable | `-128` |
| `DEFAULT_STEP` (1 pixel @ zoom 0) | `0x0003333333333333` ≈ `0.0125` |
| View width (320 mode @ zoom 0) | `320 × DEFAULT_STEP` = `4.0` (the standard Mandelbrot window) |

### Zoom level convention

`zoom_level` is the **log₂ magnification** relative to the default view:

```
step = DEFAULT_STEP / 2^zoom_level
view_width = step × H_RES = 4.0 / 2^zoom_level
magnification = 2^zoom_level
```

So `zoom_level = 10` means each pixel covers `4.0 / 1024 / 320 ≈ 1.2 × 10⁻⁵` units of the complex plane, and the view covers `~4 × 10⁻³` units across (~1024× zoom).

`zoom_level_x10` (10× the level) appears in two places in the RTL:
- `target_max_zoom_x10` per-POI table — the zoom depth where auto-zoom should stop and dwell
- `zoom_level_x10` runtime value — computed from `step_msb` so the comparison `zoom_level_x10 ≥ target_max_zoom_x10` triggers cleanly with sub-integer precision

The OSD overlay renders zoom as `X2^N.M` where `N.M = zoom_exp + zoom_frac_tenth/10`.

## 2. Practical zoom limits

| What | Zoom level | Magnification | Why |
|---|---|---|---|
| Theoretical floor | ~49.7 | ~9 × 10¹⁴ | `step` reaches `1 LSB` |
| Pixel-precision floor | ~46 | ~7 × 10¹³ | Adjacent pixels stop differing (need ≥10 LSB/pixel) |
| Quality floor @ max_iter=2048 | ~35–40 | ~10¹⁰–10¹² | Escape orbits run out of iterations near boundary |
| Quality floor @ max_iter=1024 | ~28–33 | ~10⁸–10¹⁰ | |
| Quality floor @ max_iter=512 | ~20–25 | ~10⁶–10⁷ | |
| Quality floor @ max_iter=256 | ~15–18 | ~3×10⁴–3×10⁵ | |

Rule of thumb: **doubling `max_iter` buys ~5–7 more usable zoom levels**. Past the quality floor, interior pixels start "filling in" (escape doesn't happen within budget, so they get classified as set-interior) and the boundary becomes blocky.

The deepest POI in the playlist (`JULIA ISLANDS`, Beyer step 12) sits at `X2^29.85` ≈ `10⁹×`. Comfortably inside the floor at 2048 iterations.

## 3. Acquisition workflow (the actual pipeline)

```
            tools/poi_master.json
                    │
                    ▼
       ┌────────────┼────────────┐
       │            │            │
       ▼            ▼            ▼
 poi_render.py  poi_encode.py  poi_flag_bad.py
       │            │            │
       ▼            ▼            ▼
 screenshots/    rtl/         (text report:
   poi/*.png    poi_         flag solid-color
   (visual      generated.vh   thumbnails)
   verify)      (macros)
       │            │
       │            ▼
       │    auto_zoom.v + text_overlay.v
       │    `include` consume the macros
       │            │
       └────────────┴───────────► visual review → iterate
```

`tools/poi_master.json` is the **single source of truth**. Everything else is generated from it.

### Step-by-step: adding/editing POIs

1. Edit `tools/poi_master.json` — one object per POI:
   ```json
   {
     "name": "SEAHORSE TAIL",
     "cx": -0.7435669,
     "cy": 0.1314023,
     "zoom_level": 10.77,
     "category": "SEAHORSE",
     "sources": ["https://commons.wikimedia.org/wiki/...", "https://mrob.com/pub/muency/..."],
     "note": "Beyer step 4, seahorse tail spirals"
   }
   ```
2. `python3 tools/poi_render.py` — render thumbnails to `screenshots/poi/idx_NNN_*.png`
3. **Look at every thumbnail.** Verify the named feature is centered and visible at the configured zoom.
4. `python3 tools/poi_flag_bad.py` — flags solid-color/mostly-interior images for hand-tuning.
5. Hand-tune any flagged POIs (adjust `cx`/`cy` or `zoom_level`), re-render, re-verify.
6. `python3 tools/poi_encode.py` — generates `rtl/poi_generated.vh` (deterministic, roundtrip-verified).
7. Rebuild the core (`quartus_sh --flow compile MiSTerbrot` — see `README.md → Building`).
8. On hardware, press `M` (or gamepad X) to snap through the playlist and visually verify on the actual display.

**Never hand-edit `rtl/poi_generated.vh`** — it's regenerated.

## 4. Source quality is the limiting factor

The biggest lesson: **most "POI lists" you find online have errors**. Coords get retyped, decimal points slip, names get assigned to features they don't actually point at. A POI is only as good as the sources it agreed across.

**Authoritative sources** (rank-ordered by trustworthiness):

1. **Robert Munafo's Mu-Ency** — `mrob.com/pub/muency/`. Decades-old, mathematically rigorous, treats coords as exact mathematical objects. Best source for Misiurewicz points, period-N bulb nuclei, named features (Seahorse Valley, Elephant Valley, Triple Spiral Valley, Feigenbaum Point, embedded Julia sets, medallions).
2. **Wikipedia** — `en.wikipedia.org/wiki/Mandelbrot_set` and `Misiurewicz_point`. Beyer's zoom sequence file metadata is the canonical seahorse-valley waypoint catalog.
3. **Wolfram MathWorld** — `mathworld.wolfram.com/SeaHorseValley.html` and `ElephantValley.html`. Concise, named-feature definitions.
4. **Paul Bourke** — `paulbourke.net/fractals/mandelbrot/`. Published zoom-sequence waypoints with named features (Tante Renate, Spirals, Lightning, Filament).
5. **Mandelmap** — `mandelmap.com`. Paid POI poster; names are canonical even when full coords aren't free.
6. **Wikibooks Fractals** — period-N nucleus catalogs.
7. **ResearchGate papers** on spiral medallions (Romera et al.) — multiple-spiral medallion coords.
8. **mathr.co.uk** — Location-analysis tool & deep-zoom database.

**Single-source coords are weak candidates.** Demand cross-validation to ≥4 decimal digits across at least two of the above. For coords from random blog posts or YouTube descriptions, treat as guesses until confirmed.

## 5. Common naming/coord pitfalls

Most of these came up during the original 25-POI audit. Watch for them when grading proposed POIs.

| Mistake | What's actually there | What you probably meant |
|---|---|---|
| "Cardioid Interior" at `(0.25, 0)` | Cardioid **cusp** (boundary) | Move to `(0, 0)` — the nucleus of R2a, true interior |
| "Period-2 Neck" at `(-1.4, 0)` | **Feigenbaum Point** (period-doubling cascade endpoint) | Move to `(-0.75, 0)` — the actual P2/main-cardioid neck |
| "Elephant *" at `(-1.7, 0)` or `(-0.1, 0.6)` | Antenna-region minibrots / 1/3-limb territory | Elephant Valley is at `(+0.275, +0.007)` — RIGHT side |
| "Baby Mandelbrot" at `(-0.1528, 1.04)` | Generalized **Feigenbaum Point** of 1/3 limb | Real minibrots: period-3 island at `(-1.75, 0)`, or period-3 bulb center `(-0.125, 0.744)` |
| "Triple Spiral" anywhere in upper half | Wrong location | Canonical Triple Spiral Valley: `(-0.0875937, 0.6550903)` |
| "Antenna Tip" at exactly `(-2, 0)` zoom > 4 | Mostly OUTSIDE the set — 99% featureless | Center slightly inward (e.g. `-1.7` at zoom 2) OR use the M₂,₁ exact `c = -2` only at very low zoom |
| Any "BULB CENTER" framed at `zoom = 4` | Entirely inside the bulb (radius 0.25 = view width 0.25) | Zoom 2 for P2, zoom 5–6 for smaller bulbs |
| Deep coords with only 4 decimals | Centered at wrong place by far past zoom 10 | Use ≥7 decimals for `zoom_level ≥ 10` |

The trap to internalize: **a feature documented as "centered at (cx, cy)" in low-precision sources is approximate.** Past `zoom_level ≈ 10` the configured coord must match the actual feature center to ~10⁻⁴ or the named structure ends up off-screen. The famous case of `STARFISH` (configured `(-0.374, 0.6598)` zoom 16) sits with the sunburst pattern off to one side — original was probably eyeballed from a low-zoom screenshot.

## 6. Visual verification: the only way to be sure

Source agreement guards against bad coords. **Visual verification** guards against:
- Coord typos in your own JSON
- Sources that agree on a wrong name for a feature
- Cases where the named feature exists but isn't framed by the configured zoom
- Cases where the feature requires more iterations than the renderer can afford

### `tools/poi_render.py`

NumPy-vectorized Mandelbrot renderer producing 200×150 thumbnails. Key implementation notes:

- Uses smooth escape coloring (`mu = n − log₂(log₂(|z|²)/ln(2))`) to approximate what the FPGA's escape-count rendering will produce.
- `max_iter` scales with `zoom_level`:
  - `zoom < 12`: 1024
  - `12 ≤ zoom < 18`: 2048
  - `18 ≤ zoom < 24`: 4096
  - `zoom ≥ 24`: 8192
- Without this scaling, deep-zoom POIs render as all-black because escape doesn't happen within the budget.
- Pixel grid is symmetric around `(cx, cy)` — the same convention the FPGA core uses.
- Output: `screenshots/poi/idx_NNN_<safe_name>.png`. Indexed by the order in `poi_master.json`.

### `tools/poi_flag_bad.py`

Heuristic auditor. Reads thumbnails, classifies each as:
- `ALL-BLACK`: 100% interior → bad (or max_iter too low)
- `mostly-interior`: > 85% interior → likely bad framing
- `low-detail`: stddev < 30 across all pixels → suspect (uniform color region)
- `ok`: passes

Common false-positive: deep boundary zooms with 0% set-interior pixels look "no-set-visible" but are actually beautiful — the rule of thumb is that anything with `stddev ≈ 90` (lots of color variation) is fine even with no interior.

### Visual review

There is no substitute for **looking at every thumbnail**. Tools flag obvious failures. Subtle ones (named feature off-center, named feature at wrong scale) need human eyes. Plan 1–2 minutes per POI for a thoughtful review on the first pass.

### Renderer aspect ratio note

The Python renderer outputs `200×150` (4:3) — same aspect as the FPGA's `320×240` and `640×480` modes, so framing matches what you'll see on the actual display. Don't change the renderer's aspect ratio without re-rendering all thumbnails.

## 7. Fixed-point encoding (`tools/poi_encode.py`)

Decimal → `8.56` fixed-point conversion is deterministic:

```python
SCALE = 1 << 56
raw = int(round(value * SCALE))
if raw < 0: raw += 1 << 64       # two's complement
hex64 = f"64'sh{raw:016X}"
```

Roundtrip back to decimal: `from_8_56(raw) = (raw - (1<<64) if raw & (1<<63) else raw) / SCALE`. The encoder verifies roundtrip error stays below `10⁻¹⁴` for every POI — anything worse means the coord is too close to the LSB and won't render meaningfully.

Output is `rtl/poi_generated.vh` — four `` `define `` macros expanding to `case`-statement bodies:

| Macro | Used in | Body |
|---|---|---|
| `POI_ROM_CASES` | `auto_zoom.v` | `rom_cx`, `rom_cy` assignments per `target_idx` |
| `POI_ZOOM_CASES` | `auto_zoom.v` | `target_max_zoom_x10` (10-bit, `zoom_level × 10`) |
| `POI_ZOOM_INT_CASES` | `auto_zoom.v` | `target_zoom_int` (5-bit, `round(zoom_level)` — used by snap mode) |
| `POI_NAME_CASES` | `text_overlay.v` | `target_name_full` (20-char overlay string) |

Plus three width constants: `POI_N_TARGETS`, `POI_IDX_BITS`, `POI_LAST_IDX`.

The macros work because Verilog `` `define `` expansion happens before compilation — each include site sees the full body inline.

## 8. RTL integration

- `target_idx` width comes from `POI_IDX_BITS` macro (currently 7 bits for 74 POIs; expand to 8 if you go past 128).
- `target_playlist[]` storage and `target_playlist_pos` cursor follow the same width.
- The Fisher-Yates shuffle (`next_shuffle_candidate`) is parameterized — bit-width comes from `IDX_BITS`. With 4 random candidates per attempt at 7 bits each = 28 bits of `rand_state` consumed; ~3% fallback rate for target shuffle (max_idx = 73), ~16% for palette (max_idx = 46).
- `snap_step = DEFAULT_STEP >>> target_zoom_int` — barrel shift by per-POI integer amount. Snap mode (`S_HOLD`) holds the view at this step indefinitely until another `snap_next` pulses.

If `N_TARGETS` ever exceeds 128, all the bit-widths and the shuffle function need to bump from 7 to 8 bits, plus `target_playlist[]` array depth, plus the `text_overlay.v` `target_idx` port width, plus all `7'dN` literals in the state machine.

## 9. OSD / overlay display

`text_overlay.v` consumes `POI_NAME_CASES` from the same generated header. Each POI name is a 20-char uppercase ASCII string (160 bits). Longer "lines" (32-char `target_line`, 48-char `target_poi_palette`) are derived by concatenation:

```verilog
target_line       = {target_name_full(idx), 12-space-padding}                  // 32 chars
target_poi_palette = {target_name_full(idx), " | ", palette_name(pal), 13-space-padding}  // 48 chars
```

This means **changing a POI name only requires editing `poi_master.json`** — all three width-variants update automatically through the macro pipeline. The old design had three duplicated case statements; consolidating to a single 20-char base + concat removed ~120 lines of duplicated string data.

## 10. The M-key feedback loop

Hardware verification is the gold standard. The `M` key (and gamepad X button) implements a "snap mode":

- Press `M` once: jump current POI to its canonical `(cx, cy, target_zoom_int)` view and **freeze** there in state `S_HOLD`. No animation, no auto-progress.
- Press `M` again: advance playlist + re-snap to the next POI. Stays frozen.
- Press `Z`: exit snap mode (auto-zoom is now disabled — press `Z` again to re-enable normal zoom-in).
- Press `N`: same as normal — skip to next POI but with the slow zoom-in animation.

This closes the verification loop: build → deploy → press `M` repeatedly → visually confirm every POI's named feature is centered and recognizable at the configured zoom. About 3 seconds per POI = ~4 minutes to walk all 74. Without this, verifying 74 POIs would mean ~30 minutes of waiting for slow zooms.

## 11. Common workflow patterns

### Adding a new POI from a known canonical source

1. Find ≥2 published sources giving the coord to ≥6 decimals.
2. Append to `tools/poi_master.json` with name (≤20 chars), coord, `zoom_level`, category, `sources` array, short `note`.
3. `python3 tools/poi_render.py` → look at the new thumbnail.
4. If framing's bad: nudge `zoom_level` ±1, or adjust `cx`/`cy` toward the actual feature center.
5. Re-render until the thumbnail clearly shows the named feature.
6. `python3 tools/poi_encode.py` → regenerated `rtl/poi_generated.vh`.
7. Rebuild + deploy + verify with `M` on hardware.

### Diagnosing a "this POI looks weird on the FPGA" report

1. Check the thumbnail in `screenshots/poi/`.
2. If thumbnail is fine → likely an FPGA precision / iteration issue. Increase `max_iter` via OSD.
3. If thumbnail is also bad → POI coord/zoom is wrong. Fix in `poi_master.json` and regenerate.

### Adding a brand-new feature category

If a new category appears (e.g., `SWIRL`, `DENDRITE`, etc.):
- Add to the comment in `poi_master.json`'s schema preamble (this file).
- No code change — `category` is informational, not consumed by the RTL.

## 12. References

- **Wikipedia: Mandelbrot set** — https://en.wikipedia.org/wiki/Mandelbrot_set
- **Wikipedia: Misiurewicz point** — https://en.wikipedia.org/wiki/Misiurewicz_point
- **Mu-Ency (Munafo)** — https://mrob.com/pub/muency/
  - Seahorse Valley: https://mrob.com/pub/muency/seahorsevalley.html
  - Elephant Valley: https://mrob.com/pub/muency/elephantvalley.html
  - Triple Spiral Valley: http://www.mrob.com/pub/muency/triplespiralvalley.html
  - Feigenbaum Point: http://www.mrob.com/pub/muency/feigenbaumpoint.html
  - Embedded Julia Sets: https://mrob.com/pub/muency/embeddedjuliaset.html
  - Spiral Medallions: https://mrob.com/pub/muency/medallion.html (and `doublespiralmedallion.html`, `triplespiralmedallion.html`)
- **MathWorld** — https://mathworld.wolfram.com/SeaHorseValley.html · https://mathworld.wolfram.com/ElephantValley.html
- **Paul Bourke** — https://paulbourke.net/fractals/mandelbrot/
- **ibiblio period-N bulb math** — https://www.ibiblio.org/e-notes/MSet/cperiod.htm
- **Wikibooks fractals** — https://en.wikibooks.org/wiki/Fractals/Iterations_in_the_complex_plane/Mandelbrot_set/centers
- **mathr.co.uk** — https://mathr.co.uk/web/m-location-analysis.html
- **Beyer zoom sequence file metadata** — https://commons.wikimedia.org/wiki/File:Mandel_zoom_00_mandelbrot_set.jpg through `Mandel_zoom_12_*.jpg`
- **Mandelmap** (paid POI poster) — https://mandelmap.com
