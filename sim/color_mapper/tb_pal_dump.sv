// Dump every palette entry (90 x 256 RGB) through the real color_mapper,
// cycling off, instant transitions.  Output: "P <pal> <idx> <r> <g> <b>".
`timescale 1ns/1ps
module tb_pal_dump;
reg clk = 0; always #5 clk = ~clk;
reg rst_n = 0, vblank_rise = 0, pv = 0, escaped = 1;
reg [11:0] iter = 0; reg [6:0] pal = 0;
wire vo; wire [7:0] r, g, b;
color_mapper u (.clk(clk), .rst_n(rst_n), .vblank_rise(vblank_rise), .pixel_valid_in(pv), .iter_count(iter), .escaped(escaped),
    .palette_sel(pal), .cycle_enable(1'b0), .cycle_speed_sel(4'd0), .cycle_direction(2'd0), .cycle_blend_hard(1'b0),
    .cycle_band_mode(2'd0), .palette_transition_mode(2'd1), .pixel_valid_out(vo), .color_r(r), .color_g(g), .color_b(b));
reg [7:0] idx_q [0:63]; integer wp = 0, rp = 0;
always @(posedge clk) if (vo) begin $display("P %0d %0d %0d %0d %0d", pal, idx_q[rp[5:0]], r, g, b); rp = rp + 1; end
task vbl; begin repeat (20) @(posedge clk); vblank_rise <= 1; @(posedge clk); vblank_rise <= 0; repeat (1500) @(posedge clk); end endtask
integer p, i;
initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
    for (p = 0; p < 90; p = p + 1) begin
        pal <= p; repeat (4) @(posedge clk);
        vbl(); vbl(); vbl();
        for (i = 0; i < 256; i = i + 1) begin
            idx_q[wp[5:0]] = i; wp = wp + 1;
            iter <= i; pv <= 1; @(posedge clk); pv <= 0; repeat (7) @(posedge clk);
        end
        repeat (40) @(posedge clk);
    end
    $display("DONE"); $finish;
end
endmodule
