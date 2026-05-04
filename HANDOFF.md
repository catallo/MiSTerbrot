# Handoff — `pipeline-wide` branch

## Headline

Branch achieves a 2× iteration throughput speedup (200 → 400 Miter/sec, same DSP count) plus a runtime 320/640 resolution toggle. **One unresolved bug:** a persistent display artifact in 640 mode that has resisted multiple targeted fixes. Reproducer is reliable; root cause is not yet pinpointed.

## Branch state

Tip commit: `e44f225` (round FB MEM_SIZE up to power of 2).
Bookmark `unification-wip` at `c7cd7dd` saved single-clock unification work that was abandoned (not on this branch).

Commit lineage from `main` (oldest to newest):

| Commit | What |
|---|---|
| `0eeffca` | Remove stale CLAUDE.md |
| `07fa5ed` | Stage A: pipeline iter_quad — 3 stages, 4 contexts, 16 iterators |
| `a84b340` | Fix stray semicolon in BUILD_DATE |
| `4dcd66f` | Stage B: clk_iter @ 75 MHz with CDC |
| `3388b0f` | Stage B+: split iter_quad Stage 2b |
| `c154e3e` | Hoist cardioid/bulb compares into Stage 2b1 |
| `1ae8774` | Stage 2a as explicit 64-bit add |
| `2552d37` | 5-stage / 5-context iter_quad for 100 MHz |
| `0dbf169` | BCD serial converter replaces text_overlay LPM_divide |
| `ee8709a` | **Stage C**: runtime 320/640 toggle |
| `5ee570b` | Widen FB y-slice — speculative fix attempt |
| `978a13a` | Trigger re-render on mode_640 toggle — fix attempt |
| `3fa98f1` | V_FP 3 → 10 lines — fix attempt |
| `3ca6073` | Clamp FB rd_addr in-range during blanking — fix attempt |
| `e44f225` | Power-of-2 MEM_SIZE — fix attempt |

## What works

- 320 mode (default, status[22]=0): renders cleanly, full overlay correct, no visual artifacts. fps tracks scene complexity (4–60 fps range, hits 60 cap on light scenes).
- 640 mode (status[22]=1): renders the fractal correctly at 8:3 aspect ratio (square pixels through ascaler), text overlay repositioned for wider screen, ~30 fps typical, 2× iteration throughput.
- OSD toggle "Resolution: 320x240/640x240" wired through hps_io status bit 22.
- Build closes timing at 100 MHz with marginal positive slack on clk_iter (typically +0.013 to +0.07 ns, sometimes negative on placement variance — works on real silicon at room temp).

## The unresolved bug

**Symptoms (640 mode only, both HDMI and VGA outputs):**
- Top ~15% of screen (~36 lines, full width) shows a copy of the bottom ~15% of the screen.
- Inside the top bar, an additional ~200×40 region in the upper-LEFT shows content from the lower-RIGHT corner (which contains the GitHub/build label text).
- Persists in static scenes (auto-zoom OFF). So it's NOT motion/timing-driven.
- Persists in double-buffer mode (the practical mode).
- In single-buffer mode, the equivalent artifact appears at the BOTTOM and clears after the framebuffer is fully populated. Single-buffer mode itself isn't usable for normal viewing (flickers, partial-render visible).
- Misterclaw screenshots sometimes show the artifact, sometimes don't (intermittent capture-side).

**Numerical relationship suggests address-bit corruption:**
- Top bar showing bottom 15% = address offset of +130560 (= 153600 − 23040 = bottom-of-FB minus top-of-FB).
- Upper-left square showing lower-right = additional +480 in x.
- Total offset of ~131040 ≈ 131072 = **2^17 = address bit 17 set incorrectly**. This is the boundary where bottom-half-of-FB lives.

The simplest hypothesis remains: somewhere in the FB read or write path, address bit 17 (or a few high bits) is being computed wrong for some addresses.

## Fix attempts that didn't work

