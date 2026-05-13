# Track A Performance Baseline

Initial hardware baseline captured on 2026-05-12 with the benchmark pixel
telemetry setup. Decode screenshots with `tools/bench_decode_screenshot.py`.

Build:

- Core: `MiSTerbrot_20260512.rbf`
- Bitstream SHA256: `c18dd551f019ab8c8ff70186a4484086c25040c79be68156955a7997eefad16d`
- Quartus seed: `2`
- Worst-case setup slack: `+0.093 ns`

| ID | Scene | F10 | Notes |
|---:|---|---:|---|
| 00 | FULL 320 | 596 | 59.6 FPS |
| 01 | FULL 640 | 596 | 59.6 FPS |
| 02 | CARDIOID | 597 | 59.7 FPS |
| 03 | P2 BULB | 597 | 59.7 FPS |
| 04 | P3 ISLAND | 298 | 29.8 FPS |
| 05 | SEAHORSE | 148 | 14.8 FPS |
| 06 | ELEPHANT MED | 596 | 59.6 FPS |
| 07 | FEIGENBAUM | 28 | 2.8 FPS |
| 08 | SATELLITE | 298 | 29.8 FPS |
| 09 | JULIA ISLES | 297 | 29.7 FPS |

`F10` is frames completed in the last 10 seconds, so sustained FPS is
`F10 / 10`. Record the decimal `f10` value printed by the decoder.
