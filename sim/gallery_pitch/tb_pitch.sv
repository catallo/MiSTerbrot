`timescale 1ns/1ps
module tb_pitch;
reg clk=0; always #5 clk=~clk;
reg rst_n=0; initial begin repeat(4) @(posedge clk); rst_n=1; end
reg  signed [63:0] step;
wire signed [63:0] pitch;
wire pitch_valid;
gallery_pitch dut(.clk(clk), .rst_n(rst_n), .step(step), .pitch(pitch),
                  .pitch_valid(pitch_valid));
integer i, errs = 0;
reg signed [63:0] expect_p;
reg [63:0] rnd = 64'h0123456789ABCDEF;
integer vw;
task check(input signed [63:0] s, input signed [63:0] e);
    begin
        step = s;
        @(posedge clk);
        // valid must drop immediately on a step change (unless the
        // value happens to be identical) and rise within 2 passes;
        // at the rise the published pitch must already be correct.
        vw = 0;
        while (!pitch_valid && vw >= 0) begin
            @(posedge clk); vw = vw + 1;
            if (vw > 140) begin
                errs = errs + 1;
                $display("ERR step=%h pitch_valid never rose", s);
                vw = -1;
            end
        end
        if ((pitch > e + 2) || (pitch < e - 2)) begin
            errs = errs + 1;
            $display("ERR step=%h pitch=%h expect=%h diff=%0d", s, pitch, e, pitch - e);
        end
        // valid must remain high while step is unchanged
        repeat (100) @(posedge clk);
        if (!pitch_valid) begin
            errs = errs + 1;
            $display("ERR step=%h valid dropped without step change", s);
        end
        if ((pitch > e + 2) || (pitch < e - 2)) begin
            errs = errs + 1;
            $display("ERR step=%h steady pitch=%h expect=%h", s, pitch, e);
        end
    end
endtask
initial begin
    wait(rst_n);
    // DEFAULT_STEP and a sweep of magnitudes
    check(64'sh0003333333333333, 64'sh0000B60B60B60B60);  // step*2/9
    check(64'sh0100000000000000, 64'sh0038E38E38E38E38);
    check(64'sh0000000000001000, 64'sh0000000000000390);  // tiny (deep zoom)
    check(64'sh0000000000000009, 64'sh0000000000000002);
    for (i = 0; i < 40; i = i + 1) begin
        rnd = {rnd[62:0], rnd[63]^rnd[62]^rnd[60]^rnd[59]};
        check($signed({9'd0, rnd[54:0]}),   // positive, realistic range
              $signed(({9'd0, rnd[54:0]} * 64'd2) / 64'd9));
    end
    if (errs) begin $display("TB FAIL: %0d errors", errs); $fatal; end
    $display("TB PASS");
    $finish;
end
endmodule
