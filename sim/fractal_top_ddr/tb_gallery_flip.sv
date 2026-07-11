// Gallery stage-3b TB: hidden-render mode (O[59]=Off) fade-flip.
// Checks, with "Wait on POI" = 1 s:
//   - FB_BASE only ever changes while the palette fade is at 0
//     (tear-free flip by construction)
//   - render writes always target the NON-displayed bank; the
//     activation clear is the only writer allowed to touch both
//   - the full cycle runs twice: clear -> render -> flip #1 ->
//     fade-in -> dwell -> POI advance -> render -> fade-out ->
//     flip #2 (proves commit detection, dwell gating and repetition)
//   - fade reaches 63 between flips
`timescale 1ns/1ps

module tb_gallery_flip;

reg clk = 0;      always #10 clk = ~clk;
reg clk_iter = 0; always #5  clk_iter = ~clk_iter;
reg rst_n = 0;
initial begin repeat (10) @(posedge clk); rst_n = 1; end

reg [127:0] status = 128'd0;
initial begin
    status[56:54] = 3'd5;   // Gallery
    status[14:12] = 3'd2;   // fast render
    status[59]    = 1'b1;   // Gallery Live Render = Off (hidden + flip)
    status[35:31] = 5'd1;   // Wait on POI = 1 s
end

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
// FB_VBL model: the scaler's vblank — in silicon asynchronous to the
// core; here a delayed copy of the core vblank so the lockstep palette
// comparison keeps a stable phase relationship (sweep completes long
// before the next core vblank either way).
reg [1023:0] fb_vbl_dly = 0;
wire fb_vbl = fb_vbl_dly[1023];
always @(posedge clk_iter) fb_vbl_dly <= {fb_vbl_dly[1022:0], vblank};

fractal_top #(
    .H_RES(320), .V_RES(240), .N_ITERATORS(24),
    .WIDTH(64), .FRAC_BITS(56), .BOOT_GRACE_VBLANKS(6'd2),
    .GALLERY_MAX_ITER(12'd128)
) dut (
    .clk(clk), .clk_iter(clk_iter), .clk_vid(clk_iter), .rst_n(rst_n),
    .joystick(16'd0), .ps2_key(11'd0), .status(status),
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
    .fb_vbl_in(fb_vbl), .gal_pal_clk(pal_clk), .gal_pal_addr(pal_addr),
    .gal_pal_dout(pal_dout), .gal_pal_wr(pal_wr),
    .rendering(rendering)
);

localparam [28:0] BASE_A = 29'h0604_0000;
localparam [28:0] BASE_B = 29'h060C_0000;

reg [31:0] rnd = 32'hC0FFEE11;
always @(negedge clk) begin
    rnd  <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    busy <= (rnd[3:0] < 4'd5);
end

integer flips = 0, flip_errs = 0, bank_errs = 0;
// Atomic POI advance: after settling, each target_idx change must
// produce exactly ONE render (the combinational max_iter output used
// to leak settings_changed one cycle before view_changed — double
// render, first pass on a stale pitch).
integer renders_this_poi = 0, double_renders = 0;
reg [6:0] tidx_prev = 0;
always @(posedge clk) if (rst_n) begin
    if (dut.u_auto_zoom.target_idx_out !== tidx_prev) begin
        renders_this_poi = 0;
        tidx_prev <= dut.u_auto_zoom.target_idx_out;
    end
    if (dut.start_render && flips > 0) begin
        renders_this_poi = renders_this_poi + 1;
        if (renders_this_poi > 1) begin
            double_renders = double_renders + 1;
            $display("DOUBLERENDER poi=%0d count=%0d at t=%0t",
                     tidx_prev, renders_this_poi, $time);
        end
    end
end
integer fade63_seen_after_flip = 0;
reg [31:0] fb_base_prev = 32'h3020_0000;
reg        fade_was_63 = 0;

always @(posedge clk) if (rst_n) begin
    // flip legality: FB_BASE changes only at fade 0
    if (fb_base != fb_base_prev) begin
        flips = flips + 1;
        if (dut.gal_fade_scale != 6'd0) begin
            flip_errs = flip_errs + 1;
            $display("FLIPERR base %h->%h at fade=%0d",
                     fb_base_prev, fb_base, dut.gal_fade_scale);
        end
        $display("flip #%0d at t=%0t -> base=%h", flips, $time, fb_base);
        fade_was_63 = 0;
    end
    fb_base_prev <= fb_base;
    if (dut.gal_fade_scale == 6'd63) fade_was_63 = 1;
    if (flips > 0 && fade_was_63 && fade63_seen_after_flip < flips)
        fade63_seen_after_flip = flips;

    // render writes must land in the hidden bank (clear exempt)
    if (we && !busy && !dut.gal_clear_active && dut.gallery_mode) begin
        automatic reg wr_bank;
        automatic reg disp_bank;
        wr_bank   = (addr >= BASE_B);
        disp_bank = (fb_base == 32'h3060_0000);
        if (wr_bank == disp_bank) begin
            bank_errs = bank_errs + 1;
            if (bank_errs < 5)
                $display("BANKERR write %h while display=%h", addr, fb_base);
        end
    end
end

initial begin
    wait (rst_n);
    begin : wfb
        integer g; g = 0;
        while (!fb_en) begin @(posedge clk); g = g + 1;
            if (g > 4_000_000) begin $display("FAIL: FB_EN never rose"); $fatal; end
        end
    end
    if (fb_base !== 32'h3020_0000) begin $display("FAIL: initial base"); $fatal; end

    // wait for two flips (first POI commit, then dwell -> next POI)
    begin : wflip
        integer g; g = 0;
        while (flips < 2) begin
            #1_000_000; g = g + 1;
            if (g % 200_000 == 0)
                $display("t=%0t flips=%0d fade=%0d", $time, flips, dut.gal_fade_scale);
            if (g > 3_500_000) begin
                $display("FAIL: stuck at %0d flips", flips); $fatal;
            end
        end
    end
    // let the second fade-in settle
    begin : wfade
        integer g; g = 0;
        while (dut.gal_fade_scale != 6'd63) begin
            #1_000_000; g = g + 1;
            if (g > 1_000_000) begin $display("FAIL: fade-in stuck"); $fatal; end
        end
    end
    $display("flips=%0d flip_errs=%0d bank_errs=%0d fade63after=%0d dbl=%0d",
             flips, flip_errs, bank_errs, fade63_seen_after_flip, double_renders);
    if (double_renders != 0) begin $display("FAIL: double render per POI"); $fatal; end
    if (flip_errs != 0) begin $display("FAIL: flip at nonzero fade"); $fatal; end
    if (bank_errs != 0) begin $display("FAIL: render into displayed bank"); $fatal; end
    if (fade63_seen_after_flip < 1) begin $display("FAIL: fade never settled"); $fatal; end
    if (underrun) begin $display("FAIL: underrun"); $fatal; end
    $display("TB PASS");
    $finish;
end
initial begin #6_000_000_000; $display("FAIL: global timeout"); $fatal; end
endmodule
