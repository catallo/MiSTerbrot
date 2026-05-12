# MiSTerbrot Palette System

How the 90 colour palettes are generated, selected, cycled, and named. All palettes are computed combinationally — no ROM, no LUT, no off-chip storage. The recipes live entirely in `rtl/color_mapper.v` as arithmetic expressions on the 8-bit iteration index.

Palette selection is `PAL_BITS = 7` (indices `7'd0`..`7'd89`). The OSD selector lives at `O[10:4]` in `MiSTerbrot.sv`'s CONF_STR.

## 1. Signal flow

```
iter_count[11:0] ──┐
escaped ───────────┤
                   ├──► color_mapper ──► (R, G, B) 24-bit
palette_sel[5:0] ──┤
cycle_enable ──────┘
```

Per-pixel inputs land on `clk_sys`. Inside-set pixels (`escaped = 0`) are forced to `(0,0,0)` — black is always "the set". Only the lower 8 bits of `iter_count` reach the palette logic (`iter_count[7:0]`), so colours wrap every 256 iterations regardless of the active `max_iter`.

## 2. Index computation

`rtl/color_mapper.v:30-38`:

```verilog
wire [7:0] cycle_idx_offset = cycle_enable ? cycle_phase[11:4] : 8'd0;
wire [3:0] cycle_frac       = cycle_enable ? cycle_phase[3:0]  : 4'd0;

wire [7:0] base_cidx = iter_count[7:0] + cycle_idx_offset;
wire [7:0] next_cidx = base_cidx + 8'd1;
```

| Quantity | Bits | Purpose |
|---|---|---|
| `base_cidx` | 8 | Index into the active palette recipe (with optional cycling offset added) |
| `next_cidx` | 8 | Adjacent entry, used to blend smoothly between palette steps |
| `cycle_frac` | 4 | Blend weight, 0/16 → all A, 16/16 → all B |

When color cycling is off, `cycle_idx_offset = 0` and `cycle_frac = 0`, so `base_cidx = iter_count[7:0]` and the blend collapses to A only.

## 3. Recipe styles

Three patterns appear in the 47 cases of the `palette_rgb` task (`rtl/color_mapper.v:68-1408`):

### a) HSV hue rotation

Used by **Rainbow** (`6'd0`). Multiplies `idx` by 6, treats the top 3 bits as a hue segment (R → Y → G → C → B → M → R) and the low 7 bits as the position within the segment:

```verilog
phase10_t = idx * 6;          // implemented as additions, no multiplier
seg_t = phase10_t[9:7];        // 0..5 segment
frac7_t = phase10_t[6:0];      // ramp position within segment
rise_t = {frac7_t, 1'b0};      // 0..254 ascending
fall_t = 255 - rise_t;         // 254..0 descending
```

### b) Multi-band gradient

The majority. Splits `idx` into 4–8 bands using `if (idx < N)` and defines `R/G/B` as linear functions of `idx` within each band. Examples:

- **Fire** (`6'd1`): 3 bands → black-red, red-yellow, yellow-white
- **Aurora Borealis** (`6'd42`): 6 bands → deep greens, teals, magentas, purples
- **Migraine Aura** (`6'd46`): 7 bands → alternating bright whites and electric flashes

The band math reuses three pre-computed slope quantities (`r0_t`, `r1_t`, `r2_t`) corresponding to `3*idx` for `idx < 86`, `idx-86`, `idx-171` — a tri-segment encoding that several palettes share.

### c) Grayscale fallback

The `default` clause outputs `R = G = B = idx`. Any out-of-range palette select lands here. (`6'd3` was Grayscale historically; it now hosts Oil Slick.)

### d) Hard LUT (discrete colour table)

Indexed by a low bit-slice of `idx` (e.g. `idx[3:0]` for 16 entries, `idx[2:0]` for 8, `idx[1:0]` for 4). No interpolation — colour jumps at every group boundary. Produces strobe-like cycling because the colour repeats every N idx values.

