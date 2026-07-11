// Gallery pitch: p = step * 2/9, computed serially (GALLERY_DESIGN.md).
//
// The 1080p gallery frame keeps the driving modes' vertical complex
// extent (240*step over 1080 rows) with square pixels, so both axes
// use pitch p = step * 2/9 — a non-terminating binary fraction, hence
// a real multiply.  This module runs a free-running 64-cycle serial
// shift-add against the rounded constant C = round(2^62 * 2/9) and
// republishes p roughly every 64 clocks; the coord ladder latches it
// per frame (same freshness class as step_frame itself).
//
// Accuracy: |error| <= 1 ulp of the 8.56 result — sub-pixel over the
// whole frame.

module gallery_pitch #(
    parameter WIDTH = 64
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire signed [WIDTH-1:0] step,     // 8.56 fixed point
    output reg  signed [WIDTH-1:0] pitch,    // 8.56, = step * 2/9
    // Freshness: the published pitch was computed from the CURRENT
    // step.  Drops combinationally the instant step changes; rises
    // when a full pass over the new value publishes (<= 128 clk).
    // coord_generator holds a gallery frame start until this is high
    // — a POI snap changes step by ORDERS of magnitude in one cycle,
    // and a frame latched in the stale window renders at the previous
    // POI's zoom (user-visible as a wrong-zoom first paint).
    output wire                    pitch_valid
);

// C = round(2^63 * 2/9) = 0x1C71C71C71C71C72 (63 fractional bits).
// step * C is a 64x63-bit product; the pass accumulates
// step * C * 2^-62, one power of two hot — the publish step applies
// the final >>> 1 to land on step * C * 2^-63 = step * 2/9.
localparam [62:0] C = 63'h1C71C71C71C71C72;

reg  [5:0]              bit_idx;
reg  signed [WIDTH-1:0] acc;
reg  signed [WIDTH-1:0] step_l;   // latched operand for a clean pass
reg  signed [WIDTH-1:0] pitch_src; // operand the published pitch came from
reg                     published; // at least one pass has published

assign pitch_valid = published && (pitch_src == step);

// Accumulate LSB-first: each processed bit k is followed by (62-k)
// right-shifts inside the pass plus the final publish shift, giving it
// weight 2^(k-63) — so pitch = step * C * 2^-63 = step * 2/9.  Error:
// < 1 ulp of pass truncation + 0.5 ulp publish shift.  (First cut
// iterated MSB-first — the LAST bit got full weight, result was
// step * (1 + 2/9); second cut missed the 63rd shift — step * (4/9).
// Both caught by the TB's exact Python-style cross-check.)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bit_idx   <= 6'd63;
        acc       <= {WIDTH{1'b0}};
        step_l    <= {WIDTH{1'b0}};
        pitch     <= {WIDTH{1'b0}};
        pitch_src <= {WIDTH{1'b0}};
        published <= 1'b0;
    end else begin
        if (bit_idx == 6'd63) begin
            // publish previous result (final scale shift), start a new pass
            pitch     <= acc >>> 1;
            pitch_src <= step_l;
            published <= 1'b1;
            step_l    <= step;
            acc       <= {WIDTH{1'b0}};
            bit_idx   <= 6'd0;
        end else begin
            acc <= (acc >>> 1) + (C[bit_idx] ? step_l : {WIDTH{1'b0}});
            bit_idx <= bit_idx + 6'd1;
        end
    end
end

endmodule
