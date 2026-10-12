// Equivalence bench: the committed color_mapper (procedural per-pixel palette
// evaluators, module renamed color_mapper_old from `git show HEAD`) against the
// BRAM-table rewrite.  Same inputs to both; colours must match pixel for pixel
// whenever neither instance is mid-crossfade (the rewrite applies a palette
// change at the next vblank instead of immediately, so fade phases differ by
// at most one step during a fade; steady state must be bit-identical).
`timescale 1ns/1ps
module tb_cm_equiv;
reg clk = 0; always #5 clk = ~clk;
reg rst_n = 0, vblank_rise = 0, pv = 0, escaped = 1;
reg [11:0] iter = 0; reg [6:0] pal = 0;
reg cyc_en = 1, blend_hard = 0; reg [1:0] band = 0, dir = 0, trans = 0; reg [3:0] speed = 0;
wire vo_o, vo_n; wire [7:0] ro, go, bo, rn, gn, bn;
color_mapper_old u_old (.clk(clk), .rst_n(rst_n), .vblank_rise(vblank_rise), .pixel_valid_in(pv), .iter_count(iter), .escaped(escaped),
    .palette_sel(pal), .cycle_enable(cyc_en), .cycle_speed_sel(speed), .cycle_direction(dir), .cycle_blend_hard(blend_hard),
    .cycle_band_mode(band), .palette_transition_mode(trans), .pixel_valid_out(vo_o), .color_r(ro), .color_g(go), .color_b(bo));
color_mapper u_new (.clk(clk), .rst_n(rst_n), .vblank_rise(vblank_rise), .pixel_valid_in(pv), .iter_count(iter), .escaped(escaped),
    .palette_sel(pal), .cycle_enable(cyc_en), .cycle_speed_sel(speed), .cycle_direction(dir), .cycle_blend_hard(blend_hard),
    .cycle_band_mode(band), .palette_transition_mode(trans), .pixel_valid_out(vo_n), .color_r(rn), .color_g(gn), .color_b(bn));
integer compared = 0, mism = 0, skipped = 0;
reg filled = 0;   // tables are undefined until the first vblank fill (documented)
reg settle = 0;   // first frame after a palette change: the rewrite applies the change at the next vblank (documented)
always @(posedge clk) if (vblank_rise) filled <= 1;
wire both_steady = (u_old.fade_counter == 7'd0) && (u_new.fade_counter == 7'd0);
always @(posedge clk) if ((vo_o || vo_n) && filled && !settle) begin
    if (!both_steady) skipped = skipped + 1;
    else begin
        compared = compared + 1;
        if (vo_o !== vo_n || ro !== rn || go !== gn || bo !== bn) begin
            mism = mism + 1;
            if (mism <= 8) $display("MISMATCH pal=%0d iter=%0d old=%h%h%h new=%h%h%h", pal, iter, ro, go, bo, rn, gn, bn);
        end
    end
end
task frame; integer i; begin
    for (i = 0; i < 272; i = i + 1) begin
        iter <= (i < 256) ? i : (i*37) % 4096; escaped <= (i < 256); pv <= 1; @(posedge clk); pv <= 0; repeat (3) @(posedge clk);
    end
    repeat (20) @(posedge clk); vblank_rise <= 1; @(posedge clk); vblank_rise <= 0; repeat (1500) @(posedge clk);
end endtask
integer k, f;
reg [6:0] pals [0:9];
initial begin
    pals[0]=0; pals[1]=1; pals[2]=2; pals[3]=5; pals[4]=26; pals[5]=40; pals[6]=59; pals[7]=80; pals[8]=89; pals[9]=13;
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
    frame();  // first frame: tables undefined in the new design -> skip via fade? no: force a palette change first
    for (k = 0; k < 10; k = k + 1) begin
        pal <= pals[k]; settle <= 1; repeat (8) @(posedge clk);
        for (f = 0; f < 72; f = f + 1) begin frame(); settle <= 0; end
        if (k == 4) begin band <= 2'd1; blend_hard <= 1'b1; speed <= 4'd3; dir <= 2'd2; trans <= 2'd1; end  // Instant: every frame compared
        if (k == 7) begin band <= 2'd3; blend_hard <= 1'b0; cyc_en <= 1'b0; end
    end
    $display("compared=%0d skipped(fading)=%0d mismatches=%0d", compared, skipped, mism);
    if (mism != 0 || compared < 100000) begin $display("FAIL"); $fatal; end
    $display("TB PASS"); $finish;
end
initial begin #400_000_000; $display("FAIL: timeout"); $fatal; end
endmodule
