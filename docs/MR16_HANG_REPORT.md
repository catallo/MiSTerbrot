# MiSTerbrot: Mariani-Silver hangs at MR=16 on real hardware — looking for a second opinion

## Project context

I'm building a real-time Mandelbrot core for the MiSTer FPGA platform (Terasic DE10-Nano, Intel/Altera Cyclone V `5CSEBA6U23I7`, Quartus Prime 17.0.2 Lite Edition). The core is dual-clock: `clk_sys`=50 MHz drives video/control, `clk_iter`=100 MHz runs the parallel iterator pipeline. Native 240p output, runtime-selectable 320×240 / 640×240.

The core has a recently-added Mariani-Silver (MS) interior-detection optimization implemented as a quadtree region splitter (`rtl/region_manager.v`). With MS enabled, the algorithm walks the perimeter of each rectangular region; if all boundary pixels have the same iter count and same escape status, it fills the interior without iterating; otherwise it splits into 4 children and recurses.

The minimum region dimension before forced full-dispatch (`MIN_REGION_DIM`, "MR") is selectable: 16, 32, 64, or 128 pixels. Below this threshold the region goes straight to `SL_FULL_OUT` (dispatch every pixel for iteration); at or above, the region walks its boundary and decides fill-vs-split.

## The problem

**With MS enabled and MR=16, the rendering pipeline hangs on a fresh core reload.** `frame_done` from `region_manager` never asserts. F10 (frames per 10s) stays 0. The HDMI/CRT display stays frozen on the last completed frame (the auto-zoom frame from before MS was enabled).

**MR=32, MR=64, MR=128 all render normally** when tested from a fresh core reload — typical scene 0 (P6 SUB BULB, a deep-zoom Mandelbrot view) renders at ~30 fps as expected.

The hang only happens at MR=16. It's consistent and reproducible.

A secondary observation: in multi-condition sweeps that touch MR=16 first, the subsequent MR=64 and MR=128 conditions *also* hang even though a `load_core` is issued between conditions. From an isolated cold reload, MR=64 and MR=128 work. So the hang state somehow persists across `load_core` of the same RBF — but that's a separate MiSTer-framework oddity, not the root issue.

## What I've tried

1. **Registered `min_region_dim` inside `region_manager`** (theorizing a glitchy combinational path from key-override muxes → SL_PREP comparator). This made things *worse* — MR=32 and MR=64 also started hanging, only MR=128 still worked.
2. **Multiple Quartus seeds** (5, 7, 9, 11) with `ROUTER_EFFORT_MULTIPLIER` from 2.0 to 4.0. Timing closes at +0.126 to +0.752 ns slack on `clk_iter` (100 MHz). Different seeds give different timing margins but none change MR=16's behavior.
3. **Inspected `region_manager.v` FSM** thoroughly — boundary walk pixel counts vs `slot_expected` math, stack push/pop logic, region_id routing, etc. Everything looks correct.

I'm asking for help identifying a logical or microarchitectural reason why MR=16 specifically would hang.

## Key design parameters

`region_manager` is instantiated with `N_SLOTS=1` (single region in flight) and `RID_W=1`. The full image is 640×240 (the bench scenes force `mode_640=1`).

Stack depth at peak for various MR values (verified by Python simulation of the quadtree):

| MR  | stack_peak | splits | leaves |
|----:|:----------:|:------:|:------:|
| 16  | 13         | 85     | 256    |
| 32  | 10         | 21     | 64     |
| 64  | 7          | 5      | 16     |
| 128 | 4          | 1      | 4      |

`STACK_DEPTH=64`. Not an overflow.

## Slot FSM (one slot in this build)

```
SL_IDLE → SL_PREP → { SL_FULL_OUT → SL_WAIT_FULL → SL_IDLE          (region too small to walk)
                    | SL_BD_TOP → SL_BD_RIGHT → SL_BD_BOT → SL_BD_LEFT
                                 → SL_WAIT_BD → SL_DECIDE → { SL_FILL  → SL_IDLE  (uniform → fill)
                                                            | SL_SPLIT → SL_IDLE  (non-uniform → push 4)
                                                            }
                    }
```

