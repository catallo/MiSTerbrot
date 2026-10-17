// Frame-time bench for pixel_pipeline (dispatch/collect + 4 iter_quads).
// Streams one 640x240 frame of coordinates in scan order at a catalogue view and
// reports clk_sys cycles to frame_done plus a checksum of every result, so a
// dispatch/collect change can be judged for speed AND bit-identity before a build.
//   +scene=N   0: P3 ISLAND z5 (shallow, fast)   1: SEAHORSE BODY z7 (mixed)
//              2: JULIA ISLANDS z4 (mixed)       3: SAT HEAD z22 (interior-bound)
//              4: ANTENNA BAND MERGE z3
`timescale 1ns/1ps
module tb_pp;
parameter NI = 64;   // iterators under test (8 quads x 8 contexts); override with verilator -GNI=<multiple of 8>
reg clk = 0, clk_iter = 0, rst_n = 0;
always #10 clk = ~clk;        // 50 MHz
// clk_iter: 130 MHz since 2026-10-15 (1300/10) — half period 3.846 ns with the
// 1ns/1ps timescale; override with -GITER_HALF_NS=<real> for other clocks.
parameter real ITER_HALF_NS = 3.846;
always #(ITER_HALF_NS) clk_iter = ~clk_iter;

// H = 240 is the 640x240 native mode (one row per step); -GH=480 models
// 640x480p (480 rows at step/2), the mode the bench runs in on the device.
parameter W = 640, H = 240;
reg         coord_valid = 0;
wire        coord_ready;
reg  [10:0] coord_px = 0, coord_py = 0;
reg  signed [63:0] coord_cr = 0, coord_ci = 0;
reg         coord_frame_done = 0;
wire        frame_done, result_valid, result_escaped;
wire [10:0] result_x, result_y;
wire [11:0] result_iter;
wire [1:0]  result_rid;
reg  [11:0] max_iter = 12'd1024;

pixel_pipeline #(.N_ITERATORS(NI)) dut (
    .clk(clk), .clk_iter(clk_iter), .rst_n(rst_n),
    .frame_done(frame_done), .max_iter(max_iter),
    .p3_precheck_enable(p3_en), .periodicity_enable(1'b1),
    .coord_valid(coord_valid), .coord_ready(coord_ready),
    .coord_px(coord_px), .coord_py(coord_py), .coord_cr(coord_cr), .coord_ci(coord_ci),
    .coord_region_id(2'd0), .coord_frame_done(coord_frame_done),
    .result_valid(result_valid), .result_x(result_x), .result_y(result_y),
    .result_iter(result_iter), .result_escaped(result_escaped), .result_region_id(result_rid)
);

// scene table (8.56 fixed point from doubles; identical before/after, exactness irrelevant)
function automatic signed [63:0] fx(input real v); fx = longint'(v * 72057594037927936.0); endfunction
localparam signed [63:0] DEFAULT_STEP = 64'sh0003333333333333;
integer scene = 1;
real cx, cy; integer zoom; reg signed [63:0] step, step_x, step_y, ci_shift, cx_raw, cy_raw;
integer p3_arg; reg p3_en = 1'b0; reg signed [63:0] step_arg;

integer results = 0, cycles = 0;
reg [63:0] chk = 0;
// +dump=<file>: one "x y iter esc" line per result, for engine-to-engine
// per-pixel diffs (tools: sort both files, compare).
integer dumpf = 0; reg [1023:0] dumpname;
initial if ($value$plusargs("dump=%s", dumpname)) dumpf = $fopen(dumpname, "w");
always @(posedge clk) if (result_valid) begin
    results = results + 1;
    if (dumpf) $fwrite(dumpf, "%0d %0d %0d %0d\n", result_x, result_y, result_iter, result_escaped);
    // order-independent: sum of per-result hashes (collect order may change)
    chk = chk + (({28'd0, result_x, result_y, result_iter, result_escaped} ^ 64'hA5A5_5A5A_C3C3_3C3C) * 64'h9E3779B97F4A7C15);
end
always @(posedge clk) if (coord_valid || !frame_done) cycles = cycles + 1;

integer x, y;
initial begin
    if (!$value$plusargs("scene=%d", scene)) scene = 1;
    // Arbitrary view: +cxraw=<hex 8.56> +cyraw=<hex 8.56> +zoom=<int> +maxiter=<int> [+p3=1]
    // (bench scenes from tools/benchmarks.json; frame time = cycles / 50 MHz).
    if ($value$plusargs("cxraw=%h", cx_raw)) scene = -1;
    case (scene)
       -1: begin
            if (!$value$plusargs("cyraw=%h", cy_raw)) cy_raw = 0;
            if (!$value$plusargs("zoom=%d", zoom)) zoom = 0;
            if (!$value$plusargs("maxiter=%d", max_iter)) max_iter = 12'd1024;
            if ($value$plusargs("p3=%d", p3_arg)) p3_en = (p3_arg != 0);
          end
        0: begin cx = -1.754877666;    cy = 0.0;          zoom = 5;  max_iter = 12'd1024; end
        1: begin cx = -0.74303;        cy = 0.126433;     zoom = 7;  max_iter = 12'd2048; end
        2: begin cx = -0.7436438886;   cy = 0.1318259043; zoom = 4;  max_iter = 12'd2048; end
        3: begin cx = -0.74364409961;  cy = 0.13182604688;zoom = 22; max_iter = 12'd1024; end
        default: begin cx = -1.5436890126920764; cy = 0.0; zoom = 3; max_iter = 12'd1024; end
    endcase
    step = DEFAULT_STEP >>> zoom;
    if (scene == -1 && $value$plusargs("stepraw=%h", step_arg)) step = step_arg;   // fractional zoom levels
    if (scene != -1) begin cx_raw = fx(cx); cy_raw = fx(cy); end
    step_y = (H == 480) ? (step >>> 1) : step;
    // Device grid (coord_generator.v): 640-wide frames halve the horizontal
    // step so they cover the same extent as 320 px, and every row is shifted
    // by half a row pitch so no row lands on ci=0.  The named scenes keep the
    // original square +-W/2*step grid (their checksums depend on it); the
    // +cxraw bench views use the device grid so frame times match hardware.
    step_x = (scene == -1 && W == 640) ? (step >>> 1) : step;
    ci_shift = (scene == -1) ? (step_y >>> 1) : 64'sd0;
    repeat (5) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);
    cycles = 0;
    for (y = 0; y < H; y = y + 1)
        for (x = 0; x < W; x = x + 1) begin
            coord_px <= x; coord_py <= y;
            coord_cr <= cx_raw + (x - W/2) * step_x;
            coord_ci <= cy_raw + (y - H/2) * step_y + ci_shift;
            coord_valid <= 1;
            @(posedge clk);
            while (!coord_ready) @(posedge clk);
        end
    coord_valid <= 0; coord_frame_done <= 1;
    while (!frame_done) @(posedge clk);
    repeat (3) @(posedge clk);   // let the last collected result land in the counters
    if (dumpf) $fclose(dumpf);
    $display("scene=%0d iterators=%0d results=%0d cycles=%0d chk=%h", scene, NI, results, cycles, chk);
    if (results != W*H) begin $display("FAIL: result count"); $fatal; end
    $finish;
end
initial begin #2_000_000_000; $display("FAIL: timeout"); $fatal; end
endmodule