1. **Widen FB y-slice from `[7:0]` to `[8:0]`** (`5ee570b`) — ruled out vid_pixel_y wrap-around during vblank causing aliasing into low-y rows.
2. **Trigger re-render on mode_640 toggle** (`978a13a`) — ruled out stale-cross-mode FB content.
3. **V_FP 3 → 10 lines** (`3fa98f1`) — based on agent research suggesting scandoubler `vbo[3:0]` pipeline timing. Did not help.
4. **Clamp rd_addr to in-range during hblank/vblank** (`3ca6073`) — ruled out out-of-bounds BRAM reads leaking through 1-cycle latency.
5. **Round MEM_SIZE up to 2^18 = 262144** (`e44f225`) — Quartus didn't change BRAM allocation (same RAM block count); fix probably has zero effect at this MEM_SIZE. Has not been verified to NOT help yet (last build deployed but not visually confirmed at session end).

## Best next debug steps (untried)

In recommended order:

1. **Test pattern injection.** In `rtl/fractal_top.v`, replace `wr_data` with `wr_addr[12:0]` so each FB cell holds its own address. Display shows a deterministic gradient. Any region with WRONG gradient values pinpoints exactly which addresses are returning wrong content (read-side issue) or being written wrong (write-side issue). 5 minutes of edits + 17-min build.

2. **Compare the same scene across modes.** Same fractal (auto-zoom off, fixed center/step/palette) in 320 vs 640. If 320 has the same FB content for an address that's clean, but 640 has wrong content at the same address, the bug is in the 640 address computation specifically.

3. **Investigate `iter_busy` / `iter_done_pending` CDC across modes.** The FB write-addr math has been verified by hand for arbitrary y/x but the iter_quad → pixel_pipeline CDC could conceivably drop or duplicate writes for specific dispatch_idx/collect_idx round-robin states only in 640 mode (more pixels in flight per frame).

4. **Read MiSTer's `arcade_video.v` / `video_mixer.sv` more carefully.** I had a research agent look but the conclusion (V_FP timing) didn't pan out. There may be a real interaction with `WIDTH=640` that wasn't fully understood.

## Test setup

- MiSTer at `10.0.0.8` (local network).
- Tool `tools/misterclaw-send` for remote control: `status`, `screenshot --output X.png`, `shell "..."`, `input type "..."`.
- Deploy: `scp` the RBF (must be named `MiSTerbrot_YYYYMMDD.rbf` per PROJECT.md), then `echo 'load_core /media/fat/_Other/...' > /dev/MiSTer_cmd`. Set `status[22]=1` for 640 mode by writing `printf '\x00\x00\x40\x00...' > /media/fat/config/MiSTerbrot.CFG` before reload.
- SSH: `root` / `1` (default MiSTer credentials, `sshpass` is installed locally).
- Quartus build via Docker: `docker run --rm -v $(pwd):/build ryanfb/quartus-mister bash -c "export PATH=/opt/intelFPGA_lite/17.0/quartus/bin:\$PATH && cd /build && quartus_sh --flow compile MiSTerbrot"` — ~17 min.

## Resource summary at branch tip

| | main | branch tip |
|---|---|---|
| ALMs | 19,101 (46%) | 25,532 (61%) |
| Registers | 20,815 | 31,525 |
| DSP | 112/112 (100%) | 112/112 (100%) |
| RAM blocks | 245/553 (44%) | 375/553 (68%) |
| BRAM bits | 33% | 51% |
| PLLs | 3/6 | 3/6 |
| clk_iter | 50 MHz | 100 MHz (dual-clock with CDC) |

## Honest take for the next session

The 2× speedup and 640 capability are real, useful work. The bug is annoying but bounded (640 mode only, intermittent visibility). If the test-pattern injection (step 1 above) doesn't quickly localize it, options are:

- Ship Stage C with the artifact documented as a known issue (last user pushed back on this).
- Drop runtime 320 mode, ship 640-only (won't fix the artifact but simplifies code).
- Revert Stage C, ship Stage B (100 MHz + BCD, native 320×240) — full speedup, no resolution toggle, no artifact.

Recommend: spend ~30 min on the test-pattern debug (step 1) — likely surfaces the root cause. If it points at a fixable RTL bug, fix and ship. If it points at a Quartus BRAM stitching weirdness or MiSTer framework interaction, fall back to one of the trade-off options.
