# Benchmarking

Track A performance work is measured on real MiSTer hardware with deterministic
benchmark scenes. The goal is not a user-facing benchmark UI; the core exposes a
small machine-readable pixel strip that can be decoded from screenshots.

## Components

- `tools/benchmarks.json`: source of truth for benchmark scenes.
- `tools/bench_encode.py`: converts the JSON scene list into Verilog constants.
- `rtl/benchmark_generated.vh`: generated include consumed by `fractal_top.v`.
- `rtl/fractal_top.v`: benchmark scene mux, continuous render mode, 10-second
  frame counter, and pixel telemetry.
- `tools/bench_decode_screenshot.py`: decodes the telemetry strip from a
  captured PNG.
- `docs/PERF_BASELINE_TRACK_A.md`: table for baseline and comparison results.

## Scene Source

Edit `tools/benchmarks.json` when changing the benchmark suite. Each scene fixes
the center, zoom level, resolution, palette, and `max_iter` budget. Regenerate
the RTL include after any edit:

```bash
python3 tools/bench_encode.py
```

The generated file is `rtl/benchmark_generated.vh`; do not hand-edit it.
Quartus smart recompile does not reliably notice changed include files, so use a
clean build after changing benchmark data.

Interior stress scenes such as `02 CARDIOID` and `03 P2 BULB` may look mostly
or completely black. That is expected: they are designed to measure worst-case
non-escaping iteration cost, not visual detail.

## Build And Deploy

Build the core as usual:

```bash
quartus_sh --flow compile MiSTerbrot
```

Only deploy timing-clean builds. For the current benchmark setup, seed `2`
closed timing with `+0.093 ns` worst-case setup slack.

After copying the `.rbf` to the MiSTer, reload the running core:

```bash
tools/misterclaw-send --host 10.0.0.8 reload
```

## Controls

Benchmark controls are PS/2 keyboard events:

- `B`: toggle deterministic benchmark mode.
- `V`: advance to the next benchmark scene.

Benchmark mode forces the scene center, zoom step, resolution, palette, and
iteration budget from `tools/benchmarks.json`. It also continuously re-renders
the selected static scene, so throughput can be measured without timing
individual screenshots.

The normal text overlay is intentionally left alone. The `G`/`L` verification
overlay setup is not required for benchmark decoding, because the readout is in
pixels, not text.

## Pixel Telemetry

Benchmark mode encodes data into **32 tiny 4x4-pixel color blocks** at the top-left
of the final video output (128 px wide, 4 px tall — doubled to 8 px tall by the
MiSTer scaler on its way to HDMI):

| Bits  | Field        | Notes                                              |
|------:|--------------|----------------------------------------------------|
| 31:28 | magic `0xA`  | self-check; rejects non-bench captures             |
| 27    | `ms_enable`  | Mariani-Silver state (1 = on)                      |
| 26:25 | `mr_sel`     | Min Region: 00=16, 01=32, 10=64, 11=128            |
| 24:23 | spare        | reserved for future use                            |
| 22:16 | `scene_idx`  | 7 bits — 86-POI catalogue                          |
| 15:12 | `iter_tier`  | max-iteration tier (see table below)               |
| 11:0  | `F10`        | frames completed in the last 10-second window      |

Max-iteration tiers are:

| Tier | Max Iter |
|---:|---:|
| 0 | 128 |
| 1 | 256 |
| 2 | 512 |
| 3 | 1024 |
| 4 | 2048 |
| 5 | 4095 |

Each `1` bit is yellow (`#FFFF00`) and each `0` bit is blue (`#0000FF`).
`F10` is completed render frames in the last 10-second window. The 12-bit
field is technically large enough for 409.5 FPS, but render is **vsync-locked
at ~60 fps**, so F10 saturates at ~596 (60 × 9.93 effective seconds within the
window). Sustained FPS is:

```text
FPS = F10 / 10
```

> **F10 ceiling note.** An earlier build bypassed vsync in benchmark mode to
> measure raw compute throughput, but that broke the MiSTer HDMI scaler and the
> on-disk screenshot capture (both lock to the framebuffer's vsync edge). The
> bypass is **gone for good** — accept the 60 fps ceiling. In practice, almost
> every Track A POI is well below 60 fps anyway; the ones that aren't are
> trivially "fast" and don't need precise measurement.

The magic nibble makes screenshot decoding self-checking. If the decoded magic
is not `0xA`, the screenshot was probably taken with benchmark mode disabled,
from the wrong core, or with unexpected capture scaling/cropping.

### Visible block positions (counting from leftmost)

| Block(s) | Bit(s)  | Field        |
|---------:|---------|--------------|
| 0–3      | 31..28  | magic `0xA` (Y B Y B)      |
| 4        | 27      | MS state                   |
| 5–6      | 26..25  | MR selector                |
| 7–8      | 24..23  | spare                      |
| 9–15     | 22..16  | scene index                |
| 16–19    | 15..12  | iter tier                  |
| 20–31    | 11..0   | F10                        |

### Runtime keys (verification mode)

| Key | Effect                                 |
|-----|----------------------------------------|
| B   | Toggle benchmark mode                  |
| V   | Advance to next benchmark scene        |
| S   | Force Mariani-Silver ON  (overrides OSD)|
| A   | Force Mariani-Silver OFF (overrides OSD)|
| 1   | Force MIN_REGION_DIM = 16              |
| 2   | Force MIN_REGION_DIM = 32              |
| 3   | Force MIN_REGION_DIM = 64              |
| 4   | Force MIN_REGION_DIM = 128             |

S/A and 1/2/3/4 are sticky after first press (OSD value wins until you press
one). Per the verification-key convention, there is no "follow OSD again"
reset until core reload.

## Capture And Decode

Start benchmark mode, wait for one complete 10-second window, then capture a
screenshot:

```bash
tools/misterclaw-send --host 10.0.0.8 input type B
sleep 12
tools/misterclaw-send --host 10.0.0.8 screenshot --output /tmp/bench_00.png
python3 tools/bench_decode_screenshot.py /tmp/bench_00.png
```

Example decoder output:

```text
magic=0xA scene=0 ms=Off mr=16 iter_tier=3 f10=299 fps=29.9 bits=10100000000000000011000100101011
```

To capture the full suite, repeat this loop:

1. Let the current scene run until `F10` has updated at least once.
2. Decode the screenshot and record `F10`.
3. Press `V` to advance to the next scene.
4. Wait for the next 10-second window before decoding that scene.

Use `docs/PERF_BASELINE_TRACK_A.md` for the baseline table. After each Track A
optimization, rerun the same scene list and compare `F10` for sustained
throughput.