- **C64** (`6'd19`): 16-entry LUT — the canonical example
- **Game Boy** (`7'd75`): 4-entry olive shades
- **ZX Spectrum** (`7'd78`): 16-entry (8 standard + 8 bright)
- **SMPTE Color Bars** (`7'd83`): 8-entry broadcast pattern
- **Stained Glass Hard** (`7'd88`): 8-entry with black lead-line slots

### e) Hybrid smooth + flash override

A smooth gradient (style b) **with one or more periodic colour overrides** keyed off a low bit-slice of `idx`. The override fires for specific values of `idx[N:0]` and short-circuits the gradient. Visually: a calm river of colour with sudden coloured strikes — the source of "rhythm" in palettes like Milky Way.

The canonical example (`rtl/color_mapper.v:553-565`, idx 13, OSD name *Frozen* / overlay name *Milky Way*):

```verilog
out_r = (idx[2:0] == 3'b000) ? 8'd255 : 8'd80 + r2_t[7:2];
out_g = (idx[2:0] == 3'b000) ? 8'd255 : 8'd80 + r2_t[7:2];
out_b = (idx[2:0] == 3'b000) ? 8'd255 : 8'd120 + r2_t[7:1];
```

In the third band only (deep iter), every 8th idx fires pure white — 1-in-8 white sparks on a smooth blue bed.

#### Flash rhythms — periodicity vocabulary

The override condition encodes the rhythm. Each ratio gives a recognisable visual character:

| Pattern | Verilog test | Coverage | Feel |
|---|---|---|---|
| 1-in-2 | `idx[0] == 0` | 50 % | Strobing, alternating, busy |
| 1-in-4 | `idx[1:0] == 0` | 25 % | Steady 4/4 beat |
| 1-in-8 | `idx[2:0] == 0` | 12.5 % | Milky Way default; brisk pulse |
| 1-in-16 | `idx[3:0] == 0` | 6 % | Sparse spark |
| 1-in-32 | `idx[4:0] == 0` | 3 % | Rare surprise punch |
| 2-in-8 double-pulse | `idx[2:0] == 0 \|\| idx[2:0] == 1` | 25 % | Heartbeat / double-tap |
| Compound | `(idx[3:0] == 0)` then `(idx[2:0] == 4)` | layered | Two unrelated rhythms — busy but textured |
| Band-localised | `idx[2:0] == 0 && (idx >= 8'd171)` | 4 % | Calm head, strobing tail (Milky Way) |

The override is checked **before** the gradient bands, so a sparser override leaves the calm gradient intact most of the time. Compound rhythms (e.g. 1-in-8 red + 1-in-16 blue + 1-in-32 white in Strobe Police) layer different periods to feel less mechanical than a single repeating beat.

**Interaction with colour cycling.** As `cycle_idx_offset` shifts the palette by 1 every 16 frames, the *positions* where overrides fire move across the boundary at 1 pixel / 16 frames. So a 1-in-8 flash at iter-count 0/8/16/24/… becomes a 1-in-8 flash at 1/9/17/25/… 16 frames later — the flashes appear to scroll around the fractal boundary at ~3.75 idx/sec.

Picking different periods per palette keeps the catalogue varied; using the same 1-in-8 everywhere makes everything feel like one palette with different colours.

## 4. Colour cycling

`rtl/color_mapper.v:1415-1428`:

```verilog
if (cycle_enable) begin
    if (vblank_rise)
        cycle_phase <= cycle_phase + 12'd4;
end else begin
    cycle_phase <= 12'd0;
end
```

- 12-bit phase accumulator, increments by 4 each VBLANK rising edge.
- Wraps every `4096 / 4 = 1024` frames ≈ **17 seconds** at 59.7 Hz.
- Top 8 bits drive `cycle_idx_offset` (full 256-entry sweep).
- Low 4 bits drive `cycle_frac` for inter-entry blending.

### Blend math

`rtl/color_mapper.v:43-66`:

```verilog
blend_channel(a, b, frac) = (scale_u8_5bit(a, 16-frac) + scale_u8_5bit(b, frac)) >> 4
```

