# Gallery Mode — 1920×1080 indexed framebuffer (Design)

Status: IN IMPLEMENTATION (2026-07-11).  Stages 1-4 coded and
TB-verified (see Implementation notes at the end); silicon
verification pending.  Expands the ROADMAP entry.

Goal: a zoom-less full-HD mode.  The core renders each POI ONCE as
8-bit color indices into a DDR3 framebuffer; the framework scaler
(`FB_EN`) displays it natively at 1080p and applies a 256-entry
palette (`FB_PAL`) that the core rewrites every frame — so the entire
Color Cycling feature family keeps running at 60 Hz regardless of how
deep the POI is.  The menu core's wallpaper is the existence proof for
1080p framework-FB display.

## Index semantics — the simplification that makes it cheap

The FB index is the RAW `iter[7:0]`, interior is index 0:

    fb_index = escaped ? (iter[7:0] != 0 ? iter[7:0] : 8'd1) : 8'd0

- No mod-90 logic in the write path — the index is exactly what the
  BRAM/DDR3 framebuffers store today (minus the escaped bit, which
  folds into index 0).
- The palette writer evaluates all 256 iter values through the
  EXISTING color pipeline once per frame: entry 0 = black (interior),
  entry k = pipeline(iter=k, escaped=1).  Because `is_low_band` is
  `~iter[7]` and cidx derives from iter inside color_mapper, entry k
  reproduces the per-pixel math bit-exactly — including cycling phase,
  band mix, smooth/hard blend and palette crossfades, which all
  continue to update on vblank as today.
- The single collision (a pixel escaping at iter ≡ 0 mod 256 remaps to
  entry 1) shifts one color band on one iteration value — invisible.

## Palette writer — reuse, don't duplicate

No fourth palette evaluator (the ALM diet killed the fourth once
already).  In gallery mode the core-side video output is ignored by
the framework, so the display pipeline idles — the palette sequencer
hijacks it: during vblank it injects iter=k, escaped=1 for k=1..255
through the existing fb pixel mux (a third input next to BRAM/DDR3),
captures the pipelined `color_r/g/b` outputs at the matching ticks,
and streams them to `FB_PAL_ADDR/DOUT/WR`.  256 entries per frame at
the ce cadence ≈ 1-2 scanlines' worth of time — vblank is plenty.

## Framing / coordinate ladder

16:9 full-bleed with the SAME vertical complex extent as the 4:3
driving modes (240·step over 1080 rows):

    pitch p = step × 2/9   (both axes, square pixels)
    width covered = 1920·p ≈ 426.7·step — one-third more world than
    4:3 at the same POI zoom, for free

2/9 is a non-terminating binary fraction, so p comes from a per-frame
64-cycle serial multiply with a rounded 2^-56-scaled constant (the
auto_zoom serial-compute pattern; sub-LSB exact).  Fallback if the
serial multiply misbehaves: p = step>>>2 (shift-only, view 12.5%
taller / 50% wider than canonical framing).

A2 symmetry applies unchanged (mirror row 1079−y, same bank).
Renders reuse the coord_generator with a mode_1080 row/col count.

## Memory map

Above the Track B banks: index buffer A at 0x3020_0000, B at
0x3060_0000 (1920×1080 px, 2048-byte stride = 2,211,840 B each — the
banks need 4 MiB spacing; the first cut spaced them 2 MiB and rows
1024+ of A aliased into B, caught by the flip TB).  Writes: the fb_ddr3 write-FIFO pattern with
single-BYTE enables (the probe measured 48.2 M scattered writes/s; a
full frame is ~43 ms of write traffic, once per POI).  No core-side
read path at all — ascal does the scanout.

## Live-render toggle (user spec: DEFAULT ON)

- **On** (default): indices write into the DISPLAYED buffer — the POI
  paints progressively on screen, old image overdrawn as the new one
  arrives (the classic fractal-program look).
- **Off**: render into the hidden buffer; on completion fade the
  palette to black (~30 frames, a scale factor in the palette
  writer), flip `FB_BASE`, fade back in.
OSD bit `O[59]` ("Gallery Live Render", On/Off, default On = 0).

## POI sequencing

Attract dwell logic drives POI advance unchanged ("Wait on POI" = the
per-image display time); the shuffle playlist, per-POI max_iter and
palette assignments all apply.  Zoom in/out, pacing and speed are
inert; N key still skips to the next POI, M snaps.

## OSD / UX (user spec)

- Resolution `O[56:54]` value 5 = "1920x1080" — selecting it IS
  gallery activation.  J cycles six modes.  Boot grace as usual
  (progressive 640×240 first).
- Zoom-related rows (Attract Zoom In/Out, Zoom Pacing, Zoom Speed)
  grey out via CONF_STR `D<n>` prefixes + `status_menumask` (a
  "gallery active" bit; menumask is currently tied to 0).
- Scaler-only output in this mode (no native analog).
- Overlay text is NOT composited (core video is ignored); baking the
  POI name into the framebuffer after render is stage-2 polish.

## Resource budget

~1000-1400 ALMs (index write engine ~250, FB register glue ~50,
palette sequencer + pixel-mux injection ~350, framework
MISTER_FB+MISTER_FB_PALETTE side ~500 + 1-2 M10K for the palette
RAM).  Zero new DSPs.  Expected landing ~87-88% — if the fitter
starts refusing, the escape hatch is a build define excluding the
benchmark engine (scene tables + measurement, est. 1-2k ALMs) from
release builds.

## Verification plan

- TB with an FB-port model: FB_EN/BASE/STRIDE/FORMAT values, index
  write addresses cover 1920×1080 with the right stride, index values
  match a reference iter->index mapping, palette write sequence
  delivers 256 entries per frame whose RGB equals a golden
  color_mapper run at the same cycling state.
- Hardware: gallery screenshots ARE the palette-applied framebuffer —
  for the first time the capture can be compared pixel-exactly
  against a 1080p Python reference render (strongest verification the
  project has had).  Walkthrough tooling gains a gallery leg later.

## Stages

1. **FB plumbing first**: enable the defines, drive FB_EN with a
   static test pattern + a static palette; prove 1080p display and
   FB_PAL writes on silicon before anything else.
2. Index write path + coordinate ladder: real fractal renders, live
   build-up visible (toggle On path).
3. Palette sequencer through the color pipeline: cycling, band mix,
   crossfades; then POI transitions (fade-flip for toggle Off) and
   dwell sequencing.
4. OSD integration: resolution value 5, D-mask greying, O[59] toggle,
   boot grace, new_vmode.
5. Verification (TB + hardware pixel-exact) and docs.
6. Polish: baked POI-name text, gallery walkthrough tooling.

## Risks

- Framework FB handshake details (`FB_VBL`, `FB_LL`, format bits) are
  undocumented-ish — read sys_top's consumer code before wiring;
  stage 1 exists precisely to de-risk this on silicon early.
- Fitting at ~87-88% (mitigation above).
- FB_BASE flips vs scaler frame boundaries (tearing on flip) — flip
  during FB_VBL; stage 3 verifies.

## Implementation notes (as built, 2026-07-11)

Deviations and decisions made during implementation:

- **A2 masked off in gallery v1** (`cy_is_zero && !gallery_mode`):
  renders happen once per POI, so the 2x speedup buys little, and the
  mirror path stays out of the index stream (one fewer verification
  axis).  coord_generator carries the defensive `v_last_sym = 539`
  for a possible v2.
- **Activation clear**: on gallery entry, gallery_ctl sweeps index 0
  through both banks (~86 ms) before the first render — the first
  visible frame is black, never stale DDR3 noise.  `clear_done`
  forces a re-render because the write mux drops render writes that
  race the clear.
- **Pitch publish latency**: gallery_pitch free-runs (64-cycle pass);
  the published pitch can lag a step change by up to ~128 clk.  A
  frame started inside that window renders with a one-az-tick-stale
  pitch — sub-0.2 % extent error, transient, invisible; zoom is inert
  in gallery anyway.
- **Palette capture alignment**: with the restaged color_mapper ring,
  the index loaded into the injection register at tick edge N has its
  color on `color_r/g/b` at every tick edge >= N+3 — the sequencer
  tags captures with a 2-stage pre-edge delay line (`cap_d2`).
  Verified bit-exact against an independent golden color_mapper
  (8-tick-hold evaluation, latency-independent) over multiple frames
  with cycling advancing.
- **Sweep trigger = core vblank_rise**: same edge the cycling phase
  steps, so each sweep samples a coherent phase.  ascal's scanout is
  asynchronous to the core vblank, so a scanout frame can mix entries
  from two consecutive sweeps — adjacent cycling phases, invisible.
  (FB_VBL-synced writes remain an option if it ever shows.)
- **Fade-flip (O[59]=Off)**: fade 3/vblank (63 -> 0 in ~0.35 s), flip
  FB_BASE only at fade 0 — the screen is uniformly black, so the flip
  is tear-free by construction, no FB_VBL handshake needed.
- **Dwell gating**: auto_zoom got a `dwell_gate` input; in gallery,
  "Wait on POI" counts only while the render FSM is idle, the index
  FIFO drained, and the fade settled at 63 — pure display time.
- **Zoom inertness**: gallery masks `attract_zoom_in/out_enable` at
  the auto_zoom instance; the existing snap-dwell-advance path then
  sequences POIs with no zoom animation at all.
- **Palette changes don't re-render in gallery**: indices are
  palette-independent; the crossfade plays out entirely in the
  palette sweeps.
- **settings_changed** also fires on render_480/gallery_mode
  transitions (640x240<->480p<->gallery kept the legacy flags
  constant — a static view would not have re-rendered).
- **Analog output**: blanked (black, live syncs) in gallery mode —
  the core video carries the injection sweep, which would otherwise
  show as noise on the CRT.  Scaler-only, per design.
- **OSD**: `O[59]` "Gallery Live Render" On/Off (default On), `d0`
  (greyed outside gallery); zoom rows `D0` (greyed in gallery);
  `status_menumask[0]` = resolution selection == 1920x1080.

## OPEN: output video mode for the FB display (user decision)

The framework FB is displayed by ascal's output reader, which expects
FB size == output resolution (menu-core convention).  The user's ini
has no fixed `video_mode` — the scaler follows the core timing, so the
1080p FB cannot display correctly out of the box.  Complication: the
`[MiSTerbrot]` ini section sets `vga_scaler=1`, i.e. the CRT is on the
SCALER output too — pinning `video_mode=8` (1080p60) would retime the
CRT to 67.5 kHz in ALL modes.  Options to discuss:
  (a) `[MiSTerbrot] video_mode=8` if the CRT syncs 1080p (or move the
      CRT to direct video),
  (b) an alt-ini profile for gallery sessions,
  (c) accept OLED-only gallery with a manual vmode switch.
Until decided, gallery on the current ini shows the FB reader's
attempt at a 1920x1080 buffer inside a ~640x480 output — garbage
expected on screen; the DDR3 content itself is verified good.

Also note: MiSTer screenshots read ascal's triple buffer (core video,
pre-FB-reader, pre-OSD) — they can NEVER show FB content.  Hardware
verification of the index buffer runs over HPS `devmem` sampling
instead (tools/gallery_verify.py).
