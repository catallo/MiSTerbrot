//============================================================================
// Verilator Testbench for pixel_pipeline
//
// Tests the full pipeline: coord_generator -> parallel iterators -> output
// Uses a small 8x8 frame with 4 iterators for quick verification.
//
// Verifies:
//   1. All pixels are produced (8*8 = 64 results)
//   2. Coordinates map correctly to complex plane
//   3. Known iteration counts match at specific pixels
//   4. frame_done asserts after all pixels are computed
//============================================================================

#include "Vpixel_pipeline.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <set>

static int32_t to_fp(double val) {
    return (int32_t)(val * (1 << 28));
}

static double from_fp(int32_t val) {
    return (double)val / (1 << 28);
}

static Vpixel_pipeline* top;
static vluint64_t sim_time = 0;

static void tick() {
    top->clk = 0;
    top->eval();
    sim_time++;
    top->clk = 1;
    top->eval();
    sim_time++;
}

static void reset() {
    top->rst_n = 0;
    top->start_frame = 0;
    for (int i = 0; i < 10; i++) tick();
    top->rst_n = 1;
    tick();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vpixel_pipeline;

    printf("=== Pixel Pipeline Testbench ===\n\n");

    // Parameters: 8x8 frame, 4 iterators (set via Verilator parameters)
    const int H_RES = 8;
    const int V_RES = 8;
    const int total_pixels = H_RES * V_RES;

    reset();

    // Setup: Mandelbrot, centered at (-0.5, 0), step = 0.5
    // This gives a view from (-2.5, -2.0) to (1.5, 2.0) approx
    top->fractal_type = 0;
    top->max_iter = 64;
    top->julia_cr = 0;
    top->julia_ci = 0;
    top->center_x = to_fp(-0.5);
    top->center_y = to_fp(0.0);
    top->step = to_fp(0.5);

    printf("View: center=(-0.5, 0.0), step=0.5, %dx%d\n", H_RES, V_RES);
    printf("Starting frame render...\n\n");

    // Start frame
    top->start_frame = 1;
    tick();
    top->start_frame = 0;

    // Collect results
    int results_collected = 0;
    int max_cycles = 200000;
    int cycles = 0;

    // Track which pixels we've seen
    std::set<int> seen_pixels;
    int iter_map[V_RES][H_RES];
    bool escaped_map[V_RES][H_RES];
    for (int y = 0; y < V_RES; y++)
        for (int x = 0; x < H_RES; x++) {
            iter_map[y][x] = -1;
            escaped_map[y][x] = false;
        }

    while (!top->frame_done && cycles < max_cycles) {
        tick();
        cycles++;

        if (top->result_valid) {
            int x = top->result_x;
            int y = top->result_y;
            int iter = top->result_iter;
            bool escaped = top->result_escaped;

            if (x < H_RES && y < V_RES) {
                int key = y * H_RES + x;
                seen_pixels.insert(key);
                iter_map[y][x] = iter;
                escaped_map[y][x] = escaped;
                results_collected++;
            }
        }
    }

    printf("Frame complete in %d cycles (%d results collected)\n\n", cycles, results_collected);

    // ---- Verify all pixels received ----
    int missing = 0;
    for (int y = 0; y < V_RES; y++) {
        for (int x = 0; x < H_RES; x++) {
            int key = y * H_RES + x;
            if (seen_pixels.find(key) == seen_pixels.end()) {
                if (missing < 10)
                    printf("  MISSING pixel (%d, %d)\n", x, y);
                missing++;
            }
        }
    }

    if (missing == 0) {
        printf("PASS: All %d pixels received\n", total_pixels);
    } else {
        printf("FAIL: %d pixels missing out of %d\n", missing, total_pixels);
    }

    // ---- Print iteration map ----
    printf("\nIteration count map (%dx%d):\n", H_RES, V_RES);
    printf("   ");
    for (int x = 0; x < H_RES; x++) printf(" x%d ", x);
    printf("\n");

    for (int y = 0; y < V_RES; y++) {
        printf("y%d:", y);
        for (int x = 0; x < H_RES; x++) {
            if (iter_map[y][x] < 0)
                printf("  ?? ");
            else if (!escaped_map[y][x])
                printf("  ** ");  // Inside set
            else
                printf(" %3d ", iter_map[y][x]);
        }
        printf("\n");
    }

    // ---- Verify against software reference ----
    printf("\n--- Software Reference Comparison ---\n");
    // step=0.5, center=(-0.5, 0), 8x8
    // cr_start = -0.5 - 4*0.5 = -2.5
    // ci_start = 0.0 - 4*0.5 = -2.0
    double cr_start = -0.5 - (H_RES / 2.0) * 0.5;
    double ci_start = 0.0 - (V_RES / 2.0) * 0.5;
    int mismatches = 0;

    for (int y = 0; y < V_RES; y++) {
        for (int x = 0; x < H_RES; x++) {
            double cr = cr_start + x * 0.5;
            double ci = ci_start + y * 0.5;

            // Software Mandelbrot
            double zr = 0.0, zi = 0.0;
            int sw_iter = 0;
            bool sw_escaped = false;
            for (sw_iter = 0; sw_iter < 64; sw_iter++) {
                double zr_sq = zr * zr, zi_sq = zi * zi;
                if (zr_sq + zi_sq > 4.0) { sw_escaped = true; break; }
                double zr_new = zr_sq - zi_sq + cr;
                double zi_new = 2.0 * zr * zi + ci;
                zr = zr_new; zi = zi_new;
            }
            if (sw_iter >= 64) sw_iter = 64;

            int hw_iter = iter_map[y][x];
            if (hw_iter >= 0 && abs(hw_iter - sw_iter) > 1) {
                printf("  MISMATCH at (%d,%d) c=(%.2f,%.2f): hw=%d sw=%d\n",
                       x, y, cr, ci, hw_iter, sw_iter);
                mismatches++;
            }
        }
    }

    if (mismatches == 0) {
        printf("PASS: All pixels match software reference (within +-1)\n");
    } else {
        printf("FAIL: %d mismatches\n", mismatches);
    }

    // ---- frame_done check ----
    if (top->frame_done) {
        printf("\nPASS: frame_done asserted\n");
    } else {
        printf("\nFAIL: frame_done not asserted after %d cycles\n", max_cycles);
    }

    printf("\n========================================\n");
    int total_pass = (missing == 0) + (mismatches == 0) + (top->frame_done ? 1 : 0);
    int total_fail = 3 - total_pass;
    printf("PIPELINE RESULTS: %d passed, %d failed\n", total_pass, total_fail);
    printf("========================================\n");

    top->final();
    delete top;

    return (missing > 0 || mismatches > 0 || !top) ? 1 : 0;
}
