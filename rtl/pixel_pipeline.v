//============================================================================
// Pixel Pipeline — 8 iterators via 4 time-shared DSP pairs
//
// Uses iter_pair modules: 4 pairs × 2 contexts = 8 logical iterators
// sharing 12 physical 64×64 truncated multiplies (~56 DSP blocks).
// 12-bit iteration count. Round-robin dispatch and collection.
//============================================================================

module pixel_pipeline #(
    parameter N_ITERATORS = 8,
    parameter H_RES       = 320,
    parameter V_RES       = 240,
    parameter WIDTH       = 64,
    parameter FRAC_BITS   = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    start_frame,
    output wire                    frame_done,
    input  wire [1:0]              fractal_type,
    input  wire signed [WIDTH-1:0] julia_cr,
    input  wire signed [WIDTH-1:0] julia_ci,
    input  wire [11:0]             max_iter,
    input  wire signed [WIDTH-1:0] center_x,
    input  wire signed [WIDTH-1:0] center_y,
    input  wire signed [WIDTH-1:0] step,
    output reg                     result_valid,
    output reg  [10:0]             result_x,
    output reg  [9:0]              result_y,
    output reg  [11:0]             result_iter,
    output reg                     result_escaped
);

wire                    coord_valid, coord_ready;
wire [10:0]             coord_px;
wire [9:0]              coord_py;
wire signed [WIDTH-1:0] coord_cr, coord_ci;
wire                    coord_frame_done;

coord_generator #(
    .H_RES(H_RES), .V_RES(V_RES), .WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)
) u_coord_gen (
    .clk(clk), .rst_n(rst_n), .start_frame(start_frame),
    .center_x(center_x), .center_y(center_y), .step(step),
    .ready(coord_ready), .valid(coord_valid),
    .pixel_x(coord_px), .pixel_y(coord_py),
    .cr(coord_cr), .ci(coord_ci), .frame_done(coord_frame_done)
);

wire all_idle = ~(|iter_busy);
assign frame_done = coord_frame_done & all_idle;

wire [N_ITERATORS-1:0] iter_done;
wire [N_ITERATORS-1:0] iter_escaped;
reg  [N_ITERATORS-1:0] iter_start;
reg  [N_ITERATORS-1:0] iter_busy;
wire [11:0] iter_count  [0:N_ITERATORS-1];
wire signed [WIDTH-1:0] iter_mag_sq [0:N_ITERATORS-1];
reg [10:0]             iter_px [0:N_ITERATORS-1];
reg [9:0]              iter_py [0:N_ITERATORS-1];
reg signed [WIDTH-1:0] iter_cr [0:N_ITERATORS-1];
reg signed [WIDTH-1:0] iter_ci [0:N_ITERATORS-1];

genvar gp;
generate
    for (gp = 0; gp < N_ITERATORS/2; gp = gp + 1) begin : gen_pair
        iter_pair #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_pair (
            .clk(clk), .rst_n(rst_n),
            .fractal_type(fractal_type), .julia_cr(julia_cr), .julia_ci(julia_ci),
            .max_iter(max_iter),
            .start_a(iter_start[2*gp]),   .cr_a(iter_cr[2*gp]),   .ci_a(iter_ci[2*gp]),
            .done_a(iter_done[2*gp]),     .iter_count_a(iter_count[2*gp]),
            .escaped_a(iter_escaped[2*gp]), .final_mag_sq_a(iter_mag_sq[2*gp]),
            .start_b(iter_start[2*gp+1]), .cr_b(iter_cr[2*gp+1]), .ci_b(iter_ci[2*gp+1]),
            .done_b(iter_done[2*gp+1]),   .iter_count_b(iter_count[2*gp+1]),
            .escaped_b(iter_escaped[2*gp+1]), .final_mag_sq_b(iter_mag_sq[2*gp+1])
        );
    end
endgenerate

reg [$clog2(N_ITERATORS)-1:0] dispatch_idx, collect_idx;
wire dispatch_slot_free = !iter_busy[dispatch_idx];
assign coord_ready = dispatch_slot_free;

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dispatch_idx <= 0; collect_idx <= 0;
        result_valid <= 1'b0; result_x <= 11'd0; result_y <= 10'd0;
        result_iter <= 12'd0; result_escaped <= 1'b0;
        for (i = 0; i < N_ITERATORS; i = i + 1) begin
            iter_busy[i] <= 1'b0; iter_start[i] <= 1'b0;
            iter_px[i] <= 11'd0; iter_py[i] <= 10'd0;
            iter_cr[i] <= {WIDTH{1'b0}}; iter_ci[i] <= {WIDTH{1'b0}};
        end
    end else begin
        for (i = 0; i < N_ITERATORS; i = i + 1) iter_start[i] <= 1'b0;
        result_valid <= 1'b0;

        if (coord_valid && coord_ready) begin
            iter_start[dispatch_idx] <= 1'b1;
            iter_busy[dispatch_idx]  <= 1'b1;
            iter_px[dispatch_idx] <= coord_px; iter_py[dispatch_idx] <= coord_py;
            iter_cr[dispatch_idx] <= coord_cr; iter_ci[dispatch_idx] <= coord_ci;
            dispatch_idx <= (dispatch_idx == N_ITERATORS[2:0] - 3'd1) ? 3'd0 : dispatch_idx + 3'd1;
        end

        if (iter_done[collect_idx] && iter_busy[collect_idx]) begin
            result_valid <= 1'b1;
            result_x <= iter_px[collect_idx]; result_y <= iter_py[collect_idx];
            result_iter <= iter_count[collect_idx];
            result_escaped <= iter_escaped[collect_idx];
            iter_busy[collect_idx] <= 1'b0;
        end
        collect_idx <= (collect_idx == N_ITERATORS[2:0] - 3'd1) ? 3'd0 : collect_idx + 3'd1;
    end
end

endmodule
