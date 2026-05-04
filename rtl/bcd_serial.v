//============================================================================
// Serial Binary→BCD converter (double-dabble)
//
// Converts a BIN_W-bit binary value to 4 BCD digits over BIN_W+2 cycles.
// Continuously re-runs: every BIN_W+2 clocks, captures the current bin_in
// and produces a fresh set of BCD digits. This replaces a combinational
// constant-divider tree (one /1000, /100, /10 chain plus %10 modulos),
// which on a 14-bit input synthesizes to ~19 ns of LPM_divide logic —
// the design's worst-case clk_sys path.
//
// The conversion only needs to update once per frame for coordinate
// display; (BIN_W+2)/clk_freq is far faster than that.
//============================================================================

module bcd_serial #(
    parameter BIN_W = 14   // input is 14-bit (0..9999 after upstream clamping)
)(
    input  wire             clk,
    input  wire [BIN_W-1:0] bin_in,
    output reg  [3:0]       d3,    // thousands
    output reg  [3:0]       d2,    // hundreds
    output reg  [3:0]       d1,    // tens
    output reg  [3:0]       d0     // ones
);

localparam STEP_W = $clog2(BIN_W + 2);

reg [STEP_W-1:0]    step;
reg [BIN_W+15:0]    shift_reg;  // upper 16 bits build BCD; lower BIN_W bits feed in

initial begin
    step      = {STEP_W{1'b0}};
    shift_reg = {(BIN_W+16){1'b0}};
    d3        = 4'd0; d2 = 4'd0; d1 = 4'd0; d0 = 4'd0;
end

// Adjust: for each 4-bit BCD digit in upper bits, if ≥ 5 add 3
// (this preserves BCD validity through the next left-shift)
function [15:0] adjust_bcd16;
    input [15:0] bcd;
    begin
        adjust_bcd16[15:12] = (bcd[15:12] >= 4'd5) ? (bcd[15:12] + 4'd3) : bcd[15:12];
        adjust_bcd16[11:8]  = (bcd[11:8]  >= 4'd5) ? (bcd[11:8]  + 4'd3) : bcd[11:8];
        adjust_bcd16[7:4]   = (bcd[7:4]   >= 4'd5) ? (bcd[7:4]   + 4'd3) : bcd[7:4];
        adjust_bcd16[3:0]   = (bcd[3:0]   >= 4'd5) ? (bcd[3:0]   + 4'd3) : bcd[3:0];
    end
endfunction

always @(posedge clk) begin
    if (step == {STEP_W{1'b0}}) begin
        // Init: capture bin_in into lower bits, zero the BCD area
        shift_reg <= {16'd0, bin_in};
        step      <= step + 1'b1;
    end else if (step <= BIN_W[STEP_W-1:0]) begin
        // Adjust upper 16 bits, then shift the whole register left by 1
        shift_reg <= {adjust_bcd16(shift_reg[BIN_W+15:BIN_W]), shift_reg[BIN_W-1:0]} << 1;
        step      <= step + 1'b1;
    end else begin
        // Latch result and restart
        d3   <= shift_reg[BIN_W+15:BIN_W+12];
        d2   <= shift_reg[BIN_W+11:BIN_W+8];
        d1   <= shift_reg[BIN_W+7:BIN_W+4];
        d0   <= shift_reg[BIN_W+3:BIN_W];
        step <= {STEP_W{1'b0}};
    end
end

endmodule
