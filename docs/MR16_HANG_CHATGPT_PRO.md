# ChatGPT Pro response to MR16_HANG_REPORT.md

## Top hypothesis

**Not stack overflow or the literal value 16.** It's a per-region accounting/protocol issue that MR=16 is the first mode to expose because it adds one more boundary-walk layer: **80×30 boundary regions followed by 40×15 full-dispatch leaves**.

Invariant to instrument:

> For every region, the number of accepted dispatches must exactly equal `slot_expected`, and the number of accepted results for that same region-generation must exactly equal the accepted dispatch count before the slot is reused.

With `N_SLOTS=1` and `RID_W=1`, every result is tagged `region_id=0` — so a stale/extra result from the previous region is indistinguishable from a valid result for the next region.

## 1. MR=16 is really "the 80×30 boundary case"

For 640×240 root, height sequence: `240 → 120 → 60 → 30 → 15`. Threshold bands:

| MR range | deepest boundary-walk size | full-dispatch leaf size |
|---------:|---------------------------:|------------------------:|
| 121–240  | 640×240                    | 320×120                 |
| 61–120   | 320×120                    | 160×60                  |
| 31–60    | 160×60                     | 80×30                   |
| 16–30    | 80×30                      | 40×15                   |
| 1–15     | 40×15 or smaller           | smaller                 |

MR=16 isn't special mathematically — it belongs to the 16–30 band.

**A/B test:**
| Test | Meaning |
|---|---|
| MR=30 also hangs | Bug is the 80×30 boundary / 40×15 full layer |
| MR=30 works, MR=16 hangs | Decode/CDC/timing/control-value, not quadtree geometry |
| MR=31 works | Confirms failure boundary is exactly the extra 80×30 layer |
| MR=15 hangs differently/earlier | 40×15 boundary walking also broken |

## 2. Most suspicious: stale result during slot reuse (race on `slot_received` clear)

This fragment is the smoking gun:

```verilog
SL_PREP: begin
    slot_received[s] <= 17'd0;
    ...
end
// later in same always block:
if (result_valid) begin
    slot_received[result_region_id] <= slot_received[result_region_id] + 17'd1;
    ...
end
```

If `result_valid` fires same cycle as `SL_PREP`, the router assignment wins (last NBA wins) — and it increments the **old** `slot_received`, not the cleared value:

```
previous region ended with slot_received = 216
new region enters SL_PREP
stale result_valid also arrives
slot_received <= 216 + 1 = 217
new region starts with received = 217 instead of 0
```

Then exact equality `slot_received == slot_expected` may never trigger.

The protection assumes:
1. `slot_expected` always equals actual accepted dispatch count
2. No dispatch is ever dropped
3. No result is ever duplicated
4. No previous-frame or previous-mode result can arrive after slot reuse
5. The iterator pipeline is fully drained before every new region
6. The result tag uniquely identifies the current **region generation**

**Condition 6 is false in this build.** `region_id == 0` identifies the slot, not the generation. With one slot, every region reuses the same tag.

MR=16 has many more region transitions:

```
MR=128: 1 split, 4 leaves
MR=64:  5 splits, 16 leaves
MR=32:  21 splits, 64 leaves
MR=16:  85 splits, 256 leaves
```

More transitions → more opportunities for a stale result to land during `SL_PREP`, `SL_IDLE`, `SL_DECIDE`, `SL_SPLIT`, or `SL_FILL`.

### Proposed fix: per-region generation tag

```verilog
reg [7:0] slot_gen [0:N_SLOTS-1];

always @(posedge clk_iter) begin
    if (entering_new_region)
        slot_gen[s] <= slot_gen[s] + 8'd1;
end
```

Dispatch carries `region_gen`; result router only counts results where `result_region_gen == slot_gen[result_region_id]`. Mismatches latch `dbg_stale_result_seen`.

Or at minimum, ignore results in states where they shouldn't exist:

```verilog
wire slot_accepts_result =
    (slot_state[result_region_id] == SL_FULL_OUT)  ||
    (slot_state[result_region_id] == SL_BD_TOP)    ||
    ... (other dispatch / wait states);

if (result_valid) begin
    if (slot_accepts_result) begin
        // ... normal accounting
    end else begin
        dbg_result_in_bad_state <= 1'b1;
    end
end
```

## 3. Exact-equality waits are brittle

```verilog
slot_received[s] == slot_expected[s]
```

If `slot_received` ever overshoots before the FSM reaches the wait state, the slot waits forever. Overshoot causes: extra result, stale result, duplicate result, wrong expected count, result-during-`SL_PREP` defeating the clear, dispatch/result count mismatch.

Using `>=` would mask the bug, not fix it. For diagnosis, keep `==` but add a debug latch:

```verilog
if (slot_received[s] > slot_expected[s] && !dbg_latched) begin
    dbg_latched  <= 1'b1;
    dbg_x0       <= slot_x0[s];
    dbg_y0       <= slot_y0[s];
    dbg_w        <= slot_w[s];
    dbg_h        <= slot_h[s];
    dbg_state    <= slot_state[s];
    dbg_expected <= slot_expected[s];
    dbg_received <= slot_received[s];
end
```

## 4. Add a sent/accepted dispatch ledger

Distinguish:

| Stuck condition                        | Likely cause                                  |
|----------------------------------------|-----------------------------------------------|
| `sent < expected`                      | Boundary/full walker under-emitted            |
| `sent == expected`, `received < expected` | Iterator dropped result / pipeline deadlock |
| `sent > expected`                      | Walker over-emitted or expected math wrong    |
| `received > expected`                  | Stale/duplicate result or wrong-region count  |
| result during `SL_PREP`                | Slot reuse race                               |
| result during `SL_IDLE/SPLIT/DECIDE/FILL` | Old result escaped accounting window       |

