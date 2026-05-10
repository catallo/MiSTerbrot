# MiSTerbrot

Version: `v0.11` (branch `pipeline-wide`, tip `e44f225`)

This file is the current project reference for the repository as it exists now.

## Project Goal

MiSTerbrot is a MiSTer FPGA core for real-time fractal rendering on the DE10-Nano. It renders Mandelbrot and Julia sets in hardware, supports manual exploration plus an auto-zoom screensaver, and presents a lightweight in-frame text overlay plus MiSTer OSD controls. Output resolution is runtime-selectable between native `320x240` and `640x240` (both 240p).

## Target Hardware

- MiSTer on Terasic DE10-Nano
- FPGA: Intel/Altera Cyclone V `5CSEBA6U23I7`
- Quartus target flow: `17.0.2 Lite` / standard MiSTer build environment
- Video path: native 240p core timing into the MiSTer framework, with MiSTer scaler/ascaler handling display upscaling
- Current fitted build resource usage from `output_files/MiSTerbrot.fit.summary`:
  - `25,568 / 41,910` ALMs (`61%`)
  - `31,827` registers
  - `3,310,088 / 5,662,720` block memory bits (`58%`)
  - `429 / 553` RAM blocks (`78%`)
  - `112 / 112` DSP blocks (`100%`)
  - `3 / 6` PLLs (`50%`)

## Current Architecture

### Clocking (dual-clock design)

- `clk_sys` = `50 MHz` — video timing, framebuffer, control logic, coord_generator, dispatch/collect FSMs.
- `clk_iter` = `100 MHz` (PLL outclk_1) — iterator math (`iter_quad` instances).
- CDC sits at the `iter_quad` boundary: per-slot `start` toggles into clk_iter via 3-FF synchronizer; `done` edges synchronized back into clk_sys. Slow-changing control buses (`max_iter`, `fractal_type`, `julia_*`, `cr`/`ci`) are sampled when synchronized strobes fire — `view_changed` triggers a frame restart that flushes any in-flight contexts on parameter change.
- Note: `MiSTerbrot.sdc` still labels `clk_iter` as 75 MHz in a comment; the actual PLL output is 100 MHz and timing closes there with marginal positive slack.

### Core video model

- `ce_pix` is generated from a 3-bit counter on `clk_sys`:
  - 320 mode: pulses every 8 sysclks → `6.25 MHz` dot clock, H_TOTAL=400.
  - 640 mode: pulses every 4 sysclks → `12.5 MHz` dot clock, H_TOTAL=800.
- Both modes hold a 15.625 kHz line rate, V_TOTAL=262 (V_ACTIVE=240, V_FP=10, V_SYNC=3, V_BP=9), ~59.7 Hz refresh.
- `rtl/video_timing.v` muxes the horizontal constants on `mode_640`. V_FP was widened from 3 to 10 lines as part of debugging the 640-mode display artifact (see Known Issues).
- Resolution is selected at runtime via OSD bit `status[22]` and threaded through the core as `mode_640`.

### Numeric format

- Fractal math is `64-bit` fixed-point, `8.56` format.
- Truncated `64×64` multiplies are decomposed into 32-bit halves; only the product window needed for `8.56` is kept (`rtl/mul_trunc64.v`, `rtl/iter_quad.v`).
- The built-in Julia parameter is hard-coded in `rtl/fractal_top.v`.

### Render pipeline

`input_handler -> coord_generator -> pixel_pipeline -> framebuffer -> color_mapper -> text_overlay`

Major blocks:

- `rtl/input_handler.v`
  - Manual pan/zoom/type/palette/iteration control from MiSTer joystick and PS/2 keyboard
  - Overlay toggle and color-cycle toggle
  - Auto-zoom enable/deactivate handoff
- `rtl/coord_generator.v`
  - Scans the frame in raster order and maps pixels into complex-plane coordinates from `center_x`, `center_y`, and `step`. Receives `mode_640` so the scan range matches the active resolution.
