// Gallery Mode stage-1 TB: fractal_top with eff_res=5.
// Checks: FB_EN rises after grace with the right config; the test
// pattern sweep writes exactly 1920x1080 bytes at correct addresses
// and byte lanes with the expected index values; palette writes
// stream continuously with entry 0 = black; fb_ddr3 stays silent
// (no reads, gallery owns the port).
`timescale 1ns/1ps

module tb_gallery;

reg clk = 0;      always #10 clk = ~clk;
reg clk_iter = 0; always #5  clk_iter = ~clk_iter;
reg rst_n = 0;
initial begin repeat (10) @(posedge clk); rst_n = 1; end

reg [127:0] status = 128'd0;
initial begin
    status[56:54] = 3'd5;   // Gallery
    status[14:12] = 3'd2;   // fast render (irrelevant in stage 1)
end

wire ce_pix, hsync, vsync, hblank, vblank;
wire vga_f1, vga_interlaced, vga_480p, new_vmode;
wire [7:0] vga_r, vga_g, vga_b;
wire [28:0] addr; wire [7:0] burstcnt;
wire rd, we; wire [63:0] din; wire [7:0] be;
wire underrun, rendering;
wire fb_en; wire [4:0] fb_format; wire [11:0] fb_w, fb_h;
wire [31:0] fb_base; wire [13:0] fb_stride; wire fb_blank;
wire pal_clk; wire [7:0] pal_addr; wire [23:0] pal_dout; wire pal_wr;

fractal_top #(
    .H_RES(320), .V_RES(240), .N_ITERATORS(24),
    .WIDTH(64), .FRAC_BITS(56), .BOOT_GRACE_VBLANKS(6'd2)
) dut (
    .clk(clk), .clk_iter(clk_iter), .clk_vid(clk_iter), .rst_n(rst_n),
    .joystick(16'd0), .ps2_key(11'd0), .status(status),
    .entropy_seed(33'h1_2345_6789),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync),
    .hblank(hblank), .vblank(vblank),
    .vga_f1(vga_f1), .vga_interlaced(vga_interlaced), .vga_mode_480p(vga_480p),
    .new_vmode(new_vmode),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .ddram_addr(addr), .ddram_burstcnt(burstcnt), .ddram_busy(1'b0),
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

localparam [28:0] BASE_A = 29'h0604_0000;

// write checker: count bytes, verify address/lane/index for a sample
integer wr_bytes = 0, wr_errs = 0, rd_cmds = 0;
integer pal_writes = 0, pal0_black_ok = 1;
always @(posedge clk) if (rst_n) begin
    if (rd) rd_cmds = rd_cmds + 1;
    if (we) begin
        // decode: which lane?
        integer lane, i, nl;
        reg [28:0] rel;
        reg [10:0] px, py;
        nl = 0; lane = 0;
        for (i = 0; i < 8; i = i + 1) if (be[i]) begin lane = i; nl = nl + 1; end
        if (nl != 1) begin wr_errs = wr_errs + 1; end
        else begin
            rel = addr - BASE_A;
            py = rel[18:8];
            px = {rel[7:0], 3'd0} | lane[2:0];
            if (py >= 1080 || px >= 1920) wr_errs = wr_errs + 1;
            else begin
                // expected stage-1 pattern
                if (din[8*lane +: 8] !== ((px[10:3] + py[10:3]) & 8'hFF))
                    wr_errs = wr_errs + 1;
            end
        end
        wr_bytes = wr_bytes + 1;
    end
    if (pal_wr) begin
        pal_writes = pal_writes + 1;
        if (pal_addr == 8'd0 && pal_dout !== 24'h000000) pal0_black_ok = 0;
    end
end

initial begin
    wait (rst_n);
    // FB_EN must rise after the 2-vblank grace
    begin : wfb
        integer g; g = 0;
        while (!fb_en) begin @(posedge clk); g = g + 1;
            if (g == 3_000_000)
                $display("DBG eff_res=%0d grace_done=%0d gallery=%0d bench=%0d osd_res=%0d",
                         dut.eff_res, dut.boot_grace_done, dut.gallery_mode,
                         dut.benchmark_active, dut.osd_res_mode);
            if (g > 4_000_000) begin $display("FAIL: FB_EN never rose"); $fatal; end
        end
    end
    $display("FB_EN at t=%0t  format=%b w=%0d h=%0d base=%h stride=%0d",
             $time, fb_format, fb_w, fb_h, fb_base, fb_stride);
    if (fb_format !== 5'b00011) begin $display("FAIL: format"); $fatal; end
    if (fb_w !== 12'd1920 || fb_h !== 12'd1080) begin $display("FAIL: size"); $fatal; end
    if (fb_base !== 32'h3020_0000) begin $display("FAIL: base"); $fatal; end
    if (fb_stride !== 14'd2048) begin $display("FAIL: stride"); $fatal; end

    // sweep: 2,073,600 bytes at ~1/clk -> ~42 ms sim; wait with guard
    begin : wsweep
        integer g; g = 0;
        while (wr_bytes < 1920*1080) begin
            #1_000_000; g = g + 1;
            if (g > 100_000) begin
                $display("FAIL: sweep stalled at %0d bytes", wr_bytes); $fatal;
            end
        end
    end
    #1_000_000;
    $display("bytes=%0d errs=%0d rd_cmds=%0d pal_writes=%0d pal0black=%0d",
             wr_bytes, wr_errs, rd_cmds, pal_writes, pal0_black_ok);
    if (wr_bytes !== 1920*1080) begin $display("FAIL: byte count %0d", wr_bytes); $fatal; end
    if (wr_errs != 0)  begin $display("FAIL: write addressing/data"); $fatal; end
    if (rd_cmds != 0)  begin $display("FAIL: reads in gallery mode"); $fatal; end
    if (pal_writes < 1000) begin $display("FAIL: palette not streaming"); $fatal; end
    if (!pal0_black_ok) begin $display("FAIL: palette entry 0 not black"); $fatal; end
    $display("TB PASS");
    $finish;
end
initial begin #300_000_000; $display("FAIL: timeout"); $fatal; end
endmodule
