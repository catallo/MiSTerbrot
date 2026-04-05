# MiSTerbrot

**Mandelbrot Eye Candy for MiSTer FPGA in 240p**

Real-time Mandelbrot fractal core for MiSTer FPGA. Native 320×240, 8 parallel hardware iterators, 47 palettes, attract mode zooming to 25 Points of Interest with color cycling.

A spiritual successor to digital eye candy from the 90s.

## Screenshots

![Starfish Ice](screenshots/starfish_ice.png)
![Elephant Funhaus](screenshots/elephant_funhaus.png)
![Dendrite THC](screenshots/dendrite_thc.png)
![Double Spiral Synthwave](screenshots/spiral_synthwave.png)
![Needle Neon](screenshots/needle_neon.png)
![Dendrite THC Green](screenshots/dendrite_thc_green.png)
![Dendrite Skittles Blue](screenshots/dendrite_skittles_blue.png)

## Install

1. Download [`MiSTerbrot_20260404.rbf`](https://github.com/catallo/MiSTerbrot/releases/latest) from the latest release
2. Copy to `/media/fat/_Other/` on your MiSTer SD card
3. Launch from the MiSTer menu under _Other

## Controls

Keyboard and joystick. Press F12 in the core for help.

## Architecture

The core uses a parallel pixel pipeline with 8 logical iterators, implemented as 4 `iter_pair` modules that time-share their DSP multipliers between two contexts each. Every iterator runs 64-bit fixed-point arithmetic in 8.56 format (8 integer bits, 56 fractional), giving ~17 decimal digits of precision and a theoretical max zoom of around 7.2 × 10¹⁶×.

The complex multiply z² uses a truncated 64×64 approach — split into 32-bit halves and mapped to DSP blocks via `multstyle="dsp"`. Each `iter_pair` uses 7 physical DSP multiplies shared between 2 pixel contexts, totalling ~56 DSP blocks.

Pixels are dispatched round-robin from a coordinate generator (scanning left-to-right, top-to-bottom) to whichever iterator is free. Results are collected in order and written to a BRAM double-framebuffer (320×240, 245 M9K blocks total). Buffer swaps happen only on the VBLANK rising edge — zero tearing.

Output is native 320×240 @ ~59.7 Hz (240p, 15kHz). The MiSTer framework handles upscaling for HDMI output.

## Resource Utilization (Cyclone V, DE10-Nano)

- ALMs: ~46%
- DSP blocks: 100% (fully saturated by the fixed-point multipliers)
- Block RAM (M9K): ~44% (245 of 553 blocks — framebuffer + color LUTs)
- PLLs: 50% (3 of 6)

Frame Rate Frame rate is highly scene-dependent — it ranges from ~4 fps in deeply zoomed, high-iteration areas up to ~60 fps in simple regions near the escape boundary. The bottleneck is purely computational: every pixel must iterate z = z² + c until either |z| > 2 or the iteration limit (up to 2048) is hit.