- `rtl/pixel_pipeline.v`
  - `20` logical iterators total (`N_ITERATORS=20`)
  - Implemented as `4` instances of `rtl/iter_quad.v`, each serving five alternating contexts (5-stage pipeline, 5 contexts per quad)
  - Dispatch and collect FSMs run in `clk_sys`; the iterator math runs in `clk_iter`. Round-robin dispatch fills idle slots; result valid pulses on clk_sys when a slot completes.
- `rtl/iter_quad.v`
  - Five Mandelbrot/Julia iterators sharing seven truncated `64×64` multiplies via 5-context DSP time-multiplexing
  - 5-stage pipeline: Stage 1 DSP partial products → Stage 2a1 lower-half adds → Stage 2a2 upper-half adds → Stage 2b1 mag_sq/escape/compares → Stage 2b2 final adds + state writeback
  - Mandelbrot interior precheck (main cardioid + period-2 bulb) reuses the multiplier pipeline; interior points return `iter_count=max_iter` immediately.
  - Supports up to `2048` iterations with a `12-bit` iteration count
  - ~14 DSP blocks per quad × 4 quads
- `rtl/iter_pair.v`
  - Older 2-context iterator engine. Still in the tree but not instantiated by the active pipeline.
- `rtl/framebuffer.v`
  - Double-buffered BRAM framebuffer
  - Per-pixel width is `13 bits`: `{escaped, iter_count[11:0]}`
  - `ADDR_WIDTH=18`; per-bank depth is `153,600` entries (`640×240`, sized for max resolution). In 320 mode only the lower half is used.
  - Swap occurs only on VBLANK rising edge to avoid tearing.
  - Single-buffer mode is selectable via OSD for live render visualization (flickers; not the default).
- `rtl/color_mapper.v`
  - Integer escape-count based mapping
  - Uses only `iter_count[7:0]` as the palette index, so colors wrap every `256` iterations
  - Color cycling (On/Off toggle) uses a `12-bit` phase accumulator for palette offset plus 4-bit adjacent-entry blending. Toggled via OSD, keyboard `C`, or joystick `B`.
  - `47` procedural palettes (indices `6'd0`..`6'd46`)
- `rtl/text_overlay.v`
  - Rendered directly in the video stream
  - Top-left: iterations, FPS, fractal type, palette
  - Top-right: zoom auto/manual status and color cycling status
  - Bottom-left: two-line target region with POI name (auto-zoom) and coordinates plus zoom line below
  - Bottom-right: build/date and GitHub text
  - Uses 5×5 monochrome font with 10px line height for readability at 240p
  - Coordinate digit computation is registered (synchronous pipeline stage) for timing closure
  - Uses `rtl/bcd_serial.v` (serial BCD converter) for coordinate formatting; replaced earlier LPM_divide-based dividers
- `rtl/bcd_serial.v`
  - Serial double-dabble BCD converter feeding the overlay coordinate readout
- `rtl/mul_trunc64.v`
  - Shared 64×64 truncated multiply primitive used by the iterator math

### Fractal modes

Currently working: Mandelbrot, Julia. Burning Ship is referenced in legacy comments but is not implemented as an active mode.

The Julia parameter is hard-coded in `rtl/fractal_top.v` and is not user-adjustable.

### Palette system

- `47` procedural palettes implemented combinationally in `rtl/color_mapper.v` (indices 0..46).
- Palette selection is `6-bit` across the active core and MiSTer menu interface.
- The OSD palette list in `MiSTerbrot.sv` exposes `Auto` plus 47 named palettes via `O[9:4]`.
- `rtl/auto_zoom.v` shuffles a palette playlist sized to match.

### Auto-zoom target system

