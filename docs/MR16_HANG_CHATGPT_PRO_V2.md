# ChatGPT Extended Pro response to MR16_HANG_REPORT_V2.md

**Verdict:** the new data clears `region_manager.v`. The MR=16 failure is not an MS recursion-depth bug — it's a top-level race in `fractal_top.v`'s render FSM that MR=16 happens to hit more often (probably because it changes timing/key-sequence/first-MS-frame duration).

## The contradiction explained

`render_state=RS_WAIT_SWAP` with `dbg_pp_frame_done_seen=0` is consistent because the sticky flags are cleared on bench-mode entry. So the observed state means:

> The FSM was already in `RS_WAIT_SWAP` before or at bench entry, and no new `frame_done` occurred after the debug flags were cleared.

## The smoking gun

```verilog
// Bank-swap block (separate always)
if (vblank_rise && (frame_complete || frame_done_rise)) begin
    bank_sel <= ~bank_sel;
    frame_complete <= 1'b0;        // ← clears frame_complete
end
```

vs.

```verilog
// Render FSM
RS_RENDER: begin
    if (frame_done) render_state <= RS_WAIT_SWAP;
end

RS_WAIT_SWAP: begin
    if (vblank_rise && frame_complete) begin ... end  // ← needs frame_complete
end
```

The bank-swap block is allowed to consume a same-cycle `frame_done_rise`, but the render FSM only performs the `WAIT_SWAP` exit while it was already in `RS_WAIT_SWAP` before that clock edge.

### The exact race

```text
Before clock edge:
    render_state    = RS_RENDER
    frame_complete  = 0
    frame_done_prev = 0
    frame_done      = 1
    frame_done_rise = 1
    vblank_rise     = 1

On the clock edge:
    frame_complete block:
        sees frame_done_rise → schedules frame_complete <= 1
        also sees vblank_rise && frame_done_rise → schedules frame_complete <= 0
        final post-NBA: frame_complete = 0
    render FSM:
        old state is RS_RENDER
        sees frame_done = 1 → schedules render_state <= RS_WAIT_SWAP

After clock edge:
    render_state   = RS_WAIT_SWAP
    frame_complete = 0     ← stuck
    start_render   = 0
```

The completed-frame event was consumed by the bank-swap block, but the render FSM missed the corresponding `WAIT_SWAP` exit because it was still in `RS_RENDER` during that edge. On the next cycle it's in `RS_WAIT_SWAP`, but `frame_complete` has already been cleared. No new render starts, so no future `frame_done_rise` can rescue it.

## Second trap: level-sensitive `frame_done` in `RS_RENDER`

If `frame_done` is still high from the previous producer/frame after `frame_complete` has already been cleared, `RS_RENDER` can re-enter `RS_WAIT_SWAP` without a new `frame_done_rise`:

```text
render_state   = RS_RENDER
frame_done     = 1   (stale level)
frame_done_rise= 0
frame_complete = 0
=> render_state becomes RS_WAIT_SWAP
=> frame_complete remains 0
=> stuck
```

## S→B is a real mode-switch hazard

```verilog
assign coord_frame_done = ms_enable ? rm_frame_done : cg_frame_done;
```

Switching `ms_enable` while a frame is in progress changes which producer the FSM listens to:

```text
Before S: render started by coord_generator; cg_frame_done about to rise
After S:  coord_frame_done is now rm_frame_done
          RM may be M_IDLE because no MS render has been started yet
=> render FSM waiting for completion from a producer that was never started
```

`need_rerender`/`benchmark_active`/`benchmark_view_changed` cannot escape `RS_WAIT_SWAP && !frame_complete` — they're all behind the same dead guard.

## Recommended minimal fix (two-line concept)

### Fix 1: don't consume same-cycle `frame_done_rise` in the bank-swap

```diff
- if (vblank_rise && (frame_complete || frame_done_rise)) begin
+ if (vblank_rise && frame_complete) begin
      bank_sel <= ~bank_sel;
      frame_complete <= 1'b0;
  end
```