```verilog
reg [17:0] slot_sent [0:N_SLOTS-1];

always @(posedge clk_iter) begin
    if (reset || start_frame) begin
        slot_sent[0] <= 18'd0;
    end else begin
        if (slot_state[s] == SL_PREP) slot_sent[s] <= 18'd0;
        if (dispatch_valid && dispatch_accepted && dispatch_region_id == s[RID_W-1:0])
            slot_sent[s] <= slot_sent[s] + 18'd1;
    end
end
```

> Single highest-value probe.

## 5. Specifically probe 80×30 boundary and 40×15 full

```verilog
if (slot_state[s] == SL_PREP) begin
    if (slot_w[s] == 11'd80 && slot_h[s] == 10'd30)
        dbg_seen_80x30_boundary_candidate <= 1'b1;
    if (slot_w[s] == 11'd40 && slot_h[s] == 10'd15)
        dbg_seen_40x15_full_candidate <= 1'b1;
end
```

Plus a timeout latch when stuck in `SL_WAIT_BD`/`SL_WAIT_FULL`:

```verilog
reg [23:0] wait_timer;
// in wait state, increment timer; on overflow, latch full state
```

Expected diagnostic output examples:
- `SL_WAIT_BD, w=80, h=30, received=215, expected=216` → boundary walker missed a pixel
- `SL_WAIT_FULL, w=40, h=15, received=599, expected=600` → full walker / iter path lost a pixel
- `received > expected` → stale/extra result accounting

## 6. Boundary-walk per-edge dispatch counts

```verilog
reg [17:0] bd_top_sent, bd_right_sent, bd_bot_sent, bd_left_sent;
// increment on accepted dispatch in each BD state
```

Expected for 80×30:
- top: w=80
- right: h-1=29
- bot: w-1=79
- left: h-2=28
- total = 216

If `bd_left_sent != 28` for an 80×30 region, the bug is in `SL_BD_LEFT`. (My BD_LEFT theoretical underflow concern was for tiny regions only — but maybe an arithmetic edge case kicks in here.)

## 7. Stack: lower priority, but assert anyway

For `N_SLOTS=1`, same-cycle push+pop should be impossible. Verify:

```verilog
if (push_will_happen && pop_will_happen) dbg_push_pop_same_cycle <= 1'b1;
if (push_will_happen && stack_top > STACK_DEPTH-4) dbg_stack_overflow <= 1'b1;
if (pop_will_happen && stack_top == 0) dbg_stack_underflow <= 1'b1;
if (push_will_happen && slot_state[0] != SL_SPLIT) dbg_push_misaligned <= 1'b1;
```

## 8. Counter width bug (separate issue)

```verilog
reg [16:0] slot_received;  // 17 bits, max = 131,071
```

Comment claims max 153,600 (640*240). That needs 18 bits. Doesn't trigger at MR=16 (max leaf is 40*15=600), but is a real bug for any larger full-dispatch.

Use parameterized `CNT_W = 18`.

## 9. `min_region_dim` registration result points toward CDC

The registration making MR=32/64 worse is a warning sign. Don't feed a live multi-bit config value from `clk_sys` into region decisions.

Correct pattern: synchronize a small MR selector (not the raw dimension), latch the active MR only at frame boundary, use latched value for the whole frame:

```verilog
reg [1:0] mr_sel_iter_meta, mr_sel_iter_sync, mr_sel_frame;

always @(posedge clk_iter) begin
    mr_sel_iter_meta <= mr_sel_sys;
    mr_sel_iter_sync <= mr_sel_iter_meta;
    if (start_frame_iter) mr_sel_frame <= mr_sel_iter_sync;
end
```

A live MR change mid-frame wouldn't explain MR=16 alone, but **can produce exactly the "works in isolation, fails after previous condition" behavior we saw**.

## 10. Timing: test but don't lead with it

```
Run clk_iter at 50 MHz or 75 MHz.
```

| Result | Meaning |
|---|---|
| MR=16 still hangs | Logic/protocol bug |
| MR=16 works slower | Timing or CDC |
| Inconsistent between runs | CDC/reset/unconstrained-path suspicion |

Check TimeQuest for unconstrained / cross-clock paths on `ms_enable`, `mr_sel`, `min_region_dim`, `start_frame`, `mode_640`, scene/benchmark control, iterator reset/flush. A clean +0.126 ns on constrained paths says nothing about an unsynchronized multi-bit control bus.

## Recommended order

1. **Add `slot_sent` ledger + wait-timeout latch.** Determine which stuck condition we hit.
2. **A/B compile with `min_region_dim` hardcoded to 30 and 31.** Geometric test.
3. **Latch bad-state results.** Detect `result_valid` during `SL_PREP/IDLE/DECIDE/SPLIT/FILL`.
4. **Temporarily disable fill** (force every boundary region to split). If MR=16 still hangs → fill isn't the cause; if it stops → scrutinize `SL_FILL`.
5. **Force 80×30 to full-dispatch.** If MR=16 then works → the 80×30 boundary walk is the culprit.
6. **Fix counter width** to 18+ bits.
7. **Synchronize/latch MR config per frame.** Don't use live multi-bit config in `SL_PREP`.

**Pro's bet:** first useful failure capture will show either a stale result counted into a newly-prepped region, or an off-by-one dispatch count in the 80×30 boundary path.