`scale_u8_5bit` decomposes the 5-bit weight into shift-and-add operations (no general multiplier). Each channel is blended independently. The blend produces 16 sub-steps between adjacent palette entries → 256 × 16 = 4096 visible colours per cycle.

### Toggle paths

- OSD bit `O[10]`: On/Off (`status[10]`)
- Keyboard `C` (PS/2 scancode `8'h21`)
- Joystick button `B`

## 5. Palette selection paths

Three sources can drive `palette_sel`; the priority mux lives in `rtl/fractal_top.v:245-250`:

```verilog
wire [5:0] palette_sel = osd_palette_override ? osd_palette_idx :
                         input_palette_override ? input_palette_sel :
                         auto_zoom_active       ? az_palette_idx  : input_palette_sel;
```

| Priority | Source | When active |
|---|---|---|
| 1 (highest) | OSD `O[9:4]` | User picked a fixed palette in the menu (non-zero) |
| 2 | Keyboard / joystick override | User pressed `P` or joy `Y` since last POI transition |
| 3 | Auto-zoom playlist | Auto-zoom is running and no manual override is set |
| 4 (default) | `input_palette_sel` | Manual mode, palette = 0 (Rainbow) |

### Auto = let the core choose

OSD `O[9:4] = 0` means "Auto" — the OSD doesn't pin a palette, so the auto-zoom playlist (or the user's last `P` press) wins. OSD values `1..47` map to fixed palettes `0..46` via `osd_palette_idx = osd_palette_sel - 1`.

### Manual cycling

PS/2 `P` (scancode `0x4D`) increments `palette_sel` and sets `palette_override_active`. The wrap is hard-coded:

```verilog
palette_sel <= (palette_sel == 6'd46) ? 6'd0 : palette_sel + 6'd1;
```

`palette_override_active` is **cleared automatically** when auto-zoom advances to the next POI (`sync_clear_palette_override` from `fractal_top.v`). This means manual palette picks during auto-zoom only stick until the next POI swap, which keeps the auto-zoom show varied.

## 6. Auto-zoom palette playlist

`rtl/auto_zoom.v` owns a shuffled palette playlist independent of the POI playlist:

- `N_PALETTES = 47`, `PAL_BITS = 6`
- `palette_playlist [0:46]` storage, populated with `0..46`
- Shuffled once on reset using LFSR-seeded Fisher-Yates with rejection sampling (4 random 6-bit candidates per swap; ~16% fallback rate because `max_idx = 46` is 73% of the 6-bit range — the rest of the time we pick the next sequential index)
- Playlist position advances in lockstep with the POI playlist; both wrap independently

## 7. Inside-set pixels

`rtl/color_mapper.v:1432-1441`:

```verilog
if (escaped) begin
    color_r <= blend_channel(color_a_r, color_b_r, cycle_frac);
    color_g <= blend_channel(color_a_g, color_b_g, cycle_frac);
    color_b <= blend_channel(color_a_b, color_b_b, cycle_frac);
end else begin
    color_r <= 8'd0;
    color_g <= 8'd0;
    color_b <= 8'd0;
end
```

Every palette produces black for `escaped = 0`. Use the palette to colour *escape time*, not set membership. The interior cardioid + period-2 bulb precheck in `iter_quad.v` short-circuits these pixels to `iter_count = max_iter` before iteration even starts, so they appear as crisp black regardless of zoom or `max_iter` setting.

## 8. Names and display

Three places carry palette names; **keep them in sync** when adding/renaming:

| Location | Format | Used by |
|---|---|---|
| `MiSTerbrot.sv` CONF_STR `O[9:4]` | comma-separated, OSD-display names | MiSTer menu |
| `rtl/text_overlay.v` `palette_name()` | 12-char strings, lowercase | Bottom-left overlay (after `\|` separator) |
| `rtl/text_overlay.v` `palette_line()` | `"PAL: <NAME>"`, 30 chars padded | Top-left info region (currently disabled) |