A frame that completes exactly on a vblank waits until the next vblank to swap. You lose at most one video refresh in that rare alignment case, but you avoid consuming the event before the render FSM observes the pending completion.

### Fix 2: edge-trigger `RS_RENDER`'s exit, not level

```diff
  RS_RENDER: begin
-     if (frame_done) begin
+     if (frame_done_rise) begin
          render_state <= RS_WAIT_SWAP;
      end
  end
```

Removes the stale-level trap.

> "This two-line conceptual fix may already make the MR=16 hang disappear."

## Recommended robustness fixes (do after the first build is verified)

### Make `RS_WAIT_SWAP` recover

```verilog
RS_WAIT_SWAP: begin
    if (vblank_rise) begin
        if (view_changed || settings_changed || need_rerender || benchmark_active) begin
            start_render  <= 1'b1;
            need_rerender <= 1'b0;
            render_state  <= RS_RENDER;
        end else begin
            render_state <= RS_IDLE;
        end
    end
end
```

The bank-swap is independently guarded by `frame_complete` so this doesn't force an invalid swap. Just prevents `RS_WAIT_SWAP && !frame_complete` from being absorbing.

### Armed edge detector for `frame_done`

```verilog
reg done_armed;
wire frame_done_event = done_armed && frame_done && !frame_done_prev;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_done_prev <= 1'b0;
        done_armed      <= 1'b0;
    end else begin
        frame_done_prev <= frame_done;
        if (start_render)         done_armed <= 1'b0;
        else if (!frame_done)     done_armed <= 1'b1;
    end
end
```

Use `frame_done_event` for both `frame_complete` set and `RS_RENDER` exit. Prevents stale level being interpreted as a new completion.

### Latch the renderer source per frame

```verilog
reg render_uses_ms;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) render_uses_ms <= 1'b0;
    else if (start_render) render_uses_ms <= ms_enable;
end
wire coord_frame_done = render_uses_ms ? rm_frame_done : cg_frame_done;
```

Same for `mr_sel` → `active_mr_sel`. Prevents S/keys from switching mid-frame.

### Hard restart on bench entry / source changes

Treat bench entry as a real restart, not a deferred rerender request:

```verilog
wire benchmark_entry = benchmark_toggle && !benchmark_active;
wire hard_restart = benchmark_entry || ms_enable_changed || mr_sel_changed;

if (hard_restart) begin
    start_render <= 1'b1;
    render_state <= RS_RENDER;
end else begin /* normal FSM */ end
```

## Decisive A/B test

```text
1. Hardwire MS enabled at reset.
2. Hardwire MR=16.
3. Press only B.
```

| Result | Meaning |
|---|---|
| Works reliably | S live-switching is implicated |
| Still hangs | The frame_done_rise/vblank_rise + WAIT_SWAP race alone is sufficient |
| Fix 1 alone fixes it | Same-cycle consume race confirmed |
| Fix 2 alone fixes it | Stale-level trap confirmed |
| Force start_render on benchmark entry fixes it | FSM was stuck before RM ever started |

## Refined hypothesis

The MR=16 failure is not MS recursion. The illegal state is:

```text
render_state    = RS_WAIT_SWAP
frame_complete  = 0
start_render    = 0
region_manager  = M_IDLE
```

Code allows that state because:

1. `frame_complete` can be set and cleared in the same cycle on `frame_done_rise && vblank_rise`
2. Render FSM enters `RS_WAIT_SWAP` on raw `frame_done` after the completion latch has been consumed
3. `settings_changed`, `benchmark_view_changed`, `benchmark_active` can't escape `RS_WAIT_SWAP` unless `frame_complete` is true
4. `ms_enable` live-switches the `frame_done` source, so S can make the FSM wait on RM even though the current render wasn't started by RM

Try Fix 1 + Fix 2 first. They directly target the exact `RS_WAIT_SWAP && !frame_complete` state the telemetry now shows.
