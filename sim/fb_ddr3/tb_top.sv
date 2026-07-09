// TB for fb_ddr3: memory-backed Avalon slave model with randomized
// waitrequest, read latency and beat stalls.  Scenario mirrors real
// operation:
//   1. render frame A (scan order) into bank 0
//   2. swap; scan out all 480 rows of frame A (line_req pipelining,
//      concurrent display reads) WHILE frame B is written to bank 1
//      in reverse order (write/fetch interleaving on the bus)
//   3. swap; scan out frame B
// Every pixel of both frames is compared exactly; underrun_sticky
// must stay 0 and wr_ready stalls are bounded by a watchdog.
`timescale 1ns/1ps

module tb_top;

reg clk = 0;
always #10 clk = ~clk;
reg clk_vid = 0;      // 100 MHz video domain
always #5 clk_vid = ~clk_vid;

reg rst_n = 0;
initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
end

localparam [28:0] BASE = 29'h0600_0000;
localparam [28:0] BANKW = 29'd131072;

// DUT wires
reg         wr_en = 0;
reg  [10:0] wr_x;
reg  [9:0]  wr_y;
reg  [8:0]  wr_data;
reg         render_bank = 0;
wire        wr_ready, wr_idle;
reg         line_req = 0;
reg  [9:0]  line_row;
wire        line_busy;
reg  [9:0]  rd_x = 0;
wire [8:0]  rd_data;
wire        underrun_sticky;

wire [28:0] addr;
wire [7:0]  burstcnt;
wire        rd, we;
wire [63:0] din;
wire [7:0]  be;
reg         busy = 0;
reg  [63:0] dout = 0;
reg         dout_ready = 0;

fb_ddr3 dut (
    .clk(clk), .clk_vid(clk_vid), .rst_n(rst_n),
    .wr_en(wr_en), .wr_x(wr_x), .wr_y(wr_y), .wr_data(wr_data),
    .render_bank(render_bank), .wr_ready(wr_ready), .wr_idle(wr_idle),
    .line_req(line_req), .line_row(line_row), .line_busy(line_busy),
    .rd_x(rd_x), .rd_data(rd_data), .underrun_sticky(underrun_sticky),
    .ddram_addr(addr), .ddram_burstcnt(burstcnt), .ddram_busy(busy),
    .ddram_dout(dout), .ddram_dout_ready(dout_ready),
    .ddram_rd(rd), .ddram_din(din), .ddram_be(be), .ddram_we(we)
);

// deterministic randomness
reg [31:0] rnd = 32'h1234ABCD;
always @(negedge clk) begin
    rnd  <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
    busy <= (rnd[3:0] < 4'd5); // ~31% waitrequest
end

// ---- memory-backed Avalon slave ----
reg [63:0] mem [0:(1<<18)-1]; // 2 MB window

reg [7:0] wrem = 0;
reg [28:0] waddr_track;
always @(posedge clk) begin
    if (we && rd) begin $display("FAIL: rd and we simultaneously"); $fatal; end
    if (we && !busy) begin
        if (wrem == 0) begin
            if (addr < BASE || addr >= BASE + (1 << 18)) begin
                $display("FAIL: write addr %h out of window", addr); $fatal;
            end
            waddr_track = addr;
            if (burstcnt != 8'd1) wrem <= burstcnt - 8'd1;
        end else begin
            waddr_track = waddr_track + 29'd1;
            wrem <= wrem - 8'd1;
        end
        for (int i = 0; i < 8; i++)
            if (be[i]) mem[waddr_track[17:0]][8*i +: 8] = din[8*i +: 8];
    end
end

// read command queue + return engine (latency 10..41, ~12% stalls)
reg [28:0] rq_addr [0:31];
reg [7:0]  rq_cnt  [0:31];
reg [7:0]  rq_w = 0, rq_r = 0;
always @(posedge clk) begin
    if (rd && !busy) begin
        if (addr < BASE || addr + {21'd0, burstcnt} > BASE + (1 << 18)) begin
            $display("FAIL: read addr %h+%0d out of window", addr, burstcnt); $fatal;
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

// ---- expected pixel patterns ----
function [8:0] pxA(input [10:0] x, input [9:0] y);
    pxA = (9'(x) * 9'd7 + 9'(y) * 9'd13 + 9'd5) ^ {x[2:0], y[5:0]};
endfunction
function [8:0] pxB(input [10:0] x, input [9:0] y);
    pxB = (9'(x) * 9'd3 + 9'(y) * 9'd11 + 9'd77) ^ {y[2:0], x[5:0]};
endfunction

// ---- helper tasks ----
task push_pixel(input [10:0] x, input [9:0] y, input [8:0] d);
    begin
        while (!wr_ready) @(posedge clk);
        wr_en <= 1; wr_x <= x; wr_y <= y; wr_data <= d;
        @(posedge clk);
        wr_en <= 0;
        // random pacing gap ~25%
        if (rnd[9:8] == 2'd0) @(posedge clk);
    end
endtask

integer errors = 0;

task verify_line(input [9:0] row, input frameB);
    reg [8:0] exp;
    begin
        // sequential display read, 1 px / 4 video clocks (25 MHz pace)
        for (int x = 0; x < 640; x++) begin
            rd_x <= 10'(x);
            @(posedge clk_vid);
            @(posedge clk_vid);
            @(posedge clk_vid);
            @(posedge clk_vid);
            // rd_data now valid for x (1-cycle sync read)
            exp = frameB ? pxB(11'(x), row) : pxA(11'(x), row);
            if (rd_data !== exp) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("FAIL: frame %s (%0d,%0d) got %h exp %h",
                             frameB ? "B" : "A", x, row, rd_data, exp);
            end
        end
    end
endtask

reg dbg = 0;
task fetch_line(input [9:0] row);
    integer guard;
    begin
        if (dbg) $display("[%0t] req row=%0d fetch_buf(pre)=%0d busy=%0d",
                          $time, row, dut.fetch_buf, line_busy);
        @(posedge clk_vid);
        line_req <= 1; line_row <= row;
        @(posedge clk_vid);
        line_req <= 0;
    end
endtask

always @(negedge dut.line_busy)
    if (dbg) $display("[%0t] fetch done: buf=%0d beats=%0d",
                      $time, dut.fetch_buf, dut.beat_cnt);

task wait_fetch_done;
    integer guard;
    begin
        // the req crosses a toggle synchronizer into clk — wait for the
        // fetch to actually START (busy rise) before waiting for done
        guard = 0;
        while (!line_busy && guard < 32) begin
            @(posedge clk);
            guard = guard + 1;
        end
        guard = 0;
        while (line_busy) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 20000) begin $display("FAIL: fetch stuck"); $fatal; end
        end
    end
endtask

// frame B writer runs concurrently with frame A scanout
reg frameB_go = 0, frameB_done = 0;
initial begin
    wait (frameB_go);
    for (int y = 479; y >= 0; y--)
        for (int x = 639; x >= 0; x--)
            push_pixel(11'(x), 10'(y), pxB(11'(x), 10'(y)));
    frameB_done = 1;
end

// global watchdog
initial begin
    #200_000_000; // 10M cycles
    $display("FAIL: global timeout");
    $fatal;
end

// ---- main sequence ----
initial begin
    wait (rst_n);
    repeat (4) @(posedge clk);

    // 1. render frame A into bank 0
    render_bank = 0;
    for (int y = 0; y < 480; y++)
        for (int x = 0; x < 640; x++)
            push_pixel(11'(x), 10'(y), pxA(11'(x), 10'(y)));
    while (!wr_idle) @(posedge clk);

    // 2. swap: display bank 0, render bank 1; scan out frame A while
    //    frame B writes to bank 1
    render_bank = 1;
    frameB_go = 1;
    fetch_line(10'd0);
    wait_fetch_done;
    for (int r = 0; r < 480; r++) begin
        // one req per displayed line, one ahead, wrapping like a real
        // field sequence (the wrap req is what rotates row 479 into view)
        fetch_line(r < 479 ? 10'(r + 1) : 10'd0);
        verify_line(10'(r), 1'b0);
        wait_fetch_done;
    end
    $display("frame A verified, errors so far: %0d", errors);

    // 3. finish frame B, swap, verify
    wait (frameB_done);
    while (!wr_idle) @(posedge clk);
    render_bank = 0;
    fetch_line(10'd0);
    wait_fetch_done;
    for (int r = 0; r < 480; r++) begin
        fetch_line(r < 479 ? 10'(r + 1) : 10'd0); // wrap req, as in frame A
        verify_line(10'(r), 1'b1);
        wait_fetch_done;
    end
    $display("frame B verified, errors total: %0d", errors);

    if (underrun_sticky) begin $display("FAIL: underrun flagged"); $fatal; end
    if (errors != 0) begin $display("FAIL: %0d pixel errors", errors); $fatal; end
    $display("TB PASS");
    $finish;
end

endmodule
