// DDR3 framebuffer adapter for 640x480 modes (Track B).
//
// Replaces the BRAM framebuffer banks for resolutions that no longer
// fit on-chip.  Same conceptual contract as framebuffer.v: two banks,
// whole-frame swap, 9-bit {escaped, iter[7:0]} pixels — but the pixel
// store lives in DDR3 (via the emu DDRAM_* port / f2sdram) and the
// display path reads a BRAM line buffer that is prefetched one line
// ahead, so scanout NEVER touches DDR3 directly.
//
// Memory map (silicon-probed 2026-07-09, see docs/TRACKB_DESIGN.md):
//   byte 0x3000_0000 (word 0x0600_0000), 16-bit pixel words
//   {7'b0, escaped, iter[7:0]}, row stride 2048 bytes (256 words),
//   bank stride 1 MB.  A 640-px row = 160 x 64-bit beats, fetched as
//   BURSTS_PER_LINE pipelined bursts.
//
// Write path: single-clock FIFO -> single-beat 64-bit writes with
// 2-of-8 byte enables.  The probe measured 48.2 M such writes/s
// against a <=15 M/s worst-case need, so no coalescing.  wr_ready
// deasserts with headroom; the render side must stall dispatch on it.
//
// Read path: line_req(row) toggles the ping-pong target and bursts
// logical row `line_row` of the DISPLAY bank (~render_bank) into it;
// the rd_x port reads the OTHER (last completed) line with 1-cycle
// latency, mirroring BRAM timing.  A line_req while the previous
// fetch is still running sets underrun_sticky (permanent diagnostic,
// the 64 us budget has 16x margin so this must never fire).
//
// Request protocol: the display view rotates ON line_req, so the
// caller issues exactly one req per displayed line, one line ahead,
// at the hblank preceding that line's display — including the wrap
// req (row 0 of the next field) at the last line, which is what
// rotates the final row into view.  The req stream never stops while
// scanout runs.
//
// Everything runs in clk (= clk_sys = DDRAM_CLK, 50 MHz).

module fb_ddr3 #(
    parameter [28:0] BASE_WORD  = 29'h0600_0000, // byte 0x3000_0000
    parameter [28:0] BANK_WORDS = 29'd131072,    // 1 MB bank stride
    parameter        FIFO_AW    = 8              // 256-deep write FIFO
)(
    input  wire        clk,             // clk_sys: Avalon engine, FIFO, fetch
    input  wire        clk_vid,         // 100 MHz video domain: display reads
    input  wire        rst_n,

    // render write port (targets bank render_bank), clk domain
    input  wire        wr_en,
    input  wire [10:0] wr_x,
    input  wire [9:0]  wr_y,
    input  wire [8:0]  wr_data,
    input  wire        render_bank,
    output wire        wr_ready,        // stall dispatch when low
    output wire        wr_idle,         // FIFO empty, nothing in flight

    // display line port (reads bank ~render_bank), clk_vid domain.
    // line_req/line_row cross into clk (toggle sync; line_row follows
    // the project CDC contract: stable from req until the next req,
    // >=2 destination clocks before the synced strobe fires).
    input  wire        line_req,        // pulse; row into ping-pong buffer
    input  wire [9:0]  line_row,        // logical row 0..479
    output reg         line_busy,       // high while the fetch runs (clk)
    input  wire [9:0]  rd_x,            // 0..639, last completed line
    output reg  [8:0]  rd_data,         // 1-cycle sync read
    output reg         underrun_sticky,

    // DDRAM_* (Avalon burst master, 64-bit words)
    output reg  [28:0] ddram_addr,
    output reg  [7:0]  ddram_burstcnt,
    input  wire        ddram_busy,
    input  wire [63:0] ddram_dout,
    input  wire        ddram_dout_ready,
    output reg         ddram_rd,
    output reg  [63:0] ddram_din,
    output reg  [7:0]  ddram_be,
    output reg         ddram_we
);

