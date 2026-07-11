// Gallery stage-3a TB: palette sequencer bit-exactness.
//
// A GOLDEN color_mapper instance runs in lockstep with the DUT's
// (same clk_vid, same control nets via hierarchical refs, same
// vblank_rise — so the internal cycling/crossfade state is identical
// every cycle).  The golden instance evaluates iter=k, escaped=1 with
// each k HELD for 8 ce ticks and sampled at hold-end — deliberately
// latency-independent, so it cannot share an alignment bug with the
// sequencer's 3-tick capture chain.  Every frame, each FB_PAL write
// from the DUT must equal the golden RGB for the same entry, and
// every sweep must deliver entry 0 (black) + entries 1..255.
`timescale 1ns/1ps

module tb_gallery_pal;

reg clk = 0;      always #10 clk = ~clk;
reg clk_iter = 0; always #5  clk_iter = ~clk_iter;
reg rst_n = 0;
initial begin repeat (10) @(posedge clk); rst_n = 1; end

reg [127:0] status = 128'd0;
initial begin
    status[56:54] = 3'd5;   // Gallery
    status[14:12] = 3'd2;   // fast render
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

always @(negedge clk) busy <= 1'b0;   // write path irrelevant here

// ---- golden color_mapper in control lockstep with the DUT's ----
wire        g_vbr = dut.vblank_rise_v;
reg  [8:0]  g_k = 9'd1;          // 1..255
reg  [2:0]  g_hold = 3'd0;       // 8 ticks per k
reg         g_running = 1'b0;
reg  [23:0] golden [0:255];
reg         golden_done = 1'b0;

wire [7:0] g_r, g_g, g_b;
color_mapper u_golden (
    .clk(clk_iter),
    .rst_n(rst_n),
    .vblank_rise(dut.u_color_mapper.vblank_rise),
    .pixel_valid_in(ce_pix),
    .iter_count({3'd0, g_k}),
    .escaped(1'b1),
    .palette_sel(dut.u_color_mapper.palette_sel),
    .cycle_enable(dut.u_color_mapper.cycle_enable),
    .cycle_speed_sel(dut.u_color_mapper.cycle_speed_sel),
    .cycle_direction(dut.u_color_mapper.cycle_direction),
    .cycle_blend_hard(dut.u_color_mapper.cycle_blend_hard),
    .cycle_band_mode(dut.u_color_mapper.cycle_band_mode),
    .palette_transition_mode(dut.u_color_mapper.palette_transition_mode),
    .pixel_valid_out(),
    .color_r(g_r), .color_g(g_g), .color_b(g_b)
);

// ---- DUT palette write recording (per frame) ----
reg [23:0] dutpal [0:255];
reg        dutpal_seen [0:255];
integer    dut_writes = 0;
integer    frames_compared = 0, pal_errs = 0, count_errs = 0;
reg        armed = 0;   // gallery active at last vblank edge

integer k;
always @(posedge clk_iter) if (rst_n) begin
    // golden sweep: k held 8 ticks; sample at hold-end, then advance
    if (ce_pix && g_running) begin
        if (g_hold == 3'd7) begin
            golden[g_k[7:0]] <= {g_r, g_g, g_b};   // settled >= 3 ticks ago
            if (g_k == 9'd255) begin
                g_running   <= 1'b0;
                golden_done <= 1'b1;
            end else begin
                g_k <= g_k + 9'd1;
            end
            g_hold <= 3'd0;
        end else begin
            g_hold <= g_hold + 3'd1;
        end
    end

    // DUT palette writes accumulate over the frame
    if (pal_wr) begin
        dutpal[pal_addr]      <= pal_dout;
        dutpal_seen[pal_addr] <= 1'b1;
        dut_writes            <= dut_writes + 1;
    end

    if (g_vbr) begin
        // close out the previous frame's comparison
        if (armed && golden_done) begin
            if (dut_writes != 256) begin
                count_errs = count_errs + 1;
                if (count_errs < 4)
                    $display("CNTERR frame=%0d writes=%0d", frames_compared, dut_writes);
            end
            if (!dutpal_seen[0] || dutpal[0] !== 24'h000000) begin
                pal_errs = pal_errs + 1;
                $display("PAL0ERR seen=%0d val=%h", dutpal_seen[0], dutpal[0]);
            end
            for (k = 1; k < 256; k = k + 1) begin
                if (!dutpal_seen[k] || dutpal[k] !== golden[k]) begin
                    pal_errs = pal_errs + 1;
                    if (pal_errs < 8)
                        $display("PALERR k=%0d seen=%0d dut=%h golden=%h",
                                 k, dutpal_seen[k], dutpal[k], golden[k]);
                end
            end
            frames_compared = frames_compared + 1;
        end
        // start a new lockstep frame — only at settled full fade
        // (activation clear + fade transitions scale entries down)
        armed       <= dut.gallery_v && (dut.gal_fade_scale == 6'd63);
        golden_done <= 1'b0;
        g_running   <= dut.gallery_v;
        g_k         <= 9'd1;
        g_hold      <= 3'd0;
        dut_writes  <= 0;
        for (k = 0; k < 256; k = k + 1) dutpal_seen[k] <= 1'b0;
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
    // let several compared frames accumulate (cycling phase advances
    // each frame, so misalignment cannot hide behind a static palette)
    begin : wcmp
        integer g; g = 0;
        while (frames_compared < 6) begin
            #1_000_000; g = g + 1;
            if (g > 300_000) begin
                $display("FAIL: only %0d frames compared", frames_compared); $fatal;
            end
        end
    end
    $display("frames=%0d pal_errs=%0d count_errs=%0d",
             frames_compared, pal_errs, count_errs);
    if (pal_errs != 0)   begin $display("FAIL: palette mismatch vs golden"); $fatal; end
    if (count_errs != 0) begin $display("FAIL: sweep write count"); $fatal; end
    $display("TB PASS");
    $finish;
end
initial begin #400_000_000; $display("FAIL: global timeout"); $fatal; end
endmodule
