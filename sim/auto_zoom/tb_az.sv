// auto_zoom playlist bench: the gallery_only filter.
//
// Drives the real auto_zoom (real POI ROM / `POI_GALLERY_ONLY_MASK) through
// hundreds of N-key advances and checks:
//   fast_only = 1: no gallery_only POI is ever loaded, every other POI is,
//                  and each advance changes target_idx exactly once (no
//                  transient on target_idx / palette_idx / target_max_iter_r
//                  from a skipped candidate);
//   fast_only = 0: the gallery_only POIs come back.
//   Randomizer draws: the per-POI cycling direction covers Forward,
//   and Reverse only — never Ping-Pong (2026-10-20: OSD Direction=Auto pool).
//   no_flash_palettes = 1 (N advances and M snaps): no palette flagged in
//                  rtl/palette_flags.vh is ever drawn, every other palette
//                  is, one palette/POI change per advance (no transient);
//   no_flash_palettes = 0: the flagged palettes come back, and every draw
//                  that lands a flagged palette carries the 300-baud speed
//                  cap (rnd_cycle_speed == 2) while unflagged palettes still
//                  see the whole 300..14.4k pool (2026-10-20 speed cap).
// Build: verilator --binary --timing -Wno-fatal -Wno-WIDTH -I../../rtl --top tb_az tb_az.sv ../../rtl/auto_zoom.v
`timescale 1ns/1ps
`include "poi_generated.vh"
`include "palette_flags.vh"

module tb_az;
reg clk = 0; always #10 clk = ~clk;
reg rst_n = 0;
reg enable = 0, skip_next = 0, snap_next = 0, frame_done = 0, vblank = 0;
reg fast_only = 1;
reg no_flash = 0;

wire signed [63:0] center_x, center_y, step;
wire active, view_changed, fb_sampling;
wire [6:0] palette_idx;
wire [`POI_IDX_BITS-1:0] target_idx;
wire [11:0] target_max_iter;
wire [17:0] fb_rd_addr;
wire [3:0] rnd_cs; wire [1:0] rnd_cd, rnd_zs;

auto_zoom #(.WIDTH(64), .FRAC_BITS(56)) dut (
    .clk(clk), .rst_n(rst_n), .enable(enable), .skip_next(skip_next), .snap_next(snap_next),
    .frame_done(frame_done), .vblank(vblank), .entropy_seed(33'h1_2345_6789),
    .attract_zoom_in_enable(1'b1), .attract_zoom_out_enable(1'b1), .attract_wait_vblanks(16'd600),
    .dwell_gate(1'b1), .zoom_pacing_mode(1'b0), .zoom_speed_sel(2'd0), .randomize_enable(1'b1),
    .fast_only(fast_only), .no_flash_palettes(no_flash),
    .fb_rd_data(13'd0), .fb_rd_addr(fb_rd_addr), .fb_sampling(fb_sampling),
    .center_x(center_x), .center_y(center_y), .step(step), .active(active), .view_changed(view_changed),
    .palette_idx(palette_idx), .target_idx_out(target_idx), .target_max_iter_r(target_max_iter),
    .rnd_cycle_speed(rnd_cs), .rnd_cycle_direction(rnd_cd), .rnd_zoom_speed(rnd_zs)
);

localparam integer N = `POI_N_TARGETS;
localparam [(1<<`POI_IDX_BITS)-1:0] MASK = `POI_GALLERY_ONLY_MASK;
localparam integer ADV = 600;   // advances per phase (> 4 playlist cycles)
localparam integer NPAL = 90;
localparam [127:0] PMASK = `PAL_FLASHY_MASK;
localparam integer SNAPS = 200;