Names are not always identical between sources — the OSD list says "Sunset" while the overlay says "SUNSET" and the older `palette_line` says "PAL: SUNSET". Match the OSD list as the authoritative public name.

## 9. The 90 palettes

| Idx | OSD name | Style | Notes |
|---|---|---|---|
| 0 | Rainbow | HSV 6-segment | Default. Classic R→Y→G→C→B→M cycle. |
| 1 | Fire | 3-band | Black → red → yellow → white. |
| 2 | Ocean | 3-band | Black → blue → cyan → white. |
| 3 | Oil Slick | 6-band | Iridescent film — black, violet, petrol, teal, magenta, toxic green, gold. Replaced the prior Grayscale slot. |
| 4 | Electric | 4-band | Cool blues and electric whites. |
| 5 | Neon | 3-band | Magenta → pink → cyan. |
| 6 | Pastel | 3-band | Muted pinks, greens, yellows. |
| 7 | Sunset | 3-band | Warm orange-to-red gradient. (Originally a second grayscale slot, repurposed.) |
| 8 | Aurora | 3-band | Greens and pinks like the northern lights. |
| 9 | Deep Sea | 3-band | Deep blues with bright accents. |
| 10 | Candy | 3-band | High-saturation pinks and yellows. |
| 11 | Matrix | 3-band | Greens on black. |
| 12 | Toxic | 3-band | Acid greens and yellows. |
| 13 | Frozen | 3-band | Icy blues and whites. |
| 14 | Lava | 3-band | Red-orange-yellow molten gradient. |
| 15 | Earth | 3-band | Browns and tans. |
| 16 | Indigo | 3-band | Indigo with violet accents. |
| 17 | 70s Retro | 3-band | Olive, harvest gold, burnt orange. |
| 18 | 90s Rave | 4-band | Saturated electric primaries. |
| 19 | C64 | 4-band | Commodore 64 palette homage. |
| 20 | Miami | 4-band | Hot pink, teal, sunset tones. |
| 21 | Gold | 4-band | Gold gradient. |
| 22 | Starlight | 4-band | Deep blues with bright star whites. |
| 23 | Nebula | 4-band | Purple-pink galactic clouds. |
| 24 | Silver | 4-band | Cool grays with blue tint. |
| 25 | Akihabara | 4-band | Hot pink, cyan, electric blue. |
| 26 | Colorado | 4-band | Reds and earth tones. |
| 27 | XTC | 4-band | Iridescent purples. |
| 28 | Psilocybin | 4-band | High-saturation psychedelic. |
| 29 | HDR | 4-band | Wide dynamic range, deep blacks to bright whites. |
| 30 | THC | 4-band | Greens and purples. |
| 31 | Barbie World | 5-band | Hot pink → magenta → white → baby blue → pink. |
| 32 | Skittles | 5-band | Bold saturated primaries. |
| 33 | Papagaio | 4-band | Scarlet → cobalt → emerald → sun yellow (parrot). |
| 34 | Bubblegum | 5-band | Soft pastels pink → mint → baby blue → lavender → lemon. |
| 35 | Synthwave | 4-band | Dark purple → neon magenta → cyan → purple. |
| 36 | Pop Art | 4-band | Bold red → yellow → blue → black (Warhol-style). |
| 37 | Tropical | 4-band | Hibiscus pink → mango → palm green → ocean blue. |
| 38 | Vaporwave | 4-band | Pastel pink → turquoise → lavender with white. |
| 39 | Acid | 4-band | Neon green → neon yellow → neon pink on dark. |
| 40 | Morning Sun | 5-band | Deep navy → rose → peach → golden → white. |
| 41 | Cloudy | 5-band | Slate → soft blue → cream → silver → cloud white. |
| 42 | Aurora Borealis | 6-band | Deep greens, teals, magentas, purples. |
| 43 | Cream | 4-band | Warm whites, ivories, light golds. |
| 44 | Palladium Silver | 5-band | Cool metallic silvers, steel blues. |
| 45 | Complementary | 7-band | Opposing hue pairs for high contrast. |
| 46 | Migraine Aura | 7-band | Shimmering whites and electric zigzags. |
| 47 | Radioactive Glass | 4-band | Black → dark green → acid green → yellow-green → pale white. |
| 48 | Cathedral Window | 4-band | Stained-glass jewel tones: ruby → sapphire → emerald → amber → violet. |
| 49 | CRT Phosphor | 4-band | Old terminal: black → phosphor green → cyan-green → faded white. |
| 50 | Deep Sea Bioluminescence | 4-band | Navy → deep blue → cyan → turquoise → white sparks. |
| 51 | Rust & Copper | 4-band | Aged metal: dark brown → rust → copper → tarnished gold → patina green. |
| 52 | Cyberpunk Noir | 4-band | Black → purple → neon pink → electric blue → acid cyan. |
| 53 | Bone & Ink | 4-band | Engraving palette: black → sepia → ash → ivory → bone white. |
| 54 | Solar Flare | 4-band | Dark red-brown → crimson → orange → yellow → white. |
| 55 | Arctic Plasma | 4-band | Frozen electricity: midnight blue → icy blue → cyan → mint → white. |
| 56 | Toxic Candy | 4-band | Dark purple → hot pink → lime → cyan → candy orange. |
| 57 | Old Terminal Amber | 4-band | Retro CRT: black → dark brown → amber → orange → cream. |
| 58 | Alien Coral Reef | 4-band | Black-blue → coral red → turquoise → purple → yellow-green. |
| 59 | Black Hole Accretion | 4-band | Black → violet → hot orange → white → electric blue / red collapse. |
| 60 | Infrared Camera | 4-band | Thermal: black → violet → red → orange → yellow → white. |
| 61 | Pearlescent | 4-band | Mother-of-pearl: pale rose → mint → light blue → soft gold/silver. |
| 62 | Data Center Night | 4-band | Black → slate blue → cold gray → server LED green → status cyan. |
| 63 | Lava Lamp | 4-band | Dark purple → red → orange → pink → cream. |
| 64 | Monochrome Brutalist | 4-band | Black → charcoal → gray → light → white. Subtle magenta accent in band 3. |
| 65 | Event Horizon | 4-band | Absolute black → violet → blue-white → orange → red. |
| 66 | Psychedelic Circuit | 4-band | Black → neon green → purple → cyan → magenta → white. |
| 67 | Desert Mirage | 4-band | Dark umber → sand → gold → dusty rose → pale blue → white heat. |
| 68 | Blood Moon | 4-band | Black → dark maroon → crimson → copper red → pale moon-gray. |
| 69 | Quantum Foam | 4-band | Black → electric blue → cyan/pale green → violet → white spark. |
| 70 | Hypernova Candy | 4-band | Black → hot pink → laser cyan → electric yellow → neon orange. |
| 71 | Cyber Dragon | 4-band | Black → emerald → toxic lime → violet → magenta → orange flare. |
| 72 | Laser Carnival | 4-band | Deep purple → neon red → cyan → lime → yellow → white. |
| 73 | Glitch Prism | 4-band | Sharp transitions: black → R → G → B → magenta → white. |
| 74 | Plasma Rave | 4-band | Black → ultraviolet → hot pink → acid green → bright orange → white. |
| 75 | Game Boy | 4-LUT | Original DMG olive: 4 distinct shades, hard 4-step jumps. |
| 76 | NES Castlevania | 16-LUT | NES PPU palette subset — purples, blood reds, ash gray, bone white. |
| 77 | Embers | smooth + 1-in-16 | Dark red → orange → amber gradient with rare bright white sparks. |
| 78 | ZX Spectrum | 16-LUT | 8 standard + 8 bright Spectrum colours, hard discrete jumps. |
| 79 | CGA Magenta | 4-LUT | Classic CGA palette 1: black/cyan/magenta/white. |
| 80 | Strobe Police | smooth + 1-in-8+16+32 | Dark navy gradient with layered red (1-in-8), blue (1-in-16) and white (1-in-32) flashes. |
| 81 | Halloween Strobe | smooth + 2-in-8 + 1-in-32 | Purple→orange gradient with lime double-pulse and rare white skeleton flash. |
| 82 | Traffic Lights | smooth + 1-in-8 | Dim red/yellow/green smooth base with bright signal-colour flash matching each band. |
| 83 | SMPTE Color Bars | 8-LUT | Broadcast colour-bar pattern: white, yellow, cyan, green, magenta, red, blue, black. |
| 84 | Pixel Sprite | 8-LUT | Classic 8-bit hero: outline / skin / shirt / pants / boots / accents. |
| 85 | Vintage Poster | smooth + 1-in-32 | Avocado→burnt orange smooth base with rare mustard punch. |
| 86 | Casino Slots | smooth + 1-in-8 + 1-in-16 | Gold gradient with cherry red flashes and rarer white jackpots. |
| 87 | Neon Tubes | smooth + 1-in-4 | Dark blue→hot pink smooth base with vibrant 1-in-4 cyan flash. |
| 88 | Stained Glass Hard | 8-LUT | Discrete jewel tones with black lead lines (vs. smooth Cathedral Window at idx 48). |
| 89 | Disco Floor | smooth + 1-in-2 + 1-in-16 | Rainbow gradient strobed by black voids (1-in-2) with bright white peaks (1-in-16). |