- `25` POIs with individual zoom endpoints stored as `target_max_zoom_x10` (10-bit fixed point, value = zoom_level × 10).
- Comparison uses `zoom_level_x10 = zoom_exp * 10 + zoom_frac_tenth` for sub-integer precision.
- `skip_next` input allows jumping to next target mid-zoom (`N` key / `Y` button).
- Manual palette overrides clear automatically on POI transition (`sync_clear_palette_override` from `fractal_top.v`).

## File Structure

Top-level and build files:

- `MiSTerbrot.sv`: MiSTer `emu` wrapper and OSD menu string
- `MiSTerbrot.qpf`, `MiSTerbrot.qsf`, `MiSTerbrot.sdc`, `files.qip`: Quartus project files
- `pll.v`, `pll.qip`: PLL outputs (clk_sys, clk_iter)
- `build_id.v`: build date/version include
- `HANDOFF.md`: working notes for the `pipeline-wide` branch (current 640-mode bug status)

RTL:

- `rtl/fractal_top.v`: top-level core datapath and control integration
- `rtl/input_handler.v`: joystick/keyboard/manual state
- `rtl/coord_generator.v`: pixel-to-complex coordinate generation (mode-aware)
- `rtl/pixel_pipeline.v`: dual-clock dispatch/collect wrapper around `iter_quad` instances
- `rtl/iter_quad.v`: 5-stage / 5-context iterator engine (active design)
- `rtl/iter_pair.v`: older 2-context iterator engine (still in tree, not instantiated)
- `rtl/mandelbrot_iterator.v`: legacy standalone iterator (still in tree)
- `rtl/mul_trunc64.v`: truncated 64×64 multiply primitive
- `rtl/framebuffer.v`: double-buffered on-chip framebuffer (sized for 640×240)
- `rtl/color_mapper.v`: 47 procedural palettes and color cycling
- `rtl/video_timing.v`: native 240p timing generator (mode-aware)
- `rtl/text_overlay.v`: in-frame text overlay
- `rtl/bcd_serial.v`: serial BCD converter for overlay coordinates
- `rtl/auto_zoom.v`: screensaver / playlist-driven auto-zoom controller (25 POIs)
- `rtl/fractal_osd.v`: decodes MiSTer OSD status bits into core parameters

MiSTer framework support:

- `sys/`: MiSTer platform glue, video, PLLs, HPS I/O, scaler/scandoubler support

Simulation and testbenches:

- `sim/Makefile`, `sim/tb_*.cpp` — Verilator harnesses, version-stamped to older RTL (not current)

Build artifacts and release notes:

- `output_files/`: Quartus fit/timing reports and generated `.rbf`
- `releases/`: snapshot release images and notes

## OSD layout (`MiSTerbrot.sv`)

| Bits      | Setting                       |
|-----------|-------------------------------|
| `O[9:4]`  | Palette (Auto + 47 named)     |
| `O[10]`   | Color Cycling (On/Off)        |
| `O[14:12]`| Iterations (128/256/512/1024/2048) |
| `O[17:15]`| Scandoubler Fx                |
| `O[18]`   | Buffer (Double/Single)        |
| `O[19]`   | Blank Text                    |
| `O[20]`   | Always Show FPS               |
| `O[21]`   | Always Show POI/Palette       |
| `O[22]`   | Resolution (320×240 / 640×240)|
| `O[122:121]` | Aspect ratio               |

## Build Instructions

### Quartus build

```bash
quartus_sh --flow compile MiSTerbrot
```

