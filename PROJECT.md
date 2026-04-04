# MiSTerbrot

Version: `v0.11.0-dev`

This file is the current project reference for the repository as it exists now. It supersedes `CLAUDE.md`, which is historically useful but no longer accurate in several important areas.

## Project Goal

MiSTerbrot is a MiSTer FPGA core for real-time fractal rendering on the DE10-Nano. The current codebase targets native 320x240 progressive output, renders Mandelbrot and Julia sets in hardware, supports manual exploration plus an auto-zoom screensaver, and presents a lightweight in-frame text overlay plus MiSTer OSD controls.

## Target Hardware

- MiSTer on Terasic DE10-Nano
- FPGA: Intel/Altera Cyclone V `5CSEBA6U23I7`
- Quartus target flow: `17.0.2 Lite` / standard MiSTer build environment
- Video path: native 240p core timing into the MiSTer framework, with MiSTer scaler/ascaler handling display upscaling
- Current fitted build resource usage from `output_files/MiSTerbrot.fit.summary`:
  - `19,101 / 41,910` ALMs (`46%`)
  - `20,815` registers
  - `1,850,693 / 5,662,720` block memory bits (`33%`)
  - `245 / 553` RAM blocks (`44%`)
  - `112 / 112` DSP blocks (`100%`)
  - `3 / 6` PLLs (`50%`)

## Current Architecture

### Core video model

- System clock is `50 MHz`.
- Pixel enable `ce_pix` pulses once every 8 system clocks, so the core render/display timing runs at an effective `6.25 MHz` pixel rate.
- `rtl/video_timing.v` generates native `320x240 @ ~59.7 Hz` timing with:
  - Horizontal total `400`
  - Vertical total `262`
  - 15 kHz-class native 240p scan timing

### Numeric format

- Fractal math is `64-bit` fixed-point, `8.56` format.
- This is the actual current precision model used by the iterators and top-level parameters.
- The built-in Julia parameter is hard-coded in `rtl/fractal_top.v`.

### Render pipeline

The active pipeline is:

`input_handler -> coord_generator -> pixel_pipeline -> framebuffer -> color_mapper -> text_overlay`

Major blocks:

- `rtl/input_handler.v`
  - Manual pan/zoom/type/palette/iteration control from MiSTer joystick and PS/2 keyboard
  - Overlay toggle and color-cycle toggle
  - Auto-zoom enable/deactivate handoff
- `rtl/coord_generator.v`
  - Scans the frame in raster order and maps pixels into complex-plane coordinates from `center_x`, `center_y`, and `step`
- `rtl/pixel_pipeline.v`
  - `8` logical iterators total
  - Implemented as `4` instances of `rtl/iter_pair.v`, each serving two alternating contexts
- `rtl/iter_pair.v`
  - Time-multiplexes truncated `64x64` multiplies across two iterator contexts
  - Uses DSP-sharing by splitting operands into 32-bit halves and only keeping the product window needed for `8.56`
  - Includes Mandelbrot interior prechecks for the main cardioid and period-2 bulb
  - Supports up to `2048` iterations with a `12-bit` iteration count
- `rtl/framebuffer.v`
  - Double-buffered BRAM framebuffer
  - Current actual width is `13 bits/pixel`: `{escaped, iter_count[11:0]}`
  - Two `320x240` banks, one front/read and one back/write
  - Swap occurs only on VBLANK rising edge to avoid tearing
- `rtl/color_mapper.v`
  - Current actual mapping is still integer escape-count based
  - Uses only `iter_count[7:0]` as the palette index, so colors wrap every `256` iterations
  - Color cycling (On/Off toggle, no Auto mode) uses a `12-bit` phase accumulator for palette offset plus 4-bit adjacent-entry blending. Toggled via OSD, keyboard C, or joystick B button.
- `rtl/text_overlay.v`
  - Current overlay is rendered directly in the video stream
  - Top-left: iterations, FPS, fractal type, palette
  - Top-right: zoom auto/manual status and color cycling status
  - Bottom-left: two-line target region with POI name when auto-zoom is active, and coordinates plus zoom line below it
  - Bottom-right: build/date and GitHub text
  - **Recent changes (v0.10.0):**
    - Added `clk` input for registered coordinate formatting
    - Changed coordinate digit computation from combinational to registered (synchronous pipeline stage)
    - Fixes right-margin alignment for HELP and GITHUB text regions (HELP_X: 231, GITHUB_X: 221)
    - Uses 5x5 monochrome font with 10px line height for readability at 240p

### Fractal modes

Current working modes:

- Mandelbrot
- Julia

Not currently implemented as a working mode in the RTL:

- Burning Ship

