# MiSTerbrot MR=16 hang — follow-up to your diagnostic suggestions

Thanks for the previous analysis. I implemented the diagnostic ledger you suggested. The findings narrow the bug to a different place than originally suspected — possibly a race in `fractal_top.v`'s render FSM at bench-mode entry rather than `region_manager.v`. Asking for a refined hypothesis.

## What I built

Per your "single highest-value probe" suggestion, I added a per-region dispatch ledger to `region_manager.v` and surfaced the failure modes through the on-screen telemetry strip. I also added a live snapshot of slot 0's FSM state, and tracked frame_done assertions from both the pixel pipeline and region_manager.

### Diagnostic additions

In `region_manager.v`:

```verilog
reg [16:0] slot_sent     [0:N_SLOTS-1];   // accepted dispatches per slot
output reg dbg_received_overshoot;        // sticky: ever observed
                                          //   slot_received >= slot_expected
                                          //   at the time of a result_valid
output reg dbg_reached_wait;              // sticky: ever entered SL_WAIT_BD
                                          //   or SL_WAIT_FULL
output wire [3:0] dbg_slot0_state;        // live: slot[0] FSM state

// In SL_PREP: slot_sent[s] <= 17'd0;
// On accepted dispatch:
//   if ((s == disp_slot) && disp_has && coord_ready)
//       slot_sent[s] <= slot_sent[s] + 17'd1;
// In WAIT states: dbg_reached_wait <= 1'b1;
// In result router:
//   if (result_valid && slot_received[result_region_id] >= slot_expected[result_region_id])
//       dbg_received_overshoot <= 1'b1;
```

In `fractal_top.v` (sticky flags cleared on bench-mode entry):

```verilog
reg dbg_pp_frame_done_seen;  // ever seen pixel_pipeline.frame_done = 1
reg dbg_rm_frame_done_seen;  // ever seen region_manager.frame_done = 1

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dbg_pp_frame_done_seen <= 1'b0;
        dbg_rm_frame_done_seen <= 1'b0;
    end else begin
        // Clear on bench mode entry so each session starts fresh.
        if (benchmark_toggle && !benchmark_active) begin
            dbg_pp_frame_done_seen <= 1'b0;
            dbg_rm_frame_done_seen <= 1'b0;
        end
        if (frame_done)    dbg_pp_frame_done_seen <= 1'b1;  // PP frame_done
        if (rm_frame_done) dbg_rm_frame_done_seen <= 1'b1;  // RM frame_done
    end
end
```

### Strip layout (40-bit)

| Bits  | Field |
|-------|-------|
| 39:36 | magic 0xA |
| 35    | ms_enable |
| 34:33 | mr_sel |
| 32    | dbg_received_overshoot (sticky) |
| 31    | dbg_reached_wait (sticky) |
| 30:24 | scene index |
| 23:20 | dbg_slot0_state[3:0] (live) |
| 19:8  | F10 |
| 7:6   | render_state[1:0] (live: 00=IDLE, 01=RENDER, 10=WAIT_SWAP) |
| 5     | dbg_pp_frame_done_seen (sticky) |
| 4     | dbg_rm_frame_done_seen (sticky) |
| 3:0   | reserved |

Sequence to trigger MR=16: reload core, press S (force MS on), press 1 (force MR=16), press B (enter bench mode), wait 14s, screenshot.

## Findings

5 runs of MR=16 from fresh core loads:

| Run | F10 | slot0_state | render_state | overshoot | reached_wait | pp_frame_done_seen | rm_frame_done_seen |
|----:|----:|-------------|--------------|----------:|-------------:|-------------------:|-------------------:|
| 1 | 0     | IDLE     | WAIT_SWAP | 0 | 0 | 0 | 0 |
| 2 | 0     | IDLE     | WAIT_SWAP | 0 | 0 | 0 | 0 |
| 3 | 0     | IDLE     | WAIT_SWAP | 0 | 0 | 0 | 0 |
| 4 | 0     | IDLE     | WAIT_SWAP | 0 | 0 | 0 | 0 |
| 5 | 298   | FULL_OUT | WAIT_SWAP | 0 | 1 | 1 | 1 |

