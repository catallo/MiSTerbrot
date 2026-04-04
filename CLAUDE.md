# MiSTerbrot

## Project Goal
Build a MiSTer FPGA core that renders Mandelbrot/Julia fractals in real-time on the Cyclone V (DE10-Nano).

## Target Hardware
- Terasic DE10-Nano (Cyclone V 5CSEBA6U23I7)
- ~50,000 ALMs, 553 M9K blocks, 2 PLLs
- SDRAM: 32MB (directly accessible via MiSTer framework)
- Video: VGA/HDMI via MiSTer framework

## Architecture

### Pixel Pipeline (parallel)
- 8 logical iterators via 4 DSP time-shared iter_pair modules
- Fixed-point arithmetic (8.56 format - 8 integer bits, 56 fractional, 64-bit total)
- ~17 decimal digits of precision, max zoom ~7.2 * 10^16x
- Each iterator: z = z^2 + c, check |z| > 4, max iterations configurable (128-1024)
- Truncated 64x64 multiply using 32-bit halves mapped to DSP blocks
- Each iter_pair shares 7 DSP multiplies between 2 contexts (~56 DSP blocks total)
- 10-bit iteration count for better detail at deep zoom

### Coordinate Generator
- Scans screen pixels left-to-right, top-to-bottom
- Maps pixel (x,y) to complex plane coordinates based on zoom/pan registers
- Distributes pixels round-robin to parallel iterators

### Color Mapping
- 10 palettes computed combinationally (Rainbow, Fire, Ocean, Grayscale, Smooth, Neon, Earth, Ice, Sunset, Electric)
- 4-bit palette selector, cycled via B/P/Space keys
- 10-bit iteration count mapped to 8-bit color index (wraps for banding)

### Framebuffer
- BRAM double-buffered: two 320x240 @ 11-bit banks (~184 M9K blocks total)
- Render pipeline writes to back buffer, display reads from front buffer
- Buffer swap ONLY during VBLANK rising edge = zero tearing
- 320x240 pixel-doubled 2x to 640x480 VGA output
- MiSTer scaler handles upscaling to display resolution

### Input (MiSTer framework handles controller/keyboard)
- D-Pad: Pan (X/Y movement)
- Shoulder buttons / triggers: Zoom in/out
- Face buttons: Switch fractal type, cycle palette, reset view
- Mouse input: TODO, not currently implemented
- OSD menu for settings (max iterations, palette, fractal type, resolution)
- Adjustable Julia parameter: TODO, not currently exposed via OSD/input

### MiSTerbrot Types
1. Mandelbrot: z(n+1) = z(n)^2 + c, where c = pixel coordinate
2. Julia Set: z(n+1) = z(n)^2 + c, where c = fixed built-in parameter
3. Burning Ship: TODO, documented target only and not currently implemented

## MiSTer Framework
- Use Template_MiSTer as base: https://github.com/MiSTer-devel/Template_MiSTer
- Clone it and adapt
- Quartus 17.0.2 (MiSTer standard)
- All cores use sys_top.v -> core module interface
- Framework provides: SDRAM controller, video output, audio, HPS interface, controller input
- OSD (On-Screen Display) for settings menu

## Build
- Quartus: Docker image ryanfb/quartus-mister (20GB). Build via: docker run --rm -v $(pwd):/build ryanfb/quartus-mister quartus_sh --flow compile /build/Fractal
- Install Verilator for simulation/testing: sudo apt install verilator
- Write testbenches for iterator, coordinate generator, color mapper

## File Structure
- rtl/ - All Verilog source files (fractal_top.v, iter_pair.v, mul_trunc64.v, mandelbrot_iterator.v, pixel_pipeline.v, coord_generator.v, color_mapper.v, input_handler.v, fractal_osd.v, auto_zoom.v, framebuffer.v, video_timing.v)
- sim/ - Testbenches and Verilator simulation (tb_iterator.v, tb_pipeline.v, Makefile)
- quartus/ - Quartus project files

## Design Constraints
- Fixed-point: 8.56 format (64-bit) for deep zoom (~17 decimal digits precision)
- Multipliers use DSP blocks via truncated 32-bit half decomposition (multstyle="dsp")
- Max iterations: configurable 128/256/512/1024 via OSD (10-bit)
- Clock: 50 MHz system clock from DE10-Nano, ce_pix divides by 2 for ~25 MHz pixel clock
- Resolution: 320x240 only (pixel-doubled to 640x480 VGA output)
- N_ITERATORS: 8 (4 iter_pair modules, DSP time-shared)

## Testing
- Write Verilator testbenches for each module
- Verify iterator produces correct iteration counts for known coordinates
- Test color mapper LUT output
- Simulate full pipeline with small frame

## Important
- This is Verilog, not SystemVerilog (MiSTer convention)
- Keep it synthesizable - no initial blocks in non-testbench code
- Use non-blocking assignments (<=) in always @(posedge clk) blocks
- Reset is active-low on MiSTer
