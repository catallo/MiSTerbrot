// Gallery Mode controller (docs/GALLERY_DESIGN.md).
//
// STAGE 2 (this version): the index stream now comes from the render
// pipeline (tap in fractal_top — the stage-1 diagonal-band test
// pattern proved the FB path and is gone).  This module keeps the
// bank policy and the palette source:
//   - render/display bank selection (stage 2: single buffer, live
//     view of buffer A; stage 3 adds the hidden-render + fade-flip
//     path behind the O[59] toggle)
//   - a continuously rewritten rainbow test palette (entry 0 = black)
//     — placeholder until the stage-3 sequencer runs iter=1..255
//     through the idle display color pipeline during vblank
//
// clk = clk_sys.

module gallery_ctl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gallery_en,

    // bank policy (consumed by gallery_fb)
    output wire        render_bank,
    output wire        display_bank,

    // palette source (into gallery_fb pass-through)
    output reg         pal_wr,
    output reg  [7:0]  pal_addr,
    output reg  [23:0] pal_data
);

// Stage 2: single buffer, live view of buffer A.
assign render_bank  = 1'b0;
assign display_bank = 1'b0;

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