Docker (MiSTer-standard Quartus 17.0; the image's default 19.1 is not used):

```bash
docker run --rm -v $(pwd):/build ryanfb/quartus-mister bash -c \
  "export PATH=/opt/intelFPGA_lite/17.0/quartus/bin:\$PATH && \
   export LD_LIBRARY_PATH=/opt/intelFPGA_lite/17.0/quartus/linux64:\$LD_LIBRARY_PATH && \
   quartus_sh --flow compile /build/MiSTerbrot"
```

A full compile is ~17 minutes.

### Deploy

- **RBF filename MUST include date:** `MiSTerbrot_YYYYMMDD.rbf` — MiSTer reads the date from the filename suffix, NOT from CONF_STR `V,v`. Without the date suffix, the core list shows `--.--.--.` instead of the build date.
- Latest in-tree builds: `MiSTerbrot_20260504.rbf`, `MiSTerbrot_20260505.rbf`.
- Set `status[22]=1` for 640 mode by writing the appropriate byte to `/media/fat/config/MiSTerbrot.CFG` before reload.

### Simulation

The Verilator harness under `sim/` is version-stamped to the older `iter_pair` / `mandelbrot_iterator` paths and is **not** current with the active `iter_quad` pipeline. Treat it as historical.

## Current Status

### What currently works

- MiSTer core wrapper and OSD integration
- Native 240p output at runtime-selectable `320×240` or `640×240`
- Mandelbrot rendering
- Julia rendering with fixed built-in parameter
- Manual pan and zoom from controller/keyboard
- Manual palette cycling (47 palettes)
- Configurable max iterations up to `2048`
- Auto-zoom screensaver with 25 shuffled POIs and shuffled palette playlist
- `N` key / `Y` joystick button = skip to next POI in auto-zoom playlist
- Double-buffered tear-free framebuffer swap on VBLANK edge (single-buffer mode optional)
- In-frame text overlay with current bottom-left coordinates and zoom display
- Color cycling toggle
- Dual-clock pipeline: clk_sys 50 MHz / clk_iter 100 MHz with CDC at the iter_quad boundary
- ~2× iteration throughput vs. the prior single-clock `iter_pair` design (≈200 → ≈400 Miter/s, same DSP count)

### Throughput / timing

- Build closes timing at `clk_iter = 100 MHz` with marginal positive slack (typically +0.013 to +0.07 ns; placement-variant). Works on real silicon at room temp.

## Known Issues

### OSD type bug

`rtl/fractal_osd.v` is still effectively a two-mode decoder and is commented as `v0.9.0`. The OSD/type/config documentation is stale relative to the rest of the core; type handling is not documented consistently across RTL, OSD strings, and historical notes.

### DSP saturation

Current fit uses `112 / 112` DSP blocks (`100%`). Any new DSP-based math is effectively blocked unless something else is removed or restructured.

### Latch / combinational-loop warnings

The fitted reports include latch-related warnings. `output_files/MiSTerbrot.fit.rpt` reports latch analysis; these need proper root-cause analysis and should not be normalized away as harmless noise.

### Stale simulation

`sim/Makefile` still builds around the older `iter_pair` / standalone `mandelbrot_iterator.v` path. Several simulation sources are explicitly version-stamped with older `v0.8` naming. Existing simulation is not a reliable regression suite for the current `iter_quad` render path.

### Missing / TODO

- Burning Ship mode is not implemented.
- Julia parameter is not user-adjustable.
- Simulation needs to be updated to the current `iter_quad` pipeline.

## Design Constraints

- Keep the design MiSTer-compatible and synthesizable under the Quartus 17.x flow.
- Native 240p timing (15.625 kHz line rate) at both `320×240` and `640×240`.
- Core math currently relies on `8.56` fixed-point and truncated multiply decomposition; changing this has wide impact.
- The active framebuffer is on-chip BRAM, sized for `640×240` × 13 bits per bank.
- Double buffering and VBLANK-only swap are core correctness constraints.
- Project headroom:
  - `100%` DSP usage (no headroom)
  - `78%` RAM blocks
  - `61%` ALMs
  - clk_iter at 100 MHz with marginal positive slack
- Any feature work that increases arithmetic width, palette logic depth, framebuffer width, or control complexity must be evaluated against those limits first.

## Practical Guidance

- Treat comments marked `v0.8` / `v0.9.0` as potentially stale until checked against the actual RTL.
- Treat `PROJECT.md` as the maintained truth source.
- For current branch state and the 640-mode debugging trail, see `HANDOFF.md`.
