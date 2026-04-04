//============================================================================
// Mandelbrot/Julia Iterator (v0.8)
//
// Fixed-point arithmetic: 8.56 format (64-bit)
// Uses DSP-friendly truncated multiply (mul_trunc64) for area efficiency.
//
// 12-bit iteration count: supports up to 2048 max iterations.
//
// Computes z(n+1) = z(n)^2 + c until |z|^2 > 4.0 or max iterations reached.
// One iteration per clock cycle (3 truncated multiplies per iteration).
//
// Fractal types:
//   0 = Mandelbrot: z0=0, c=pixel coordinate
//   1 = Julia: z0=pixel coordinate, c=fixed parameter
//============================================================================

module mandelbrot_iterator #(
    parameter WIDTH     = 64,
    parameter FRAC_BITS = 56
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // Control
    input  wire                    start,
    input  wire signed [WIDTH-1:0] cr,
    input  wire signed [WIDTH-1:0] ci,
    input  wire [1:0]              fractal_type,
    input  wire signed [WIDTH-1:0] julia_cr,
    input  wire signed [WIDTH-1:0] julia_ci,
    input  wire [11:0]             max_iter,

    // Results
    output reg                     done,
    output reg  [11:0]             iter_count,
    output reg                     escaped,
    output reg  signed [WIDTH-1:0] final_mag_sq
);

// Escape threshold: 4.0 in fixed-point = 1 << (FRAC_BITS + 2)
localparam signed [WIDTH-1:0] ESCAPE_THRESHOLD = {{(WIDTH-FRAC_BITS-3){1'b0}}, 1'b1, {(FRAC_BITS+2){1'b0}}};

// States
localparam [1:0] S_IDLE = 2'd0,
                 S_ITER = 2'd1,
                 S_DONE = 2'd2;

reg [1:0]              state;
reg signed [WIDTH-1:0] zr, zi;
reg signed [WIDTH-1:0] c_real, c_imag;
reg [11:0]             iter;

// ---- DSP-based truncated multiplies ----
wire signed [WIDTH-1:0] zr_sq;
wire signed [WIDTH-1:0] zi_sq;
wire signed [WIDTH-1:0] zr_zi;

mul_trunc64 #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_mul_zr_sq (
    .a(zr), .b(zr), .result(zr_sq)
);

mul_trunc64 #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_mul_zi_sq (
    .a(zi), .b(zi), .result(zi_sq)
);

mul_trunc64 #(.WIDTH(WIDTH), .FRAC_BITS(FRAC_BITS)) u_mul_zr_zi (
    .a(zr), .b(zi), .result(zr_zi)
);

// 2 * zr * zi (left shift by 1)
wire signed [WIDTH-1:0] two_zr_zi = {zr_zi[WIDTH-2:0], 1'b0};

// |z|^2 = zr^2 + zi^2
wire signed [WIDTH-1:0] mag_sq = zr_sq + zi_sq;

// ---- Escape detection ----
// Overflow: squared value should be non-negative; if sign bit set, overflow occurred
wire zr_sq_overflow = zr_sq[WIDTH-1];
wire zi_sq_overflow = zi_sq[WIDTH-1];
// Addition overflow: both positive inputs but negative sum
wire sum_overflow   = ~zr_sq[WIDTH-1] & ~zi_sq[WIDTH-1] & mag_sq[WIDTH-1];
wire escape = zr_sq_overflow | zi_sq_overflow | sum_overflow |
              ($signed(mag_sq) > ESCAPE_THRESHOLD);

// Next z values
wire signed [WIDTH-1:0] zr_next_std  = zr_sq - zi_sq + c_real;
wire signed [WIDTH-1:0] zi_next_std  = two_zr_zi + c_imag;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= S_IDLE;
        done        <= 1'b0;
        escaped     <= 1'b0;
        iter_count  <= 12'd0;
        final_mag_sq<= {WIDTH{1'b0}};
        zr          <= {WIDTH{1'b0}};
        zi          <= {WIDTH{1'b0}};
        c_real      <= {WIDTH{1'b0}};
        c_imag      <= {WIDTH{1'b0}};
        iter        <= 12'd0;
    end else begin
        case (state)
        S_IDLE: begin
            if (start) begin
                done <= 1'b0;
                iter <= 12'd0;
                case (fractal_type)
                    2'd0: begin // Mandelbrot: z0=0, c=pixel
                        zr     <= {WIDTH{1'b0}};
                        zi     <= {WIDTH{1'b0}};
                        c_real <= cr;
                        c_imag <= ci;
                    end
                    2'd1: begin // Julia: z0=pixel, c=parameter
                        zr     <= cr;
                        zi     <= ci;
                        c_real <= julia_cr;
                        c_imag <= julia_ci;
                    end
                    default: begin
                        zr     <= {WIDTH{1'b0}};
                        zi     <= {WIDTH{1'b0}};
                        c_real <= cr;
                        c_imag <= ci;
                    end
                endcase
                state <= S_ITER;
            end
        end

        S_ITER: begin
            if (escape || (iter >= max_iter)) begin
                escaped      <= escape;
                iter_count   <= iter;
                final_mag_sq <= mag_sq;
                done         <= 1'b1;
                state        <= S_DONE;
            end else begin
                zr <= zr_next_std;
                zi <= zi_next_std;
                iter <= iter + 12'd1;
            end
        end

        S_DONE: begin
            if (start) begin
                done <= 1'b0;
                iter <= 12'd0;
                case (fractal_type)
                    2'd0: begin
                        zr     <= {WIDTH{1'b0}};
                        zi     <= {WIDTH{1'b0}};
                        c_real <= cr;
                        c_imag <= ci;
                    end
                    2'd1: begin
                        zr     <= cr;
                        zi     <= ci;
                        c_real <= julia_cr;
                        c_imag <= julia_ci;
                    end
                    default: begin
                        zr     <= {WIDTH{1'b0}};
                        zi     <= {WIDTH{1'b0}};
                        c_real <= cr;
                        c_imag <= ci;
                    end
                endcase
                state <= S_ITER;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