## 10. Adding a new palette

The change touches four files. Skipping any one of them ships a broken core (silent palette skip in cycle, wrong name on OSD, etc.).

1. **`rtl/color_mapper.v`** — add a new `case` clause to the `palette_rgb` task. Pick an arithmetic recipe that produces 24-bit RGB from `idx[7:0]`. Keep it within the LUT-add budget — the synthesis cost grows with the number of `if (idx < N)` bands. The cost summary (current fit): 47 palettes synthesise into ALMs without DSPs, leaving DSP headroom intact.

2. **`MiSTerbrot.sv`** — append the OSD-display name to the `O[9:4],Palette,Auto,...` CONF_STR. **Order matters** — the position determines the OSD selection number, and the OSD selection minus 1 is the canonical palette index.

3. **`rtl/text_overlay.v`** — add an entry to `palette_name()` (and optionally `palette_line()` if the info region gets re-enabled). The 12-char limit is fixed by the function return width; pad with spaces to exactly 12 chars.

4. **`rtl/auto_zoom.v`** — bump `localparam N_PALETTES`. Then update `rtl/input_handler.v` keyboard-cycle bounds:

   ```verilog
   palette_sel <= (palette_sel == 6'd46) ? 6'd0 : palette_sel + 6'd1;
   //                              ↑ bump this to the new last index
   ```

   in **both places** (`8'h4D` P-key handler and the `joy_y` button handler).

5. Rebuild and re-deploy. The OSD list updates immediately on next core load; the palette playlist re-shuffles on reset.

If `N_PALETTES` ever exceeds 128, all the `7'dN` literals and `PAL_BITS = 7` need to widen to 8, including the playlist array size and the `palette_sel` port widths through `text_overlay.v`, `color_mapper.v`, `fractal_top.v`, `fractal_osd.v`, `input_handler.v`, and `MiSTerbrot.sv` (the OSD bit range too). Currently we have headroom (75/128).

## 11. Why combinational, not ROM

A 47-entry × 256-step × 24-bit ROM would be `47 × 256 × 3 = 36 KiB` of M10K — about 4 % of total BRAM, on top of the 58 % already used by the framebuffer. Combinational synthesis lets each palette be evaluated only when its `case` arm is selected, and the `palette_rgb` task is called only twice per pixel (for `base_cidx` and `next_cidx`). The LUTs needed for the arithmetic decode are cheaper than the BRAM would be, and the recipe form makes palettes easy to tweak without regenerating tables.

The cost: any palette change requires a Quartus rebuild (~20 min). Editing a ROM-stored palette would be a `\`include` swap. Given how rarely palettes change post-launch, the tradeoff has been clearly worth the BRAM saved.
