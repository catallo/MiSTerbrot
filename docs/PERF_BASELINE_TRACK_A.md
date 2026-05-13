# Track A Performance Log

Running record of the Track A frame-rate effort. Each entry is a benchmark
suite run on real hardware, capturing F10 (frames in the last 10 s, sampled
from the pixel-telemetry strip) for every scene in `tools/benchmarks.json`.

**We keep every run in this file — never overwrite an earlier baseline.** The
point is to watch the curve, not just the latest number. Add new entries at
the top; older runs stay below as context for the next optimisation. Treat
this file as the optimisation changelog: one section per build that moved
the needle (or didn't), each with its bitstream hash + build settings so the
numbers stay attributable.

Decode screenshots with `tools/bench_decode_screenshot.py`; run the suite
with `tools/bench_run.py --label <name> --output <path>`; diff two runs
with `tools/bench_diff.py <before.json> <after.json>`.

---

## 2026-05-13 · `6ctx-postfix` — 6-context iter_quad baseline

First run after the 6-context / operand-input-register refactor closed
timing at 100 MHz and the `phase_d4` writeback gate was restored (initial
6-ctx rev incorrectly gated on a newly-added `phase_d5`, scrambling
per-context writeback by one slot — visible as scattered black dots and
~10× slowdown). This becomes the Track A starting line.

Build:

- Core: `MiSTerbrot_20260513.rbf`
- Bitstream SHA256: `ee75241e43f7d87f0d3f3d4bff1c2d9eadd3544d5123547595c63ecb2f2a20de`
- Quartus seed: `3`
- Iterators: `24` (4 quads × 6 contexts)
- Iter clock: `100 MHz` · setup slack `+0.513 ns`
- Results JSON: `tools/benchmark_results_6ctx_postfix.json`

| ID | Scene | F10 | FPS |
|---:|---|---:|---:|
| 0 | FULL 640 | 596 | 59.6 |
| 1 | P3 ISLAND | 394 | 39.4 |
| 2 | P5 ISLAND DEEP | 222 | 22.2 |
| 3 | TRIPLE SPIRAL P4 | 30 | 3.0 |
| 4 | SEAHORSE TAIL | 98 | 9.8 |
| 5 | ELEPHANT ISLAND | 78 | 7.8 |
| 6 | FEIGENBAUM DEEP | 27 | 2.7 |
| 7 | JEWEL BOX | 56 | 5.6 |
| 8 | SH SATELLITE | 50 | 5.0 |
| 9 | JULIA ISLANDS | 22 | 2.2 |

---

## 2026-05-12 · Pre-refactor baseline (older scene list — not comparable)

Captured before the benchmark scene list was rewritten, so the scenes
below do **not** correspond 1:1 with the current `tools/benchmarks.json`.
Kept for historical reference only.

Build:

- Core: `MiSTerbrot_20260512.rbf`
- Bitstream SHA256: `c18dd551f019ab8c8ff70186a4484086c25040c79be68156955a7997eefad16d`
- Quartus seed: `2`
- Iterators: `20` (4 quads × 5 contexts)
- Iter clock: `100 MHz` · setup slack `+0.093 ns`

| ID | Scene | F10 | FPS |
|---:|---|---:|---:|
| 00 | FULL 320 | 596 | 59.6 |
| 01 | FULL 640 | 596 | 59.6 |
| 02 | CARDIOID | 597 | 59.7 |
| 03 | P2 BULB | 597 | 59.7 |
| 04 | P3 ISLAND | 298 | 29.8 |
| 05 | SEAHORSE | 148 | 14.8 |
| 06 | ELEPHANT MED | 596 | 59.6 |
| 07 | FEIGENBAUM | 28 | 2.8 |
| 08 | SATELLITE | 298 | 29.8 |
| 09 | JULIA ISLES | 297 | 29.7 |

`F10` is frames completed in the last 10 seconds, so sustained FPS is
`F10 / 10`.