Wait states (`SL_WAIT_BD`, `SL_WAIT_FULL`) gate on `slot_received[s] == slot_expected[s]`. `slot_received[s]` is incremented in the result router on every `result_valid` pulse tagged with `region_id == s`. `slot_expected[s]` is set in `SL_PREP` to either `w*h` (full dispatch) or `2w+2h-4` (boundary walk).

## Critical code excerpts

### `region_manager.v` — `SL_PREP` (boundary-vs-full-dispatch decision)

```verilog
SL_PREP: begin
    slot_x_max[s]    <= slot_x0[s] + slot_w[s] - 11'd1;
    slot_y_max[s]    <= slot_y0[s] + slot_h[s] - 10'd1;
    slot_received[s] <= 17'd0;
    slot_first[s]    <= 1'b0;
    slot_min_iter[s] <= 12'd0;
    slot_max_iter[s] <= 12'd0;
    slot_unif_t[s]   <= 1'b1;
    slot_unif_f[s]   <= 1'b1;
    slot_walk_px[s]  <= slot_x0[s];
    slot_walk_py[s]  <= slot_y0[s];
    if ((slot_w[s] < {3'b0, min_region_dim}) ||
        (slot_h[s] < {2'b0, min_region_dim})) begin
        slot_expected[s] <= {6'b0, slot_w[s]} * {7'b0, slot_h[s]};
        slot_state[s]    <= SL_FULL_OUT;
    end else begin
        slot_expected[s] <= {6'b0, slot_w[s]} + {6'b0, slot_w[s]} +
                            {7'b0, slot_h[s]} + {7'b0, slot_h[s]} - 17'd4;
        slot_state[s]    <= SL_BD_TOP;
    end
end
```

### Widths

```verilog
reg [10:0] slot_x0       [0:N_SLOTS-1];   // 11 bits (0..2047, max needed 639)
reg [9:0]  slot_y0       [0:N_SLOTS-1];   // 10 bits (0..1023, max needed 239)
reg [10:0] slot_w        [0:N_SLOTS-1];   // 11 bits
reg [9:0]  slot_h        [0:N_SLOTS-1];   // 10 bits
reg [10:0] slot_x_max    [0:N_SLOTS-1];
reg [9:0]  slot_y_max    [0:N_SLOTS-1];
reg [10:0] slot_walk_px  [0:N_SLOTS-1];
reg [9:0]  slot_walk_py  [0:N_SLOTS-1];
reg [16:0] slot_received [0:N_SLOTS-1];   // 17 bits (max needed 640*240=153600 in SL_FULL_OUT)
reg [16:0] slot_expected [0:N_SLOTS-1];

reg [9:0]  stack_x0 [0:STACK_DEPTH-1];
reg [9:0]  stack_y0 [0:STACK_DEPTH-1];
reg [10:0] stack_w  [0:STACK_DEPTH-1];
reg [9:0]  stack_h  [0:STACK_DEPTH-1];
localparam SP_W = $clog2(STACK_DEPTH+1);  // 7 bits for depth 64
reg [SP_W-1:0] stack_top;
```

### Quadtree split (in `SL_SPLIT`)

