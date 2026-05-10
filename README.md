# MiSTerbrot

**Mandelbrot Eye Candy for MiSTer FPGA in 240p**

Real-time Mandelbrot fractal core for MiSTer FPGA. Runtime-selectable 320×240 / 640×240 native 240p output, 20 parallel hardware iterators on a dual-clock pipeline (50 MHz / 100 MHz), 47 palettes, attract-mode zoom through 67 cross-validated canonical Mandelbrot POIs (Seahorse, Elephant, Triple Spiral, Misiurewicz, Feigenbaum, period-N bulbs and minibrots, embedded Julia sets) with color cycling.

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
3. Launch from the MiSTer menu under Other

## Controls

Keyboard and joystick. Press F12 in the core for help.

## Architecture

The core uses a parallel pixel pipeline with 20 logical iterators, implemented as 4 `iter_quad` modules that 5-context-time-share their DSP multipliers across two clock domains (50 MHz `clk_sys` / 100 MHz `clk_iter`, with toggle synchronizers at the iter_quad CDC boundary). Every iterator runs 64-bit fixed-point arithmetic in 8.56 format (8 integer bits, 56 fractional), giving ~17 decimal digits of precision and a theoretical max zoom of around 7.2 × 10¹⁶×.

The complex multiply z² uses a truncated 64×64 approach — split into 32-bit halves and mapped to DSP blocks via `multstyle="dsp"`. Each `iter_quad` uses 7 physical DSP multiplies shared between 5 pixel contexts.

Pixels are dispatched round-robin from a coordinate generator (scanning left-to-right, top-to-bottom) to whichever iterator slot is free. Results are collected in order and written to a BRAM double-framebuffer sized for 640×240 (used for both modes). Buffer swaps happen only on the VBLANK rising edge — zero tearing.

Output is native 240p @ ~59.7 Hz (15.6 kHz line rate), 320×240 or 640×240 selectable at runtime via the OSD. The MiSTer framework handles upscaling for HDMI output.

## Resource Utilization (Cyclone V, DE10-Nano)

- ALMs: 61% (25,568 of 41,910)
- DSP blocks: 100% (fully saturated by the fixed-point multipliers)
- Block RAM (M9K): 78% (429 of 553 blocks — framebuffer sized for 640×240 + color LUTs)
- PLLs: 50% (3 of 6)
- Closes timing at clk_iter = 100 MHz.

Frame rate is highly scene-dependent — it ranges from ~4 fps in deeply zoomed, high-iteration areas up to ~60 fps in simple regions near the escape boundary. The bottleneck is purely computational: every pixel must iterate z = z² + c until either |z| > 2 or the iteration limit (up to 2048) is hit.