There are places in comments and older docs that imply a larger type roadmap. The actual current interactive implementation is Mandelbrot + Julia only.

### Palette system

- The project currently has `47` procedural palettes, implemented combinationally in `rtl/color_mapper.v`.
- Palette selection is `6-bit` across the active core and MiSTer menu interface.
- `rtl/auto_zoom.v` also assumes `42` palettes and shuffles a palette playlist of that size.
- This is one of the major areas where `CLAUDE.md` is stale.

## File Structure

Top-level and build files:

- `MiSTerbrot.sv`: MiSTer `emu` wrapper and OSD menu string
- `MiSTerbrot.qpf`, `MiSTerbrot.qsf`, `MiSTerbrot.sdc`, `files.qip`: Quartus project files
- `build_id.v`: build date/version include

RTL:

- `rtl/fractal_top.v`: top-level core datapath and control integration
- `rtl/input_handler.v`: joystick/keyboard/manual state
- `rtl/coord_generator.v`: pixel-to-complex coordinate generation
- `rtl/pixel_pipeline.v`: dispatch/collect wrapper around iterators
- `rtl/iter_pair.v`: shared-DSP dual-context iterator engine
- `rtl/mandelbrot_iterator.v`: older standalone iterator path, still present
- `rtl/framebuffer.v`: double-buffered on-chip framebuffer
  - Supports Double (default, tear-free) and Single (live render view) buffer modes via OSD toggle
- `rtl/color_mapper.v`: procedural palette mapping and color cycling
- `rtl/video_timing.v`: native 240p timing generator
- `rtl/text_overlay.v`: in-frame text overlay with registered coordinate path
- `rtl/auto_zoom.v`: screensaver / playlist-driven auto-zoom controller
- `rtl/fractal_osd.v`: decodes MiSTer OSD status bits into core parameters

MiSTer framework support:

- `sys/`: MiSTer platform glue, video, PLLs, HPS I/O, scaler/scandoubler support

Simulation and testbenches:

- `sim/Makefile`
- `sim/tb_iterator.cpp`
- `sim/tb_pipeline.cpp`
- `sim/tb_iterator_v08.cpp`
- `sim/tb_pipeline_v08.cpp`
- `sim/tb_iter_pair_v08.cpp`

Build artifacts and release notes:

- `output_files/`: Quartus fit/timing reports and generated files
- `releases/v0.10.0.md`: release note snapshot for the current named release

## Build Instructions

### Quartus build

From the repo root, the standard compile entry point is:

```bash
quartus_sh --flow compile MiSTerbrot
```

This uses the project rooted at `MiSTerbrot.qpf` / `MiSTerbrot.qsf`.

If building with the `ryanfb/quartus-mister` Docker image, do not rely on the container's default Quartus environment. That image exposes Quartus `19.1` on the default `PATH`, but this project targets the MiSTer-standard Quartus `17.0` flow. The working Docker invocation explicitly prepends the Quartus 17.0 binaries and shared libraries:

```bash
docker run --rm -v $(pwd):/build ryanfb/quartus-mister bash -c "export PATH=/opt/intelFPGA_lite/17.0/quartus/bin:\$PATH && export LD_LIBRARY_PATH=/opt/intelFPGA_lite/17.0/quartus/linux64:\$LD_LIBRARY_PATH && quartus_sh --flow compile /build/MiSTerbrot"
```

The repository also contains prior build outputs under `output_files/`, so current resource and timing numbers can be inspected without rebuilding.

### Deploy

- **RBF filename MUST include date:** `MiSTerbrot_YYYYMMDD.rbf` — MiSTer reads the date from the filename suffix, NOT from CONF_STR `V,v`. Without the date suffix, the core list shows `--.--.--.` instead of the build date.
- Build produces an `.rbf` via the normal MiSTer/Quartus flow.
- A prior release artifact exists at [`releases/Fractal_20260326.rbf`](/home/sco/projects/mister-fractal/releases/Fractal_20260326.rbf), but it should be treated as a historical release image, not proof that the current working tree has been revalidated.

### Simulation

There is a Verilator harness under `sim/`, but it is not current with the active RTL and should not be treated as authoritative without repair.

## Current Status

### What currently works

- MiSTer core wrapper and OSD integration
- Native 320x240 progressive render path
- Mandelbrot rendering
- Julia rendering with fixed built-in parameter
- Manual pan and zoom from controller/keyboard
- Manual palette cycling
- Configurable max iterations up to `2048`
- Auto-zoom screensaver with shuffled target and palette playlists
- N key / Y joystick button = skip to next POI in auto-zoom playlist
- Double-buffered tear-free framebuffer swap on VBLANK edge
- In-frame text overlay with current bottom-left coordinates and zoom display
- `47` procedural palettes and optional palette cycling
- **Timing closure achieved** (setup slack: +0.386 ns, all paths positive)