```verilog
wire [10:0] split_w_a = (slot_w[split_slot] + 11'd1) >>> 1;
wire [10:0] split_w_b =  slot_w[split_slot] - split_w_a;
wire [9:0]  split_h_a = (slot_h[split_slot] + 10'd1) >>> 1;
wire [9:0]  split_h_b =  slot_h[split_slot] - split_h_a;

SL_SPLIT: begin
    if (s[RID_W-1:0] == split_slot) begin
        stack_x0[stack_top + 'd0] <= slot_x0[s][9:0];
        stack_y0[stack_top + 'd0] <= slot_y0[s];
        stack_w [stack_top + 'd0] <= split_w_a;
        stack_h [stack_top + 'd0] <= split_h_a;
        stack_x0[stack_top + 'd1] <= slot_x0[s][9:0] + split_w_a[9:0];
        stack_y0[stack_top + 'd1] <= slot_y0[s];
        stack_w [stack_top + 'd1] <= split_w_b;
        stack_h [stack_top + 'd1] <= split_h_a;
        stack_x0[stack_top + 'd2] <= slot_x0[s][9:0];
        stack_y0[stack_top + 'd2] <= slot_y0[s] + {1'b0, split_h_a[8:0]};
        stack_w [stack_top + 'd2] <= split_w_a;
        stack_h [stack_top + 'd2] <= split_h_b;
        stack_x0[stack_top + 'd3] <= slot_x0[s][9:0] + split_w_a[9:0];
        stack_y0[stack_top + 'd3] <= slot_y0[s] + {1'b0, split_h_a[8:0]};
        stack_w [stack_top + 'd3] <= split_w_b;
        stack_h [stack_top + 'd3] <= split_h_b;
        slot_state[s] <= SL_IDLE;
    end
end
```

### Pop (in `SL_IDLE`)

```verilog
SL_IDLE: begin
    if ((s[RID_W-1:0] == idle_slot) && idle_has &&
        (stack_top != {SP_W{1'b0}})) begin
        slot_x0[s]    <= {1'b0, stack_x0[stack_top - 1'b1]};
        slot_y0[s]    <=         stack_y0[stack_top - 1'b1];
        slot_w[s]     <=         stack_w [stack_top - 1'b1];
        slot_h[s]     <=         stack_h [stack_top - 1'b1];
        slot_state[s] <= SL_PREP;
    end
end
```

### Result router

```verilog
if (result_valid) begin
    slot_received[result_region_id] <= slot_received[result_region_id] + 17'd1;
    if (!slot_first[result_region_id]) begin
        slot_min_iter[result_region_id] <= result_iter;
        slot_max_iter[result_region_id] <= result_iter;
        slot_unif_t[result_region_id]   <=  result_escaped;
        slot_unif_f[result_region_id]   <= ~result_escaped;
        slot_first[result_region_id]    <= 1'b1;
    end else begin
        if (result_iter < slot_min_iter[result_region_id])
            slot_min_iter[result_region_id] <= result_iter;
        if (result_iter > slot_max_iter[result_region_id])
            slot_max_iter[result_region_id] <= result_iter;
        if (!result_escaped) slot_unif_t[result_region_id] <= 1'b0;
        if ( result_escaped) slot_unif_f[result_region_id] <= 1'b0;
    end
end
```

### Combined stack_top delta

```verilog
wire pop_will_happen  = (master_state == M_RUN) && idle_has &&
                        (stack_top != {SP_W{1'b0}});
wire push_will_happen = (master_state == M_RUN) && split_has;

// At end of always block:
if (push_will_happen && pop_will_happen)
    stack_top <= stack_top + 'd4 - 'd1;
else if (push_will_happen)
    stack_top <= stack_top + 'd4;
else if (pop_will_happen)
    stack_top <= stack_top - 'd1;
```

### Frame done

```verilog
wire all_slots_idle = &slot_is_idle;
wire frame_complete = all_slots_idle && (stack_top == {SP_W{1'b0}});

M_RUN: begin
    if (frame_complete) master_state <= M_DONE;
end

M_DONE: begin
    frame_done <= 1'b1;
    if (start_frame) begin
        frame_done    <= 1'b0;
        init_px       <= 11'd0;
        init_py       <= 10'd0;
        init_cr_accum <= cr_first;
        init_ci_accum <= ci_first;
        stack_top     <= {SP_W{1'b0}};
        master_state  <= M_INIT_TABLES;
    end
end
```

## Quadtree behavior trace at MR=16, 640×240 starting region

