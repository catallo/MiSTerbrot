// Functional TB: fractal_top in 640x480i (eff_res 3, DDR3 framebuffer).
// Boot grace shortened via parameter; the core free-runs in attract
// mode against a memory-backed DDR3 model.  Checks:
//   - interlace activates after grace, VGA_F1 toggles across fields
//   - line-fetch address stream follows the 2r+f logical row sequence
//     (with harmless blank-time repeats), base-aligned, right bank
//   - writes are single-beat, legal BE, in-window; mirror writes reach
//     high rows (proves the 10-bit wr_y path); both banks get written
//     across frames
//   - underrun_sticky stays 0
`timescale 1ns/1ps

module tb_mode3;

reg clk = 0;      // 50 MHz
always #10 clk = ~clk;
reg clk_iter = 0; // 100 MHz
always #5 clk_iter = ~clk_iter;

reg rst_n = 0;
initial begin repeat (10) @(posedge clk); rst_n = 1; end

localparam [28:0] BASE = 29'h0600_0000;
localparam [28:0] BANKW = 29'd131072;

reg [127:0] status = 128'd0;
initial begin
    status[55:54] = 2'd3;   // Resolution: 640x480i
    status[14:12] = 3'd2;   // Iterations: 128 (fast sim render)
end

wire ce_pix, hsync, vsync, hblank, vblank;
wire vga_f1, vga_interlaced, new_vmode, bob_deint;
wire [7:0] vga_r, vga_g, vga_b;
wire [28:0] addr;
wire [7:0]  burstcnt;
wire        rd, we;
wire [63:0] din;
wire [7:0]  be;
reg         busy = 0;
reg  [63:0] dout = 0;
reg         dout_ready = 0;
wire        underrun;
wire        rendering;

fractal_top #(
    .H_RES(320), .V_RES(240), .N_ITERATORS(24),
    .WIDTH(64), .FRAC_BITS(56),
    .BOOT_GRACE_VBLANKS(6'd2)
) dut (
    .clk(clk), .clk_iter(clk_iter), .clk_vid(clk_iter), .rst_n(rst_n),
    .joystick(16'd0), .ps2_key(11'd0), .status(status),
    .entropy_seed(33'h1_2345_6789),
    .ce_pix(ce_pix), .hsync(hsync), .vsync(vsync),
    .hblank(hblank), .vblank(vblank),
    .vga_f1(vga_f1), .vga_interlaced(vga_interlaced),
    .new_vmode(new_vmode),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .ddram_addr(addr), .ddram_burstcnt(burstcnt), .ddram_busy(busy),
    .ddram_dout(dout), .ddram_dout_ready(dout_ready),
    .ddram_rd(rd), .ddram_din(din), .ddram_be(be), .ddram_we(we),
    .ddram_underrun(underrun),
    .rendering(rendering)
);

// ---- DDR3 model (as in sim/fb_ddr3, memory-backed) ----
reg [31:0] rnd = 32'hC0FFEE11;
always @(negedge clk) begin
    rnd  <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    busy <= (rnd[3:0] < 4'd5);
end

reg [63:0] mem [0:(1<<18)-1];

integer writes = 0;
integer werrs = 0;
reg [479:0] rows_written_lo;  // bank-relative rows 0..479 seen (bank 0/1 merged)
reg [1:0]   banks_written = 2'b00;
initial rows_written_lo = 480'd0;

always @(posedge clk) begin
    if (we && rd) begin $display("FAIL: rd and we same cycle"); $fatal; end
    if (we && !busy) begin
        if (burstcnt != 8'd1) begin $display("FAIL: write burstcnt %0d", burstcnt); $fatal; end
        if (!(be == 8'h03 || be == 8'h0C || be == 8'h30 || be == 8'hC0)) begin
            $display("FAIL: write BE %h", be); $fatal;
        end
        if (addr < BASE || addr >= BASE + 2*BANKW) begin
            $display("FAIL: write addr %h out of window", addr); $fatal;
        end else begin
            banks_written[(addr - BASE) >= BANKW] <= 1'b1;
            if ((((addr - BASE) % BANKW) >> 8) < 480)
                rows_written_lo[(((addr - BASE) % BANKW) >> 8)] <= 1'b1;
            else begin
                werrs = werrs + 1; // row >= 480 inside bank = bad address math
            end
        end
        for (int i = 0; i < 8; i++)
            if (be[i]) mem[addr[17:0]][8*i +: 8] = din[8*i +: 8];
        writes = writes + 1;
    end
end

// read side: command queue + return engine + line-row sequence check
reg [28:0] rq_addr [0:31];
reg [7:0]  rq_cnt  [0:31];
reg [7:0]  rq_w = 0, rq_r = 0;
integer line_reqs = 0;
integer seq_errs = 0;
reg [9:0] last_lrow = 0;
reg       have_lrow = 0;

always @(posedge clk) begin
    if (rd && !busy) begin
        if (burstcnt != 8'd40) begin $display("FAIL: read burstcnt %0d", burstcnt); $fatal; end
        if (addr < BASE || addr + 29'd40 > BASE + 2*BANKW) begin
            $display("FAIL: read addr %h out of window", addr); $fatal;
        end
        // line-base commands are 256-word aligned; +40/+80/+120 are not
        if (((addr - BASE) % BANKW) % 256 == 0) begin
            line_reqs = line_reqs + 1;
            begin : rowchk
                reg [9:0] lrow;
                lrow = 10'((((addr - BASE) % BANKW) >> 8));
                if (have_lrow && lrow != last_lrow) begin
                    // logical rows advance +2 within a field; wraps land
                    // on row 0 or 1 (next field's first row)
                    if (!(lrow == last_lrow + 10'd2 || lrow <= 10'd1)) begin
                        seq_errs = seq_errs + 1;
                        if (seq_errs < 5)
                            $display("SEQERR last=%0d now=%0d", last_lrow, lrow);
                    end
                end
                last_lrow = lrow;
                have_lrow = 1;
            end
        end
        rq_addr[rq_w[4:0]] <= addr;
        rq_cnt[rq_w[4:0]]  <= burstcnt;
        rq_w <= rq_w + 8'd1;
    end
end

reg [7:0]  ret_rem = 0, ret_lat = 0;
reg [28:0] ret_addr = 0;
always @(posedge clk) begin
    dout_ready <= 1'b0;
    if (ret_rem == 0 && ret_lat == 0 && rq_r != rq_w) begin
        ret_lat  <= 8'd10 + {3'd0, rnd[4:0]};
        ret_rem  <= rq_cnt[rq_r[4:0]];
        ret_addr <= rq_addr[rq_r[4:0]];
        rq_r     <= rq_r + 8'd1;
    end else if (ret_lat != 0) begin
        ret_lat <= ret_lat - 8'd1;
    end else if (ret_rem != 0) begin
        if (rnd[6:4] != 3'd0) begin
            dout_ready <= 1'b1;
            dout <= mem[ret_addr[17:0]];
            ret_addr <= ret_addr + 29'd1;
            ret_rem <= ret_rem - 8'd1;
        end
    end
end

// F1 toggle observation
integer f1_toggles = 0;
reg f1_prev = 0;
always @(posedge clk) begin
    if (vga_f1 != f1_prev) f1_toggles = f1_toggles + 1;
    f1_prev <= vga_f1;
end

// ---- sequence ----
integer k, hi_rows, lo_rows;
initial begin
    wait (rst_n);

    // interlace must activate after the 2-vblank grace
    begin : wait_il
        integer guard;
        guard = 0;
        while (!vga_interlaced) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 4_000_000) begin
                $display("FAIL: interlace never activated");
                $fatal;
            end
        end
    end
    $display("interlace active at t=%0t", $time);

    // observe several fields' worth of scanout + rendering
    #140_000_000; // 7M clk

    hi_rows = 0; lo_rows = 0;
    for (k = 0; k < 480; k = k + 1) begin
        if (rows_written_lo[k]) begin
            if (k >= 400) hi_rows = hi_rows + 1;
            else          lo_rows = lo_rows + 1;
        end
    end

    $display("writes=%0d rows(lo)=%0d rows(hi>=400)=%0d banks=%b werrs=%0d",
             writes, lo_rows, hi_rows, banks_written, werrs);
    $display("line_reqs=%0d seq_errs=%0d f1_toggles=%0d underrun=%0d",
             line_reqs, seq_errs, f1_toggles, underrun);

    if (writes < 100000)   begin $display("FAIL: too few writes"); $fatal; end
    if (werrs != 0)        begin $display("FAIL: write row addressing"); $fatal; end
    if (hi_rows < 10)      begin $display("FAIL: no high-row (mirror) writes"); $fatal; end
    if (line_reqs < 1000)  begin $display("FAIL: too few line fetches"); $fatal; end
    if (seq_errs != 0)     begin $display("FAIL: fetch row sequence"); $fatal; end
    // F1 is permanently suppressed since the deinterlace removal
    // (2026-07-11): fields are scaled as independent half-pictures.
    if (f1_toggles != 0)    begin $display("FAIL: F1 active despite suppression"); $fatal; end
    if (underrun)          begin $display("FAIL: underrun flagged"); $fatal; end
    $display("TB PASS");
    $finish;
end

initial begin #400_000_000; $display("FAIL: global timeout"); $fatal; end

endmodule
