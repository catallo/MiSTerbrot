// Gallery Mode controller (docs/GALLERY_DESIGN.md).
//
// STAGE 1 (this version): silicon de-risk of the framework FB path.
// On gallery activation it sweeps a diagonal-band test pattern into
// index buffer A (index = (x/8 + y/8) & 0xFF) and continuously writes
// a static rainbow test palette — proving FB_EN display, 8bpp indexed
// scanout, stride/addressing and the FB_PAL path on real hardware
// before the render integration (stage 2) and the color-pipeline
// palette sequencer (stage 3) land.
//
// clk = clk_sys.

module gallery_ctl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gallery_en,

    // index write port (into gallery_fb)
    output reg         wr_en,
    output reg  [10:0] wr_x,
    output reg  [10:0] wr_y,
    output reg  [7:0]  wr_index,
    output wire        render_bank,
    output wire        display_bank,
    input  wire        wr_ready,

    // palette source (into gallery_fb pass-through)
    output reg         pal_wr,
    output reg  [7:0]  pal_addr,
    output reg  [23:0] pal_data
);

// Stage 1: single buffer, live view of buffer A.
assign render_bank  = 1'b0;
assign display_bank = 1'b0;

// ---- test pattern sweep ----
localparam [10:0] W = 11'd1920;
localparam [10:0] H = 11'd1080;

reg        swept;        // pattern written once per activation
reg        gallery_d;
// Internal scan counters are SEPARATE from the output registers:
// outputs (wr_x/wr_y/wr_index) latch the coordinate being written on
// the same edge, while px/py advance to the next pixel.  (First cut
// advanced wr_x directly and presented coordinates one pixel ahead of
// the index — visible as errors at every 8-pixel index boundary.)
reg [10:0] px, py;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_en <= 1'b0;
        wr_x <= 11'd0;
        wr_y <= 11'd0;
        wr_index <= 8'd0;
        px <= 11'd0;
        py <= 11'd0;
        swept <= 1'b0;
        gallery_d <= 1'b0;
    end else begin
        gallery_d <= gallery_en;
        wr_en <= 1'b0;
        if (gallery_en && !gallery_d) begin
            // activation edge: restart the sweep
            swept <= 1'b0;
            px <= 11'd0;
            py <= 11'd0;
        end else if (gallery_en && !swept && wr_ready) begin
            wr_en <= 1'b1;
            wr_x <= px;
            wr_y <= py;
            wr_index <= (px[10:3] + py[10:3]) & 8'hFF;
            if (px == W - 11'd1) begin
                px <= 11'd0;
                if (py == H - 11'd1) begin
                    swept <= 1'b1;
                end else begin
                    py <= py + 11'd1;
                end
            end else begin
                px <= px + 11'd1;
            end
        end
    end
end

// ---- static rainbow test palette, rewritten continuously ----
// (continuous rewrite also proves the FB_PAL path stays live — the
// stage-3 cycling sequencer will write per-frame the same way)
reg [7:0] pal_k;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pal_k <= 8'd0;
        pal_wr <= 1'b0;
        pal_addr <= 8'd0;
        pal_data <= 24'd0;
    end else begin
        pal_wr <= gallery_en;
        pal_addr <= pal_k;
        // entry 0 = black (interior); crude rainbow elsewhere
        pal_data <= (pal_k == 8'd0) ? 24'h000000
                  : {pal_k, 8'hFF - pal_k, {pal_k[3:0], pal_k[7:4]}};
        pal_k <= pal_k + 8'd1;
    end
end

endmodule