localparam [7:0] BURST_LEN       = 8'd40;
localparam [2:0] BURSTS_PER_LINE = 3'd4;
localparam [7:0] LINE_BEATS      = 8'd160;

// ---------------------------------------------------------------------
// Write FIFO: {bank, y, x, data} captured at push (bank swap may not
// wait for drain), address math done at issue.  MLAB-friendly async
// read of the head entry.
// ---------------------------------------------------------------------
reg [30:0] wfifo [0:(1<<FIFO_AW)-1];
reg [FIFO_AW:0] wf_wp, wf_rp;
wire [FIFO_AW:0] wf_count = wf_wp - wf_rp;
wire wf_empty = (wf_count == 0);
// Headroom of 64: after wr_ready deasserts, up to ~24 in-flight slot
// results plus mirror-FIFO drains can still arrive before the render
// side actually stalls.
assign wr_ready = (wf_count < ((1 << FIFO_AW) - 64));

always @(posedge clk) begin
    if (!rst_n) begin
        wf_wp <= 0;
    end else if (wr_en) begin
        wfifo[wf_wp[FIFO_AW-1:0]] <= {render_bank, wr_y, wr_x, wr_data};
        wf_wp <= wf_wp + 1'b1;
    end
end

wire [30:0] wf_head = wfifo[wf_rp[FIFO_AW-1:0]];
wire        wfh_bank = wf_head[30];
wire [9:0]  wfh_y    = wf_head[29:20];
wire [10:0] wfh_x    = wf_head[19:9];
wire [8:0]  wfh_d    = wf_head[8:0];
wire [28:0] wfh_addr = BASE_WORD + (wfh_bank ? BANK_WORDS : 29'd0)
                     + {11'd0, wfh_y, 8'd0} + {20'd0, wfh_x[10:2]};

assign wr_idle = wf_empty & ~ddram_we;

// ---------------------------------------------------------------------
// Line fetch request — video-domain side.
// disp_sel toggles on the raw req (display rotates immediately at line
// start, microseconds before active pixels); the fetch engine sees the
// same req a few clocks later through the toggle synchronizer.  Both
// count the same requests, so disp_sel and fetch_buf stay consistent.
// ---------------------------------------------------------------------
reg        req_tgl_v;
reg        disp_sel;
reg [9:0]  line_row_hold;   // stable until the next req (>=1 line period)

always @(posedge clk_vid or negedge rst_n) begin
    if (!rst_n) begin
        req_tgl_v     <= 1'b0;
        disp_sel      <= 1'b0;
        line_row_hold <= 10'd0;
    end else if (line_req) begin
        req_tgl_v     <= ~req_tgl_v;
        disp_sel      <= ~disp_sel;
        line_row_hold <= line_row;
    end
end

reg [2:0] req_sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) req_sync <= 3'd0;
    else        req_sync <= {req_sync[1:0], req_tgl_v};
end
wire req_pulse = req_sync[2] ^ req_sync[1];

// ---------------------------------------------------------------------
// Line fetch — clk (engine) domain
// ---------------------------------------------------------------------
reg  [28:0] fetch_addr;    // next burst address to issue
reg  [2:0]  rd_pending;    // bursts left to issue (incl. current)
reg  [7:0]  beat_cnt;      // beats received this line
reg         fetch_buf;     // ping-pong target

wire [28:0] disp_base = BASE_WORD + (render_bank ? 29'd0 : BANK_WORDS);

always @(posedge clk) begin
    if (!rst_n) begin
        rd_pending <= 3'd0;
        beat_cnt <= 8'd0;
        fetch_buf <= 1'b0;
        line_busy <= 1'b0;
        underrun_sticky <= 1'b0;
        fetch_addr <= BASE_WORD;
    end else begin
        if (req_pulse) begin
            if (line_busy) underrun_sticky <= 1'b1;
            fetch_addr <= disp_base + {11'd0, line_row_hold, 8'd0};
            rd_pending <= BURSTS_PER_LINE;
            beat_cnt <= 8'd0;
            fetch_buf <= ~fetch_buf;
            line_busy <= 1'b1;
        end else if (ddram_dout_ready && line_busy) begin
            beat_cnt <= beat_cnt + 8'd1;
            if (beat_cnt == LINE_BEATS - 8'd1)
                line_busy <= 1'b0;
        end
        // rd_pending consumed by the command engine below
        if (ddram_rd && !ddram_busy)
            rd_pending <= rd_pending - 3'd1;
    end
end

// ---------------------------------------------------------------------
// Line buffer: 2 x 160 x 36 bit (4 pixels per 64-bit beat), stored
// with a 256-word stride per buffer so {buf, beat[7:0]} indexes
// directly.  Dual-clock: written by the fetch engine (clk), read by
// the display side (clk_vid).  The halves are always disjoint —
// display reads the last completed line (~disp_sel) while the fetch
// fills the other.
// ---------------------------------------------------------------------
reg [35:0] linebuf [0:511];
reg [35:0] rd_word_r;
reg [1:0]  rd_lane_d;

always @(posedge clk) begin
    if (ddram_dout_ready && line_busy)
        linebuf[{fetch_buf, beat_cnt}] <=
            {ddram_dout[56:48], ddram_dout[40:32],
             ddram_dout[24:16], ddram_dout[8:0]};
end

always @(posedge clk_vid) begin
    rd_word_r <= linebuf[{~disp_sel, rd_x[9:2]}];
    rd_lane_d <= rd_x[1:0];
end

always @(*) begin
    case (rd_lane_d)
        2'd0: rd_data = rd_word_r[8:0];
        2'd1: rd_data = rd_word_r[17:9];
        2'd2: rd_data = rd_word_r[26:18];
        2'd3: rd_data = rd_word_r[35:27];
    endcase
end

// ---------------------------------------------------------------------
// Avalon command engine.  Line-fetch reads have absolute priority;
// the write FIFO drains otherwise.  A held (unaccepted) command is
// never retracted — Avalon requires it stable under waitrequest — so
// a pending fetch waits for the current write beat to be accepted.
// ---------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        ddram_rd <= 1'b0;
        ddram_we <= 1'b0;
        ddram_addr <= BASE_WORD;
        ddram_burstcnt <= 8'd1;
        ddram_be <= 8'hFF;
        ddram_din <= 64'd0;
        wf_rp <= 0;
    end else begin
        if (ddram_rd) begin
            if (!ddram_busy) begin
                if (rd_pending == 3'd1) begin
                    ddram_rd <= 1'b0;
                end else begin
                    ddram_addr <= ddram_addr + {21'd0, BURST_LEN};
                end
            end
        end else if (ddram_we) begin
            if (!ddram_busy) begin
                if (rd_pending != 3'd0 || wf_empty) begin
                    ddram_we <= 1'b0;      // yield to fetch / go idle
                end else begin
                    ddram_addr <= wfh_addr;
                    ddram_be <= 8'h03 << {wfh_x[1:0], 1'b0};
                    ddram_din <= {4{{7'd0, wfh_d}}};
                    wf_rp <= wf_rp + 1'b1;
                end
            end
        end else begin
            if (rd_pending != 3'd0) begin
                ddram_rd <= 1'b1;
                ddram_addr <= fetch_addr;
                ddram_burstcnt <= BURST_LEN;
            end else if (!wf_empty) begin
                ddram_we <= 1'b1;
                ddram_burstcnt <= 8'd1;
                ddram_addr <= wfh_addr;
                ddram_be <= 8'h03 << {wfh_x[1:0], 1'b0};
                ddram_din <= {4{{7'd0, wfh_d}}};
                wf_rp <= wf_rp + 1'b1;
            end
        end
    end
end

endmodule
