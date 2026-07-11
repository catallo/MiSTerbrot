// Gallery Mode framebuffer engine (docs/GALLERY_DESIGN.md).
//
// Owns the DDRAM_* port while gallery mode is active (fb_ddr3 idles —
// the port is muxed in fractal_top) and provides:
//   - an 8-bit index write port (x 0..1919, y 0..1079) draining a FIFO
//     as single-BYTE-enable 64-bit writes, the Track-B-probed pattern
//     (48.2 M scattered writes/s against a ~2 M px frame)
//   - the framework FB configuration (FB_EN, 8bpp palette format,
//     1920x1080, stride 2048) with double-buffer FB_BASE selection
//   - the FB_PAL write port, driven by an external palette source
//     (stage 1: static test palette; stage 3: the color-pipeline
//     sequencer in fractal_top)
//
// Memory map: index buffer A at byte 0x3020_0000, B at 0x3040_0000
// (word addresses 0x0604_0000 / 0x0608_0000), stride 2048 bytes =
// 256 words -> shift-only addressing, 8 pixels per 64-bit word.
//
// Everything runs in clk (= clk_sys = DDRAM_CLK, 50 MHz).

module gallery_fb #(
    parameter [28:0] BASE_A_WORD = 29'h0604_0000, // byte 0x3020_0000
    parameter [28:0] BASE_B_WORD = 29'h0608_0000, // byte 0x3040_0000
    parameter        FIFO_AW     = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        gallery_en,      // level: gallery mode active

    // index write port (render/pattern side)
    input  wire        wr_en,
    input  wire [10:0] wr_x,            // 0..1919
    input  wire [10:0] wr_y,            // 0..1079
    input  wire [7:0]  wr_index,
    input  wire        render_bank,     // buffer being written
    output wire        wr_ready,
    output wire        wr_idle,

    // which buffer the framework displays (live render: == render_bank;
    // hidden render: == ~render_bank until the flip)
    input  wire        display_bank,

    // framework framebuffer config
    output wire        fb_en,
    output wire [4:0]  fb_format,
    output wire [11:0] fb_width,
    output wire [11:0] fb_height,
    output wire [31:0] fb_base,
    output wire [13:0] fb_stride,
    output wire        fb_force_blank,

    // palette write port (pass-through to FB_PAL_*)
    input  wire        pal_wr_in,
    input  wire [7:0]  pal_addr_in,
    input  wire [23:0] pal_data_in,
    output wire        fb_pal_clk,
    output wire [7:0]  fb_pal_addr,
    output wire [23:0] fb_pal_dout,
    output wire        fb_pal_wr,

    // DDRAM_* (Avalon burst master, 64-bit words) — muxed in the caller
    output reg  [28:0] ddram_addr,
    output reg  [7:0]  ddram_burstcnt,
    input  wire        ddram_busy,
    output reg  [63:0] ddram_din,
    output reg  [7:0]  ddram_be,
    output reg         ddram_we
);

// ---- framework FB configuration ----
assign fb_en          = gallery_en;
// [2:0] = 011: 8bpp palette-indexed (template convention); [4:3] n/a
assign fb_format      = 5'b00011;
assign fb_width       = 12'd1920;
assign fb_height      = 12'd1080;
assign fb_stride      = 14'd2048;
assign fb_base        = display_bank ? 32'h3040_0000 : 32'h3020_0000;
assign fb_force_blank = 1'b0;

// palette pass-through (ascal's pal2 port clocks on fb_pal_clk)
assign fb_pal_clk  = clk;
assign fb_pal_addr = pal_addr_in;
assign fb_pal_dout = pal_data_in;
assign fb_pal_wr   = pal_wr_in;

// ---- index write FIFO: {bank, y[10:0], x[10:0], index[7:0]} = 31 bits
reg [30:0] wfifo [0:(1<<FIFO_AW)-1];
reg [FIFO_AW:0] wf_wp, wf_rp;
wire [FIFO_AW:0] wf_count = wf_wp - wf_rp;
wire wf_empty = (wf_count == 0);
// 64-entry headroom for in-flight pipeline results after a stall
assign wr_ready = (wf_count < ((1 << FIFO_AW) - 64));
assign wr_idle  = wf_empty & ~ddram_we;

always @(posedge clk) begin
    if (!rst_n) begin
        wf_wp <= 0;
    end else if (wr_en) begin
        wfifo[wf_wp[FIFO_AW-1:0]] <= {render_bank, wr_y, wr_x, wr_index};
        wf_wp <= wf_wp + 1'b1;
    end
end

wire [30:0] wfh      = wfifo[wf_rp[FIFO_AW-1:0]];
wire        wfh_bank = wfh[30];
wire [10:0] wfh_y    = wfh[29:19];
wire [10:0] wfh_x    = wfh[18:8];
wire [7:0]  wfh_d    = wfh[7:0];
// word address = base + y*256 + x[10:3]; byte lane = x[2:0]
wire [28:0] wfh_addr = (wfh_bank ? BASE_B_WORD : BASE_A_WORD)
                     + {10'd0, wfh_y, 8'd0} + {21'd0, wfh_x[10:3]};

reg [7:0] wfh_be;
always @(*) begin
    case (wfh_x[2:0])
        3'd0: wfh_be = 8'h01;
        3'd1: wfh_be = 8'h02;
        3'd2: wfh_be = 8'h04;
        3'd3: wfh_be = 8'h08;
        3'd4: wfh_be = 8'h10;
        3'd5: wfh_be = 8'h20;
        3'd6: wfh_be = 8'h40;
        default: wfh_be = 8'h80;
    endcase
end

// ---- Avalon command engine: single-beat posted writes ----
always @(posedge clk) begin
    if (!rst_n) begin
        ddram_we <= 1'b0;
        ddram_addr <= BASE_A_WORD;
        ddram_burstcnt <= 8'd1;
        ddram_be <= 8'h01;
        ddram_din <= 64'd0;
        wf_rp <= 0;
    end else begin
        if (ddram_we) begin
            if (!ddram_busy) begin
                if (wf_empty) begin
                    ddram_we <= 1'b0;
                end else begin
                    ddram_addr <= wfh_addr;
                    ddram_be   <= wfh_be;
                    // data byte replicated across all lanes; BE picks one
                    ddram_din  <= {8{wfh_d}};
                    wf_rp <= wf_rp + 1'b1;
                end
            end
        end else if (!wf_empty) begin
            ddram_we <= 1'b1;
            ddram_burstcnt <= 8'd1;
            ddram_addr <= wfh_addr;
            ddram_be   <= wfh_be;
            ddram_din  <= {8{wfh_d}};
            wf_rp <= wf_rp + 1'b1;
        end
    end
end

endmodule
