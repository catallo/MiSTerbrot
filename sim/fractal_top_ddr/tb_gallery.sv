// Gallery Mode stage-2 TB: fractal_top with eff_res=5, render tap.
// Checks:
//   - FB_EN rises after grace with the right config (stage-1 regression)
//   - every gallery_fb FIFO push carries the index-mapping law
//     (escaped ? (iter[7:0] ? iter : 1) : 0) and the pipeline's x/y
//   - every DDR3 write command matches its FIFO push exactly
//     (address, single byte lane, replicated data) — scoreboard in
//     push order, against a busy-stressed Avalon model
//   - full 1920x1080 coverage (each pixel written at least once)
//   - frame-start coordinates: cr/ci of pixel (0,0) equal
//     center - 960*pitch / center - 540*pitch + pitch/2 with the
//     latched pitch, and the published pitch is (step*2)/9 to 2 ulp
//   - no DDR3 reads; palette streams with entry 0 = black
`timescale 1ns/1ps

module tb_gallery;

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

localparam [28:0] BASE_A = 29'h0604_0000;

// randomized Avalon busy (write-side backpressure stress)
reg [31:0] rnd = 32'hC0FFEE11;
always @(negedge clk) begin
    rnd  <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    busy <= (rnd[3:0] < 4'd5);
end

// ---- scoreboard: FIFO pushes (with expected index) vs DDR writes ----
// gallery_fb preserves push order, so a ring buffer suffices.
localparam SB = 512;
reg [10:0] sb_x [0:SB-1];
reg [10:0] sb_y [0:SB-1];
reg [7:0]  sb_i [0:SB-1];
reg        sb_c [0:SB-1];   // pushed by the activation clear engine
reg        sb_b [0:SB-1];   // bank presented at push time
integer sb_w = 0, sb_r = 0;
integer clear_pushes = 0;

integer push_errs = 0, wr_errs = 0, rd_cmds = 0;
integer pal_writes = 0, pal0_black_ok = 1;
integer covered_cnt = 0;
reg covered [0:1920*1080-1];
initial for (int i = 0; i < 1920*1080; i++) covered[i] = 1'b0;

// palette stream — now clocked on clk_vid (gallery_palette taps
// color_mapper), so sample in that domain
always @(posedge clk_iter) if (rst_n) begin
    if (pal_wr) begin
        pal_writes = pal_writes + 1;
        if (pal_addr == 8'd0 && pal_dout !== 24'h000000) pal0_black_ok = 0;
    end
end

// frame-start coordinate check
reg               exp_armed = 0;
reg signed [63:0] exp_cx, exp_cy, exp_pitch, exp_step, exp_step_old;
integer coord_checks = 0, coord_errs = 0, pitch_errs = 0;

// 256-clock step delay line: the free-running pitch multiplier
// publishes with up to ~128 clocks of latency, so at a frame start the
// latched pitch may still belong to the PREVIOUS step value (attract
// zoom ticks step once per vblank).  Step changes at most once inside
// any 256-clock window, so {step_now, step_256ago} covers all sources.
reg signed [63:0] step_ring [0:255];
reg [7:0]         step_ri = 8'd0;
initial for (int i = 0; i < 256; i++) step_ring[i] = 64'sd0;

always @(posedge clk) if (rst_n) begin
    // FIFO push side: index law + x/y must match the pipeline result
    if (dut.u_gallery_fb.wr_en) begin
        automatic logic [7:0] exp_idx =
            dut.pipe_result_escaped
                ? ((dut.pipe_result_iter[7:0] != 8'd0)
                       ? dut.pipe_result_iter[7:0] : 8'd1)
                : 8'd0;
        if (dut.gal_clear_active) begin
            // activation clear: index must be 0 (both banks swept)
            clear_pushes = clear_pushes + 1;
            if (dut.u_gallery_fb.wr_index !== 8'd0) begin
                push_errs = push_errs + 1;
                if (push_errs < 5) $display("PUSHERR clear idx != 0");
            end
        end else if (dut.u_gallery_fb.wr_index !== exp_idx ||
            dut.u_gallery_fb.wr_x     !== dut.pipe_result_x ||
            dut.u_gallery_fb.wr_y     !== dut.pipe_result_y ||
            !dut.pipe_result_valid) begin
            push_errs = push_errs + 1;
            if (push_errs < 5)
                $display("PUSHERR x=%0d y=%0d idx=%h exp=%h",
                         dut.u_gallery_fb.wr_x, dut.u_gallery_fb.wr_y,
                         dut.u_gallery_fb.wr_index, exp_idx);
        end
        sb_x[sb_w % SB] = dut.u_gallery_fb.wr_x;
        sb_y[sb_w % SB] = dut.u_gallery_fb.wr_y;
        sb_i[sb_w % SB] = dut.u_gallery_fb.wr_index;
        sb_c[sb_w % SB] = dut.gal_clear_active;
        sb_b[sb_w % SB] = dut.u_gallery_fb.render_bank;
        sb_w = sb_w + 1;
        if (sb_w - sb_r > SB) begin
            $display("FAIL: scoreboard overflow sbw=%0d sbr=%0d wfcnt=%0d we=%b busy=%b clr=%b",
                     sb_w, sb_r, dut.u_gallery_fb.wf_count, we, busy, dut.gal_clear_active);
            $fatal;
        end
    end

    // DDR command side
    if (rd) rd_cmds = rd_cmds + 1;
    if (we && !busy) begin
        automatic integer lane = 0, nl = 0;
        automatic reg [28:0] eaddr;
        automatic reg [7:0]  ebe;
        for (int i = 0; i < 8; i++) if (be[i]) begin lane = i; nl = nl + 1; end
        if (sb_r >= sb_w) begin
            wr_errs = wr_errs + 1;
            if (wr_errs < 5) $display("WRERR: write with empty scoreboard");
        end else begin
            eaddr = (sb_b[sb_r % SB] ? 29'h060C_0000 : BASE_A)
                           + {10'd0, sb_y[sb_r % SB], 8'd0}
                           + {21'd0, sb_x[sb_r % SB][10:3]};
            ebe   = 8'h01 << sb_x[sb_r % SB][2:0];
            if (burstcnt !== 8'd1 || nl != 1 || addr !== eaddr || be !== ebe ||
                din[8*lane +: 8] !== sb_i[sb_r % SB]) begin
                wr_errs = wr_errs + 1;
                if (wr_errs < 5)
                    $display("WRERR addr=%h exp=%h be=%h exp=%h d=%h exp=%h",
                             addr, eaddr, be, ebe, din[8*lane +: 8], sb_i[sb_r % SB]);
            end else if (!sb_c[sb_r % SB]) begin
                // coverage counts RENDER writes only — the activation
                // clear must not satisfy the full-frame assertion
                automatic integer pix = sb_y[sb_r % SB] * 1920 + sb_x[sb_r % SB];
                if (!covered[pix]) begin
                    covered[pix] = 1'b1;
                    covered_cnt = covered_cnt + 1;
                end
            end
            sb_r = sb_r + 1;
        end
    end

    // frame-start latch capture: pre-NBA reads at this posedge see the
    // same center/pitch values coord_generator latches on this edge.
    step_ring[step_ri] = dut.step;
    step_ri = step_ri + 8'd1;
    if (dut.start_render) begin
        exp_cx       <= dut.center_x;
        exp_cy       <= dut.center_y;
        exp_pitch    <= dut.gal_pitch;
        exp_step     <= dut.step;
        exp_step_old <= step_ring[step_ri];   // oldest entry (ri wrapped)
        exp_armed    <= dut.gallery_mode;
    end

    // first coordinate of a gallery frame
    if (exp_armed && dut.cg_valid && dut.cg_px == 11'd0 && dut.cg_py == 11'd0) begin
        automatic logic signed [63:0] ecr = exp_cx - 64'sd960 * exp_pitch;
        automatic logic signed [63:0] eci = exp_cy - 64'sd540 * exp_pitch
                                                   + (exp_pitch >>> 1);
        automatic logic signed [63:0] pref  = (exp_step * 64'sd2) / 64'sd9;
        automatic logic signed [63:0] prefo = (exp_step_old * 64'sd2) / 64'sd9;
        automatic logic signed [63:0] pdiff = exp_pitch - pref;
        automatic logic signed [63:0] pdiffo = exp_pitch - prefo;
        coord_checks = coord_checks + 1;
        if (dut.cg_cr !== ecr || dut.cg_ci !== eci) begin
            coord_errs = coord_errs + 1;
            if (coord_errs < 5)
                $display("COORDERR cr=%h exp=%h ci=%h exp=%h",
                         dut.cg_cr, ecr, dut.cg_ci, eci);
        end
        if ((pdiff > 2 || pdiff < -2) && (pdiffo > 2 || pdiffo < -2)) begin
            pitch_errs = pitch_errs + 1;
            if (pitch_errs < 5)
                $display("PITCHERR pitch=%h exp=%h expold=%h",
                         exp_pitch, pref, prefo);
        end
        exp_armed <= 1'b0;   // one check per frame start
    end
end

initial begin
    wait (rst_n);
    // FB_EN must rise after the 2-vblank grace
    begin : wfb
        integer g; g = 0;
        while (!fb_en) begin @(posedge clk); g = g + 1;
            if (g > 4_000_000) begin $display("FAIL: FB_EN never rose"); $fatal; end
        end
    end
    $display("FB_EN at t=%0t  format=%b w=%0d h=%0d base=%h stride=%0d",
             $time, fb_format, fb_w, fb_h, fb_base, fb_stride);
    if (fb_format !== 5'b00011) begin $display("FAIL: format"); $fatal; end
    if (fb_w !== 12'd1920 || fb_h !== 12'd1080) begin $display("FAIL: size"); $fatal; end
    if (fb_base !== 32'h3020_0000) begin $display("FAIL: base"); $fatal; end
    if (fb_stride !== 14'd2048) begin $display("FAIL: stride"); $fatal; end

    // wait for full-frame coverage (first complete 1080p render)
    begin : wcov
        integer g; g = 0;
        while (covered_cnt < 1920*1080) begin
            #1_000_000; g = g + 1;
            if (g % 20_000 == 0)
                $display("t=%0t covered=%0d/%0d", $time, covered_cnt, 1920*1080);
            if (g > 3_000_000) begin
                $display("FAIL: coverage stalled at %0d", covered_cnt); $fatal;
            end
        end
    end
    #1_000_000;
    $display("covered=%0d push_errs=%0d wr_errs=%0d rd_cmds=%0d clear_pushes=%0d",
             covered_cnt, push_errs, wr_errs, rd_cmds, clear_pushes);
    if (clear_pushes !== 2*1920*1080) begin
        $display("FAIL: clear push count %0d", clear_pushes); $fatal;
    end
    $display("coord_checks=%0d coord_errs=%0d pitch_errs=%0d pal_writes=%0d pal0=%0d",
             coord_checks, coord_errs, pitch_errs, pal_writes, pal0_black_ok);
    if (push_errs != 0)  begin $display("FAIL: index mapping at FIFO push"); $fatal; end
    if (wr_errs != 0)    begin $display("FAIL: DDR write vs scoreboard"); $fatal; end
    if (rd_cmds != 0)    begin $display("FAIL: reads in gallery mode"); $fatal; end
    if (coord_checks == 0) begin $display("FAIL: no frame-start coord check ran"); $fatal; end
    if (coord_errs != 0) begin $display("FAIL: frame-start coordinates"); $fatal; end
    if (pitch_errs != 0) begin $display("FAIL: pitch vs (step*2)/9"); $fatal; end
    if (pal_writes < 1000) begin $display("FAIL: palette not streaming"); $fatal; end
    if (!pal0_black_ok) begin $display("FAIL: palette entry 0 not black"); $fatal; end
    if (underrun)       begin $display("FAIL: underrun flagged"); $fatal; end
    $display("TB PASS");
    $finish;
end
initial begin #3_000_000_000; $display("FAIL: global timeout"); $fatal; end
endmodule
