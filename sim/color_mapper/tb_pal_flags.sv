// rtl/palette_flags.vh self-check: pal_safe_at() never returns a flagged
// palette, is the identity on unflagged ones, and the mask popcount matches
// PAL_FLASHY_COUNT (the generator's own count).
`timescale 1ns/1ps
module tb_pal_flags;
`include "palette_flags.vh"
localparam [127:0] M = `PAL_FLASHY_MASK;
integer i, n = 0, errors = 0;
reg [6:0] s;
initial begin
    for (i = 0; i < 128; i = i + 1) if (M[i]) begin
        n = n + 1;
        if (i >= 90) begin $display("FAIL: flag %0d outside the catalogue", i); errors = errors + 1; end
    end
    if (n != `PAL_FLASHY_COUNT) begin $display("FAIL: popcount %0d != %0d", n, `PAL_FLASHY_COUNT); errors = errors + 1; end
    for (i = 0; i < 90; i = i + 1) begin
        s = pal_safe_at(i[6:0]);
        if (M[s]) begin $display("FAIL: pal_safe_at(%0d) = %0d is flagged", i, s); errors = errors + 1; end
        if (!M[i] && s != i[6:0]) begin $display("FAIL: pal_safe_at(%0d) = %0d, expected identity", i, s); errors = errors + 1; end
        if (s >= 7'd90) begin $display("FAIL: pal_safe_at(%0d) = %0d out of range", i, s); errors = errors + 1; end
    end
    $display("flagged %0d palettes, %0d substitutions checked", n, 90);
    if (errors == 0) $display("TB PASS"); else $display("TB FAIL");
    $finish;
end
endmodule
