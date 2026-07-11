// Gallery M-snap race TB: reproduce the silicon wedge.
//
// Observed on hardware (2 of 4 gallery entries): pressing M (snap to
// next POI) ~2 s after gallery activation — i.e. DURING the first
// post-clear render — froze the paint mid-frame permanently (buffer
// static for minutes, dispatch dead until the mode was left).
//
// This TB enters gallery, waits for the activation clear to finish
// and the first render to be mid-frame, injects an M keypress via the
// PS/2 port, and then requires that gallery index writes keep flowing
// and a full frame completes afterwards.  A wedge fails the progress
// check.
`timescale 1ns/1ps

module tb_gallery_msnap;

reg clk = 0;      always #10 clk = ~clk;
reg clk_iter = 0; always #5  clk_iter = ~clk_iter;
reg rst_n = 0;
initial begin repeat (10) @(posedge clk); rst_n = 1; end

reg [127:0] status = 128'd0;
initial begin
    status[56:54] = 3'd5;   // Gallery
    status[14:12] = 3'd2;   // fast render
end

reg [10:0] ps2 = 11'd0;

wire ce_pix, hsync, vsync, hblank, vblank;
wire vga_f1, vga_interlaced, vga_480p, new_vmode;
wire [7:0] vga_r, vga_g, vga_b;
wire [28:0] addr; wire [7:0] burstcnt;
wire rd, we; wire [63:0] din; wire [7:0] be;
reg  busy = 0;
wire underrun, rendering;
wire fb_en; wire [4:0] fb_format; wire [11:0] fb_w, fb_h;
wire [31:0] fb_base; wire [13:0] fb_stride; wire fb_blank;
wire pal_clk; wire [7:0] pal_addr; wire [23:0] pal_dout; wire pal_wr;

fractal_top #(
    .H_RES(320), .V_RES(240), .N_ITERATORS(24),
    .WIDTH(64), .FRAC_BITS(56), .BOOT_GRACE_VBLANKS(6'd2)
) dut (
    .clk(clk), .clk_iter(clk_iter), .clk_vid(clk_iter), .rst_n(rst_n),
    .joystick(16'd0), .ps2_key(ps2), .status(status),
    .entropy_seed(33'h1_2345_6789),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync),
    .hblank(hblank), .vblank(vblank),
    .vga_f1(vga_f1), .vga_interlaced(vga_interlaced), .vga_mode_480p(vga_480p),
    .new_vmode(new_vmode),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .ddram_addr(addr), .ddram_burstcnt(burstcnt), .ddram_busy(busy),
    .ddram_dout(64'd0), .ddram_dout_ready(1'b0),
    .ddram_rd(rd), .ddram_din(din), .ddram_be(be), .ddram_we(we),
    .ddram_underrun(underrun),
    .gal_fb_en(fb_en), .gal_fb_format(fb_format),
    .gal_fb_width(fb_w), .gal_fb_height(fb_h),
    .gal_fb_base(fb_base), .gal_fb_stride(fb_stride),
    .gal_fb_force_blank(fb_blank),
    .gal_pal_clk(pal_clk), .gal_pal_addr(pal_addr),
    .gal_pal_dout(pal_dout), .gal_pal_wr(pal_wr),
    .rendering(rendering)
);

reg [31:0] rnd = 32'hC0FFEE11;
always @(negedge clk) begin
    rnd  <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    busy <= (rnd[3:0] < 4'd5);
end

// progress counters
integer render_writes = 0;
always @(posedge clk) if (rst_n) begin
    if (dut.u_gallery_fb.wr_en && !dut.gal_clear_active)
        render_writes = render_writes + 1;
end

task press_m;
    begin
        ps2 <= {~ps2[10], 1'b1, 1'b0, 8'h3A};  // strobe toggle, pressed, M
        repeat (200) @(posedge clk);
        ps2 <= {~ps2[10], 1'b0, 1'b0, 8'h3A};  // release
    end
endtask

integer w0, w1;
integer stall_checks;
initial begin
    wait (rst_n);
    // wait for gallery FB
    begin : wfb
        integer g; g = 0;
        while (!fb_en) begin @(posedge clk); g = g + 1;
            if (g > 4_000_000) begin $display("FAIL: FB_EN never rose"); $fatal; end
        end
    end
    // wait for the clear to finish and the first render to be mid-frame
    begin : wmid
        integer g; g = 0;
        while (dut.gal_clear_active || render_writes < 200_000) begin
            #1_000_000; g = g + 1;
            if (g > 400_000) begin $display("FAIL: first render never started"); $fatal; end
        end
    end
    $display("first render mid-frame (%0d writes) at t=%0t — pressing M", render_writes, $time);
    press_m;

    // after M: writes must keep flowing (allow generous gaps for
    // restart latency, iterator drain and vblank waits)
    stall_checks = 0;
    begin : wprog
        integer g; g = 0;
        forever begin
            w0 = render_writes;
            #12_000_000;  // 12 ms window
            w1 = render_writes;
            if (w1 == w0) begin
                stall_checks = stall_checks + 1;
                $display("no writes in 12 ms window at t=%0t (strike %0d, total %0d)",
                         $time, stall_checks, w1);
                if (stall_checks >= 4) begin
                    $display("FAIL: dispatch wedged after M (writes frozen at %0d)", w1);
                    $display("DBG rs=%0d clear=%b wr_ready=%b wr_idle=%b cg_valid=%b pipe_ready=%b wfcnt=%0d",
                             dut.render_state, dut.gal_clear_active,
                             dut.gal_wr_ready, dut.gal_wr_idle,
                             dut.cg_valid, dut.pipe_coord_ready,
                             dut.u_gallery_fb.wf_count);
                    $fatal;
                end
            end else begin
                stall_checks = 0;
            end
            g = g + 1;
            // pass when at least ~1.2 full frames of writes happened post-M
            if (render_writes > 2_600_000) begin
                $display("TB PASS (%0d writes post-M, no wedge)", render_writes);
                $finish;
            end
            if (g > 400) begin
                $display("FAIL: timeout without enough post-M writes (%0d)", render_writes);
                $fatal;
            end
        end
    end
end
initial begin #6_000_000_000; $display("FAIL: global timeout"); $fatal; end
endmodule
