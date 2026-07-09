# 320×480i — Design Notes (revised)

Goal: interlaced 480-line output at the native 15.7 kHz line rate — the
CRT/SCART-friendly way to double VERTICAL detail without SDRAM.  BRAM-only.
640×480 (p or i) remains Track-B/DDR3 territory.

## The key insight: 320×480 IS a bank

One framebuffer bank holds 153,600 entries = 640×240 = **exactly 320×480**.
So 320×480i needs NO third bank and NO field-aware rendering:

- The render path draws a plain PROGRESSIVE 320×480 frame into the back
  bank (`py` runs 0..479; the address formula `y*320 + x` is unchanged —
  `wr_y` already carries 9 bits).
- Only the SCANOUT is field-aware: during field f, display row `r` reads
  logical row `2r + f` → `rd_addr = (2r+f)*320 + x`.
- Bank swap stays whole-frame (both fields come from the same render):
  **no interfield shimmer**, no pairing scheme needed.
- A2 real-axis symmetry keeps working (mirror row 479−y lives in the
  same bank; scan rows 0..239, mirror 240..479).
- The 9-bit pixel diet (stage 1) is kept: fewer/looser RAM blocks help
  placement, and Quartus configures a bank as 150× M10K(1024×10) either
  way — the earlier 3-bank plan (which the diet was sized for) is
  superseded by this layout.

Rejected alternative for the record: 640×480i via three 640×240 banks —
Quartus implements a 153,600×9 bank as 150 M10K blocks (1024×10 config),
so 3 banks + framework ≈ 580 > 553 blocks.  Does not fit; and the
field-sequenced render it required had inherent interfield shimmer.

## Stage 1 — framebuffer diet (13 → 9 bit)  [DONE, verified]

Display path only consumes `{escaped, iter[7:0]}`.  Zero behavioral
change (walkthrough bit-identical).

## Stage 2a — interlaced video timing

- Line rate stays 15.625 kHz.  525-line frame: field 0 = 262 lines,
  field 1 = 263 lines, vsync in field 1 offset by half a line
  (`hc == h_total/2`) — the classic CRT interlace trigger.
- `field` output + `VGA_F1` through emu (currently tied 0); the MiSTer
  framework detects interlace from F1 activity, ascal deinterlaces for
  HDMI.
- 240p paths must remain BIT-IDENTICAL when interlace is off (15 kHz
  hard requirement): interlace logic is a strict superset gated by
  `interlace_mode`, verified by a TB comparing sync waveforms
  cycle-by-cycle against the current timing with the mode off.
- 480i implies 320-wide (`mode_640` and interlace are mutually
  exclusive; OSD enforces it).

## Stage 2b — coord_generator vertical mode

Progressive 480-row scan over the SAME complex extent (240·step): row
pitch p = step/2.  `ci(Y) = center_y − 120·step + p/2 + Y·p`, Y = 0..479.
Implementation: `V_PIXELS` muxes 240/480 and the per-row increment muxes
`step`/`step>>>1` (mirroring what mode_640 already does horizontally);
the ci_start grid shift becomes `step>>>2` in 480 mode (half of the new
pitch — same "no row on ci=0" rationale).  A2 symmetry scan stops at row
239 (of 480) instead of 119; the mirror target formula in fractal_top
muxes 239−y / 479−y.

## Stage 2c — scanout + swap plumbing

- video read address: `(2*vid_pixel_y + field)*320 + x` in 480i mode.
- Overlay/text unchanged: text_overlay keys off vid_pixel_y (0..239 per
  field) and composites AFTER the framebuffer read — glyphs render in
  both fields at the same in-field position = vertically doubled, same
  as 240p today.  Telemetry strip likewise (rows 0..3 of both fields);
  benchmark mode forces 240p anyway (determinism + decoder geometry).
- Render cost: 480-row frame = 2× today's 320×240.  fps roughly halves
  vs 320×240p; A2/P1/P2 wins carry over.

## Stage 2d — OSD + emu plumbing, hardware bring-up

- Unified OSD Resolution selector `O[55:54]`: 320x240 / 640x240 /
  320x480i (single menu entry; the former O[22]+O[53] pair is retired).
  The J key cycles the three modes (sticky override).
- emu: `VGA_F1` = field when interlaced; `HDMI_BOB_DEINT` stays 0.
- Bring-up: scaler screenshots for structure; the CRT judges the
  half-line sync quality (analog territory).
- **Bring-up findings (2026-07-09):**
  - `new_vmode` (hps_io) must toggle on every resolution change, and the
    core must NEVER boot straight into 480i: the framework's first mode
    lock after core load fails on an interlaced signal.  Boot grace of
    ~60 vblanks in progressive, then switch to the saved setting.
  - Analog 31 kHz-only VGA monitors (user's IBM C170) cannot sync native
    15.7 kHz 480i; the PSX comparison worked because that setup runs
    `vga_scaler=1` (scaler output on the VGA port).  Same ini section
    added for MiSTerbrot; native 480i remains for 15 kHz displays.
  - **Native 15 kHz 480i is UNVERIFIED on real 15 kHz hardware** — no
    SCART TV / arcade monitor available locally.  Signal structure is
    TB-verified (classic 262/263 half-line scheme) and the ascal locks
    and weaves it correctly, but composite-sync quality and field
    pairing on a real tube await community feedback — the same policy
    PROJECT.md has always applied to 15 kHz 240p.  Flag in release
    notes when this ships.
  - Weave combing on motion is inherent to deinterlacing a zooming
    fractal; `O[58:57]` exposes Weave (default) / Bob / Off.  Off
    suppresses the F1 field flag so the framework scales each field
    as an independent progressive half-picture — no combing and no
    bob shimmer, at half the vertical detail.
  - Tooling: poi_walkthrough/poi_ocr assume 240p capture geometry —
    480i captures (320x480) silently match nothing.  Stage 3 item.

## Stage 3 — tooling

- `tools/poi_render.py`: V_OVERSAMPLE=2 mode (mirrors the existing
  H_OVERSAMPLE=2 for 640-wide) for 480i references.
- Walkthrough/scoring: scaler screenshots of 480i come back
  deinterlaced; verify geometry and adapt block indexing.

## Open questions (answer on the CRT)

1. Overlay glyphs vertically doubled (drawn identically in both
   fields) — fine, or should the overlay go field-aware for sharper
   text?
2. Weave vs bob deinterlace on the OLED (`HDMI_BOB_DEINT`)?
3. Is 320×480i's tall-pixel look (horizontal 320 vs vertical 480
   sampling) pleasing on the fractal content?  If yes, it becomes the
   attract-mode default recommendation; if not, it stays an option.