integer errors = 0, i, k, n_gonly = 0, seen_gonly, seen_fast;
reg [3:0] dir_seen = 4'b0;
reg [N-1:0] seen;
integer idx_changes, vc_pulses, mi_changes, pal_changes;
reg [6:0] pal_prev;
reg [NPAL-1:0] pseen; integer n_flashy = 0, seen_pal, seen_flashy;
reg [15:0] spd_seen_safe = 0;   // speed codes drawn with an unflagged palette
integer n_capped = 0, n_flashy_draws = 0;
reg [`POI_IDX_BITS-1:0] idx_prev; reg [11:0] mi_prev; reg counting = 0;

// Every target_idx change must be matched by exactly one view_changed pulse
// (no skipped-candidate transients), and target_max_iter_r must only move
// on the edge view_changed lands.
always @(posedge clk) begin
    if (counting) begin
        if (target_idx !== idx_prev) idx_changes = idx_changes + 1;
        if (palette_idx !== pal_prev) pal_changes = pal_changes + 1;
        if (view_changed) vc_pulses = vc_pulses + 1;
        if (target_max_iter !== mi_prev) begin
            mi_changes = mi_changes + 1;
            if (!view_changed) begin
                $display("FAIL: target_max_iter_r moved without view_changed (idx %0d)", target_idx);
                errors = errors + 1;
            end
        end
    end
    idx_prev <= target_idx; mi_prev <= target_max_iter; pal_prev <= palette_idx;
end

task snap;      // M key: snap to the next POI (from S_HOLD: S_SNAP_LOAD advance)
    begin
        @(posedge clk); snap_next <= 1; @(posedge clk); snap_next <= 0;
        repeat (120) @(posedge clk);
    end
endtask

task advance;   // N key: one playlist advance
    begin
        @(posedge clk); skip_next <= 1; @(posedge clk); skip_next <= 0;
        repeat (120) @(posedge clk);
    end
endtask

initial begin
    for (i = 0; i < N; i = i + 1) if (MASK[i]) n_gonly = n_gonly + 1;
    $display("POIs %0d, gallery_only %0d, fast %0d", N, n_gonly, N - n_gonly);
    repeat (5) @(posedge clk); rst_n = 1;
    enable = 1;
    repeat (4000) @(posedge clk);   // shuffle + first advance settle

    // ---- phase 1: fast_only = 1 ----
    seen = 0; idx_changes = 0; vc_pulses = 0; mi_changes = 0;
    idx_prev = target_idx; mi_prev = target_max_iter; counting = 1;
    if (MASK[target_idx]) begin $display("FAIL: first POI %0d is gallery_only", target_idx); errors = errors + 1; end
    seen[target_idx] = 1;
    for (k = 0; k < ADV; k = k + 1) begin
        advance;
        if (MASK[target_idx]) begin $display("FAIL: gallery_only POI %0d loaded with fast_only", target_idx); errors = errors + 1; end
        seen[target_idx] = 1;
        dir_seen[rnd_cd] = 1'b1;
        if (dut.skip_run == {`POI_IDX_BITS{1'b1}}) begin $display("FAIL: skip guard saturated"); errors = errors + 1; end
    end
    counting = 0;
    seen_fast = 0; for (i = 0; i < N; i = i + 1) if (seen[i]) seen_fast = seen_fast + 1;
    $display("fast_only=1: %0d advances, %0d distinct POIs seen (expect %0d), idx changes %0d, view_changed %0d, max_iter changes %0d",
             ADV, seen_fast, N - n_gonly, idx_changes, vc_pulses, mi_changes);
    if (seen_fast != N - n_gonly) begin $display("FAIL: not every fast POI reached"); errors = errors + 1; end
    if (idx_changes != ADV || vc_pulses != ADV) begin $display("FAIL: advance count mismatch"); errors = errors + 1; end
    $display("direction draws seen: fwd=%0d rev=%0d (pp=%0d and code 3=%0d must never appear)", dir_seen[0], dir_seen[1], dir_seen[2], dir_seen[3]);
    if (dir_seen != 4'b0011) begin $display("FAIL: direction draw pool"); errors = errors + 1; end

    // ---- phase 2: fast_only = 0 ----
    fast_only = 0;
    seen = 0; idx_changes = 0; vc_pulses = 0; mi_changes = 0;
    idx_prev = target_idx; mi_prev = target_max_iter; counting = 1;
    for (k = 0; k < ADV; k = k + 1) begin
        advance;
        seen[target_idx] = 1;
    end
    counting = 0;
    seen_gonly = 0; for (i = 0; i < N; i = i + 1) if (seen[i] && MASK[i]) seen_gonly = seen_gonly + 1;
    $display("fast_only=0: %0d advances, gallery_only POIs seen %0d (expect %0d), idx changes %0d, view_changed %0d",
             ADV, seen_gonly, n_gonly, idx_changes, vc_pulses);
    if (seen_gonly != n_gonly) begin $display("FAIL: gallery_only POIs missing with fast_only=0"); errors = errors + 1; end
    if (idx_changes != ADV || vc_pulses != ADV) begin $display("FAIL: advance count mismatch"); errors = errors + 1; end

    // ---- phase 3: no_flash_palettes = 1 (fast_only stays 0): N advances + M snaps ----
    for (i = 0; i < NPAL; i = i + 1) if (PMASK[i]) n_flashy = n_flashy + 1;
    no_flash = 1;
    advance;   // first advance under the filter lands a non-flashy palette
    pseen = 0; idx_changes = 0; vc_pulses = 0; mi_changes = 0; pal_changes = 0;
    idx_prev = target_idx; mi_prev = target_max_iter; pal_prev = palette_idx; counting = 1;
    if (PMASK[palette_idx]) begin $display("FAIL: first filtered palette %0d is flashy", palette_idx); errors = errors + 1; end
    pseen[palette_idx] = 1;
    for (k = 0; k < ADV; k = k + 1) begin
        advance;
        if (PMASK[palette_idx]) begin $display("FAIL: flashy palette %0d drawn with no_flash_palettes (N)", palette_idx); errors = errors + 1; end
        pseen[palette_idx] = 1;
        if (dut.pal_skip_run == 7'h7F) begin $display("FAIL: palette skip guard saturated"); errors = errors + 1; end
    end
    counting = 0;
    snap;      // first M from S_ZOOM_IN only snaps the depth (no advance)
    idx_prev = target_idx; mi_prev = target_max_iter; pal_prev = palette_idx; counting = 1;
    for (k = 0; k < SNAPS; k = k + 1) begin
        snap;
        if (PMASK[palette_idx]) begin $display("FAIL: flashy palette %0d drawn with no_flash_palettes (M)", palette_idx); errors = errors + 1; end
        pseen[palette_idx] = 1;
    end
    counting = 0;
    seen_pal = 0; for (i = 0; i < NPAL; i = i + 1) if (pseen[i]) seen_pal = seen_pal + 1;
    $display("no_flash=1: %0d advances + %0d snaps, %0d distinct palettes seen (expect %0d), idx changes %0d, palette changes %0d, view_changed %0d",
             ADV, SNAPS, seen_pal, NPAL - n_flashy, idx_changes, pal_changes, vc_pulses);
    if (seen_pal != NPAL - n_flashy) begin $display("FAIL: not every non-flashy palette reached"); errors = errors + 1; end
    if (idx_changes != ADV + SNAPS || vc_pulses != ADV + SNAPS || pal_changes != ADV + SNAPS) begin $display("FAIL: filtered advance count mismatch"); errors = errors + 1; end

    // ---- phase 4: no_flash_palettes = 0 ----
    no_flash = 0;
    pseen = 0;
    for (k = 0; k < ADV; k = k + 1) begin
        advance; pseen[palette_idx] = 1;
        if (PMASK[palette_idx]) begin
            n_flashy_draws = n_flashy_draws + 1;
            if (rnd_cs == 4'd2) n_capped = n_capped + 1;
            else begin $display("FAIL: flashy palette %0d drawn with speed code %0d (cap is 2 = 300 baud)", palette_idx, rnd_cs); errors = errors + 1; end
        end else begin
            spd_seen_safe[rnd_cs] = 1'b1;
            if (!(rnd_cs == 4'd0 || (rnd_cs >= 4'd2 && rnd_cs <= 4'd5))) begin
                $display("FAIL: speed code %0d outside the 300..14.4k pool", rnd_cs); errors = errors + 1; end
        end
    end
    seen_flashy = 0; for (i = 0; i < NPAL; i = i + 1) if (pseen[i] && PMASK[i]) seen_flashy = seen_flashy + 1;
    $display("no_flash=0: %0d advances, flashy palettes seen %0d (expect %0d), flashy draws %0d all capped to 300 baud (%0d), unflagged speed codes seen %b (expect 0,2,3,4,5)",
             ADV, seen_flashy, n_flashy, n_flashy_draws, n_capped, spd_seen_safe[5:0]);
    if (seen_flashy != n_flashy) begin $display("FAIL: flashy palettes missing with no_flash_palettes=0"); errors = errors + 1; end
    if (n_flashy_draws == 0 || n_capped != n_flashy_draws) begin $display("FAIL: speed cap on flagged palettes"); errors = errors + 1; end
    if (spd_seen_safe[5:0] != 6'b111101) begin $display("FAIL: unflagged palettes must see the whole speed pool"); errors = errors + 1; end

    if (errors == 0) $display("TB PASS"); else $display("TB FAIL (%0d errors)", errors);
    $finish;
end
initial begin #200_000_000; $display("FAIL: timeout"); $finish; end
endmodule