```
640×240 (w=640,h=240, both ≥16)        → BD walk → split into 4
    320×120 (w=320,h=120, both ≥16)    → BD walk → split into 4
        160×60 (w=160,h=60, both ≥16)  → BD walk → split into 4
            80×30 (w=80,h=30, both ≥16) → BD walk → split into 4
                40×15 (h=15<16)         → SL_FULL_OUT (40*15=600 pixels)
```

So the smallest region that enters the boundary walk is 80×30 (boundary count = 2*80+2*30-4 = 216 pixels). The smallest `SL_FULL_OUT` leaf is 40×15 (600 pixels). Nothing tiny enough to trigger an obvious off-by-one.

Compare MR=128 (which works): the 640×240 root walks its boundary (1756 pixels), splits into 4 × 320×120, and each 320×120 immediately goes `SL_FULL_OUT` (h=120 < 128). Just 1 boundary walk, 4 full-dispatch leaves.

So MR=16 has **4 levels of boundary walks** + 256 full-dispatch leaves; MR=128 has **1 boundary walk** + 4 full-dispatch leaves. The hang correlates strongly with the depth of recursion / total number of `SL_PREP → … → SL_SPLIT → SL_IDLE → SL_PREP …` transitions.

## Plausible failure modes I considered

1. **Stack overflow** — ruled out (peak 13, depth 64).
2. **Underflow in `SL_BD_LEFT` for h≤2** — possible in principle (`slot_walk_py` walks down from `y_max-1` to `y0+1`, decrementing unsigned 10-bit; if `y_max-1 < y0+1` it underflows and loops forever). But smallest BD-walk region at MR=16 is 80×30, so this can't fire.
3. **`region_id` mismatch** — `N_SLOTS=1`, `RID_W=1`, dispatch always tags 0, result tagged 0, no other slot. Out of bounds shouldn't happen.
4. **slot_received clear vs result_valid race in same always block** — same always block, both NBAs; if both fire same cycle for the same slot, "last assignment wins" (result_router runs after the per-slot FSM). But this would require a result arriving during `SL_PREP`, and `SL_WAIT_BD/FULL` only transitions to `SL_DECIDE/IDLE` when `slot_received == slot_expected` (i.e., when the pipeline has drained for this region), so no in-flight results during `SL_PREP` of a new region. Unless I'm missing a corner case.
5. **`slot_received` overshoot** — would require extra spurious results from the iter pipeline. Each dispatch produces exactly one result; result_router increments by 1 per pulse.

## Test methodology

- Press `B` keyboard to enter benchmark mode (forces scene 0 = P6 SUB BULB).
- Telemetry strip (32 4×4 colour blocks at top-left of video output) encodes `{magic 0xA, ms_enable, mr_sel, spare, scene_idx, iter_tier, F10}`. F10 = frames completed in the last 10-second window.
- Wait 12 seconds, capture screenshot, decode the strip.
- F10 > 0 = rendering is happening. F10 = 0 = nothing completed.

When MR=16 hangs, the strip's magic/ms/mr/scene/tier bits are all correct (proving the keys took effect and bench mode is active), but F10 stays 0 indefinitely.

## Question to ChatGPT Pro

**Where in this design could a hang specifically at MR=16 (but not 32/64/128) originate?**

Plausible angles I want considered:
- A logical edge case in the FSM transitions that only manifests at the deeper recursion levels MR=16 induces.
- A subtle width / signed-vs-unsigned / off-by-one error in the boundary walk or split arithmetic that activates at specific region sizes (80×30, 160×60, etc. — the ones that appear at MR=16 but not at higher MR).
- Something about how `slot_received` interacts with same-cycle pop+push or the combined `stack_top` delta when push and pop happen close together (which is more frequent at MR=16 due to many shallow splits).
- A synthesis or timing issue I haven't tested for (the design is at +0.126 to +0.7 ns slack on `clk_iter` depending on seed; the iter pipeline runs at 100 MHz).
- Anything else my inspection missed.

I want to know **what to look at next**, not necessarily a definitive fix. Specific suggestions for testbench probes, assertions to add, or specific lines to scrutinize would be ideal.

Thanks!