### What is present but not fully closed out

- Auto-zoom, OSD, manual palette selection, and overlay behavior all work as a combined system, but several control-path semantics have drifted and need cleanup
- Comments and release notes are partially out of sync with the actual RTL
- The repository still carries older iterator/simulation paths that are no longer the best description of the active design
- Coordinate formatting now registered in text_overlay.v; pipeline latency increased by 1 cycle but timing now clean

### Auto-zoom target system

- 25 POIs with individual zoom endpoints stored as `target_max_zoom_x10` (10-bit fixed point, value = zoom_level × 10)
- Example: `10'd156` = zoom level 15.6, `10'd93` = zoom level 9.3
- Comparison uses `zoom_level_x10 = zoom_exp * 10 + zoom_frac_tenth` for sub-integer precision
- `skip_next` input allows jumping to next target mid-zoom (N key / Y button)

**Wiring lesson learned:** When adding a new port to a module, you must wire it in **both** the module declaration AND the instantiation in the parent. The `skip_next` port was added to `auto_zoom.v` but initially not wired in `fractal_top.v`'s `u_auto_zoom` instantiation — and also accidentally inserted into the wrong instantiation (`u_osd` instead of `u_input`). Always verify port wiring in the parent module after adding ports.

### Missing / TODO

- Burning Ship mode is not implemented
- Julia parameter is not user-adjustable
- Simulation needs to be updated to the current iterator/pipeline design
- OSD semantics and palette/type mappings need to be made consistent across `MiSTerbrot.sv`, `rtl/fractal_osd.v`, `rtl/input_handler.v`, `rtl/auto_zoom.v`, and `rtl/color_mapper.v`

## Known Issues

These are current project-level issues that should be treated as active engineering debt.

### OSD type bug

- `rtl/fractal_osd.v` is still effectively a two-mode decoder and is commented as `v0.9.0`.
- The OSD/type/config documentation is stale relative to the rest of the core.
- Type handling is not documented consistently across RTL, OSD strings, and historical notes.

### Palette mapping drift

- Palette count and semantics have drifted across the codebase:
  - `MiSTerbrot.sv` exposes a long theme list
  - `rtl/color_mapper.v` implements `47` palettes
  - `rtl/auto_zoom.v` shuffles `47` palettes
  - `rtl/fractal_osd.v` comment still says `1-32` fixed themes
  - `releases/v0.10.0.md` still describes `0=Auto, 1..31=fixed palette selection`
- This is not just doc drift; it increases the risk of off-by-one and override mismatches in UI behavior.

### Sticky override behavior — FIXED

- `rtl/input_handler.v` asserts `palette_override_active` when the user cycles palettes manually.
- The override is now automatically cleared when auto-zoom transitions to the next target (via `sync_clear_palette_override` signal from `fractal_top.v`).
- Manual palette choice persists during current POI, then reverts to playlist on next POI.

### DSP saturation

- Current fit uses `112 / 112` DSP blocks (`100%`).
- `rtl/iter_pair.v` comments describe the fractal math itself as roughly `~56 DSP blocks` across four `iter_pair` instances, but the fitted full design has no DSP headroom left.
- Any new DSP-based math is effectively blocked unless something else is removed or restructured.

### Latch / combinational-loop warnings

- The fitted reports include latch-related warnings.
- `output_files/MiSTerbrot.fit.rpt` reports latch analysis; these need proper root-cause analysis; they should not be normalized away as harmless noise.

### Stale simulation

- `sim/Makefile` still builds around older assumptions, including the standalone `mandelbrot_iterator.v` path.
- Several simulation sources are explicitly version-stamped with older `v0.8` naming.
- Existing simulation is not a reliable regression suite for the current active render path.

## Design Constraints

- Keep the design MiSTer-compatible and synthesizable under Quartus 17.x flow.
- Preserve native `320x240` render resolution and 240p timing unless there is a deliberate architectural redesign.
- Core math currently relies on `8.56` fixed-point and truncated multiply decomposition; changing this has wide impact.
- The active framebuffer is on-chip BRAM, not SDRAM.
- Double buffering and VBLANK-only swap are core correctness constraints.
- The project is already at:
  - `100%` DSP usage
  - non-trivial BRAM usage
  - **positive timing slack** (timing closure achieved)
- Any feature work that increases arithmetic width, palette logic depth, framebuffer width, or control complexity must be evaluated against those limits first.

## Practical Guidance

- Treat comments marked `v0.8` / `v0.9.0` as potentially stale until checked against the actual RTL.
- Treat `PROJECT.md` as the maintained truth source.
- Treat `CLAUDE.md` as historical context only.