So MR=16 hangs with probability ~80%. When it hangs:
- No `slot_received >= slot_expected` was ever observed (the stale-result race we were initially hunting did not fire).
- Region_manager never reached `M_DONE` (rm_frame_done never asserted).
- Pixel pipeline never asserted `frame_done` (consistent with above).
- Region_manager's slot[0] is sitting in `SL_IDLE`.
- fractal_top's render FSM is sitting in `RS_WAIT_SWAP`.

When it works (run 5), all flags fire and rendering proceeds normally.

## What's puzzling

`render_state == RS_WAIT_SWAP` and `dbg_pp_frame_done_seen == 0` is *contradictory* in my mental model. The only path into `RS_WAIT_SWAP` is from `RS_RENDER` on `frame_done` being high. If `frame_done` never asserted since bench mode was entered (sticky flag is 0), how is the render FSM in `RS_WAIT_SWAP`?

Hypothesis: the FSM was in `RS_WAIT_SWAP` from the *previous* (auto-zoom) frame at the moment B was pressed. Then it never exited. The exit guard is:

```verilog
RS_WAIT_SWAP: begin
    if (vblank_rise && frame_complete) begin
        ...
    end
end
```

If `frame_complete` is 0 by the time the next vblank fires, we sit forever. `frame_complete` is set only by `frame_done_rise` (in a separate always block) and cleared on vblank+frame_complete. With no new `frame_done` events post-bench-entry (because region_manager is in `M_IDLE` waiting for `start_frame`, and `start_frame` only fires on `start_render`, and `start_render` only fires on the WAIT_SWAP exit transition), we have a chicken-and-egg deadlock.

Why would this hit MR=16 specifically (or much more often than other MRs)? Maybe MR=16 hits the timing window that triggers the race. Maybe the race depends on `ms_enable` and `mr_sel` values reaching certain logic at certain phases.

## Relevant `fractal_top.v` code

```verilog
// Render FSM states
localparam RS_IDLE      = 2'd0,
           RS_RENDER    = 2'd1,
           RS_WAIT_SWAP = 2'd2;
reg [1:0] render_state;
reg       start_render;
reg       need_rerender;

// frame_complete latch (separate always block from render FSM)
reg  frame_complete;
wire frame_done;       // from pixel_pipeline
reg  frame_done_prev;
wire frame_done_rise = frame_done & ~frame_done_prev;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        frame_complete  <= 1'b0;
        frame_done_prev <= 1'b0;
    end else begin
        frame_done_prev <= frame_done;
        if (frame_done_rise)
            frame_complete <= 1'b1;
        if (vblank_rise && (frame_complete || frame_done_rise)) begin
            bank_sel <= ~bank_sel;
            frame_complete <= 1'b0;
        end
    end
end

// view_changed source mux (in bench mode it's benchmark_view_changed,
// which pulses on B-press and on V-press while bench mode active)
wire view_changed = benchmark_active ? benchmark_view_changed :
                    auto_zoom_active ? az_view_changed : input_view_changed;

// Render FSM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        render_state  <= RS_RENDER;
        start_render  <= 1'b1;  // first frame on startup
        need_rerender <= 1'b0;
    end else begin
        start_render <= 1'b0;

        // Latch view changes during render or wait
        if ((view_changed || settings_changed) && render_state != RS_IDLE)
            need_rerender <= 1'b1;

        case (render_state)
        RS_IDLE: begin
            if (view_changed || settings_changed || need_rerender) begin
                start_render  <= 1'b1;
                need_rerender <= 1'b0;
                render_state  <= RS_RENDER;
            end
        end

        RS_RENDER: begin
            if (frame_done) begin
                render_state <= RS_WAIT_SWAP;
            end
        end

        RS_WAIT_SWAP: begin
            if (vblank_rise && frame_complete) begin
                if (view_changed || settings_changed || need_rerender ||
                    benchmark_active) begin
                    start_render  <= 1'b1;
                    need_rerender <= 1'b0;
                    render_state  <= RS_RENDER;
                end else begin
                    render_state <= RS_IDLE;
                end
            end
        end
        endcase
    end
end

// pixel_pipeline.frame_done is level-sensitive:
// assign frame_done = coord_frame_done & ~any_busy;
//   coord_frame_done = ms_enable ? rm_frame_done : cg_frame_done;
//   any_busy = OR-reduce of iter_busy[0..23];
```

## Bench mode entry flow

The bench-mode toggle is from input_handler:

```verilog
8'h32: begin // B = Toggle deterministic benchmark mode
    benchmark_toggle <= 1'b1;  // single-cycle pulse
end
```

In fractal_top:

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        benchmark_active       <= 1'b0;
        benchmark_idx          <= 0;
        benchmark_view_changed <= 1'b0;
    end else begin
        benchmark_view_changed <= 1'b0;

        if (benchmark_toggle) begin
            benchmark_active       <= ~benchmark_active;
            benchmark_view_changed <= 1'b1;  // single-cycle pulse
        end

        if (benchmark_next) begin
            benchmark_idx <= ...
            if (benchmark_active)
                benchmark_view_changed <= 1'b1;
        end
    end
end
```

So pressing B during auto-zoom:
- benchmark_toggle pulses once
- benchmark_active flips 0→1 (next cycle)
- benchmark_view_changed pulses once
- view_changed = benchmark_view_changed (since benchmark_active is now 1)

`ms_enable` was already 1 (S was pressed before B). When B sets benchmark_active, the muxes for center/step/scene parameters switch from auto-zoom to bench-scene values immediately.

## Summary of state at hang

- region_manager is in M_IDLE (no rm_frame_done has fired since bench entry → it's never been to M_DONE, which is the only state that asserts rm_frame_done=1; M_INIT_TABLES would have completed in 640 cycles).
- pixel_pipeline.frame_done has never been high since bench entry.
- fractal_top.render_state is sitting in RS_WAIT_SWAP.
- frame_complete must be 0 (otherwise we'd transition out of WAIT_SWAP on the next vblank).

For start_render to fire, we need to exit RS_WAIT_SWAP, which requires `vblank_rise && frame_complete`. For frame_complete=1, we need a `frame_done_rise`. But frame_done is gated on `coord_frame_done = rm_frame_done` (since ms_enable=1), and rm_frame_done is 0 because region_manager is in M_IDLE waiting for start_frame.

For start_frame to fire, start_render must fire. Catch-22.

## Question

What's the actual race here? My best guess:

> When B is pressed mid-WAIT_SWAP, `view_changed` pulses for one cycle. The render FSM latches `need_rerender` (per the `(view_changed || settings_changed) && render_state != RS_IDLE` check). On the next vblank, the WAIT_SWAP exit checks `vblank_rise && frame_complete`. If `frame_complete` happens to be cleared in that same cycle (by the parallel always block — `if (vblank_rise && (frame_complete || frame_done_rise))`), the WAIT_SWAP exit's read of frame_complete is its **PRE-NBA value**, which IS still 1, and we transition normally to RS_RENDER. But if `frame_complete` was cleared in some earlier cycle (by an earlier vblank that didn't fire the rerender condition because benchmark_active was still 0 at that vblank), we're already at frame_complete=0 by the time bench mode is entered. Then we sit in WAIT_SWAP forever.

But — auto-zoom mode has `view_changed` cycling regularly (target_idx changes), so the rerender condition should trigger and keep us out of permanent WAIT_SWAP.

Possible refinements:
- Is there a concrete scenario where WAIT_SWAP is entered with frame_complete already 0?
- Is the `if (frame_done) ...` check in RS_RENDER a level-sensitive trap that causes us to "transition" to WAIT_SWAP without actually ever needing frame_done_rise?
- Is there a mode-switch ordering issue between `ms_enable` going 1 (S press), `benchmark_active` going 1 (B press), and the `coord_frame_done = ms_enable ? rm_frame_done : cg_frame_done` mux output?

Specifically the last point: after S press and before B press, `coord_frame_done` is `rm_frame_done`. RM has been in M_IDLE since boot (start_frame has never fired because start_frame requires ms_enable=1 AND start_render). At the moment S is pressed, start_render hasn't fired since (or hasn't fired at all in MS mode), so RM is still in M_IDLE. coord_frame_done becomes rm_frame_done = 0. PP.frame_done = 0. The currently-rendering auto-zoom frame's frame_done suddenly drops from 1 to 0 (because the mux switched). frame_done_rise might have fired in a strange timing relative to vblank.

Could the S→B sequence be triggering something specific?

## Asks

1. Where's the deadlock in the `RS_WAIT_SWAP` / `frame_complete` / `start_render` / region_manager handshake?
2. Is the sequence S then B the trigger? (should we test B then S to compare?)
3. What's the cleanest fix that doesn't require restructuring the FSMs entirely?
