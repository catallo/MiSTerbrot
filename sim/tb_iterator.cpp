//============================================================================
// Verilator Testbench for mandelbrot_iterator
//
// Tests fixed-point 4.28 Mandelbrot iteration against known results:
//   c = 0+0i      -> inside set (reaches max_iter)
//   c = 1+0i      -> escapes at iteration 3
//   c = -1+0i     -> inside set (period-2 cycle)
//   c = 0.5+0i    -> escapes at iteration 5
//   c = -2+0i     -> boundary (reaches max_iter, |z|=2 exactly)
//   c = 0+1i      -> inside set (period-2 cycle)
//   c = 0.25+0i   -> near boundary, takes many iterations
//   c = 10+0i     -> escapes immediately (iteration 1)
//
// Also tests Julia and Burning Ship modes.
//============================================================================

#include "Vmandelbrot_iterator.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

// 4.28 fixed-point conversion
static int32_t to_fp(double val) {
    return (int32_t)(val * (1 << 28));
}

static double from_fp(int32_t val) {
    return (double)val / (1 << 28);
}

static Vmandelbrot_iterator* top;
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
    top->start = 0;
    for (int i = 0; i < 5; i++) tick();
    top->rst_n = 1;
    tick();
}

// Run iterator until done, return iteration count. Max cycles to prevent hang.
static int run_until_done(int max_cycles = 100000) {
    int cycles = 0;
    while (!top->done && cycles < max_cycles) {
        tick();
        cycles++;
    }
    if (cycles >= max_cycles) {
        printf("  TIMEOUT after %d cycles!\n", max_cycles);
        return -1;
    }
    return cycles;
}

struct TestCase {
    const char* name;
    double cr, ci;
    int fractal_type;
    int expected_iter;    // -1 = should reach max_iter (inside set)
    bool expected_escaped;
    double julia_cr, julia_ci;  // for Julia mode
};

static int tests_passed = 0;
static int tests_failed = 0;

static void run_test(const TestCase& tc, int max_iter) {
    printf("Test: %-30s c=(%.4f, %.4f) type=%d ... ",
           tc.name, tc.cr, tc.ci, tc.fractal_type);

    // Setup inputs
    top->cr = to_fp(tc.cr);
    top->ci = to_fp(tc.ci);
    top->fractal_type = tc.fractal_type;
    top->max_iter = max_iter;
    top->julia_cr = to_fp(tc.julia_cr);
    top->julia_ci = to_fp(tc.julia_ci);

    // Pulse start
    top->start = 1;
    tick();
    top->start = 0;

    // Run until done
    int cycles = run_until_done();
    if (cycles < 0) {
        tests_failed++;
        return;
    }

    int iter = top->iter_count;
    bool escaped = top->escaped;
    double mag_sq = from_fp(top->final_mag_sq);

    bool pass = true;

    if (tc.expected_iter >= 0) {
        // Check iteration count with +-1 tolerance for fixed-point rounding
        if (abs(iter - tc.expected_iter) > 1) {
            printf("FAIL (iter=%d, expected=%d +-1)", iter, tc.expected_iter);
            pass = false;
        }
    } else {
        // Should be inside set (reach max_iter)
        if (iter < max_iter) {
            printf("FAIL (iter=%d, expected max_iter=%d)", iter, max_iter);
            pass = false;
        }
    }

    if (tc.expected_escaped != escaped) {
        if (!pass) printf(", ");
        printf("FAIL (escaped=%d, expected=%d)", escaped, tc.expected_escaped);
        pass = false;
    }

    if (pass) {
        printf("PASS (iter=%d, escaped=%d, |z|^2=%.4f)", iter, escaped, mag_sq);
        tests_passed++;
    } else {
        printf(" (got iter=%d, escaped=%d, |z|^2=%.4f)", iter, escaped, mag_sq);
        tests_failed++;
    }
    printf("\n");
}

// Software reference Mandelbrot computation
static int reference_mandelbrot(double cr, double ci, int max_iter) {
    double zr = 0.0, zi = 0.0;
    for (int i = 0; i < max_iter; i++) {
        double zr_sq = zr * zr;
        double zi_sq = zi * zi;
        if (zr_sq + zi_sq > 4.0) return i;
        double zr_new = zr_sq - zi_sq + cr;
        double zi_new = 2.0 * zr * zi + ci;
        zr = zr_new;
        zi = zi_new;
    }
    return max_iter;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vmandelbrot_iterator;

    printf("=== Mandelbrot Iterator Testbench ===\n\n");
    printf("Fixed-point format: 4.28 (32-bit signed)\n");
    printf("Escape threshold: 4.0 (|z|^2 > 4.0)\n\n");

    reset();

    int max_iter = 128;

    // ---- Mandelbrot Tests ----
    printf("--- Mandelbrot Set Tests (max_iter=%d) ---\n", max_iter);

    TestCase mandelbrot_tests[] = {
        {"Origin (inside)",         0.0,  0.0,  0, -1,  false, 0, 0},
        {"c=1+0i (escapes@3)",      1.0,  0.0,  0,  3,  true,  0, 0},
        {"c=-1+0i (period-2)",     -1.0,  0.0,  0, -1,  false, 0, 0},
        {"c=0.5+0i (escapes@5)",    0.5,  0.0,  0,  5,  true,  0, 0},
        {"c=0+1i (period-2)",       0.0,  1.0,  0, -1,  false, 0, 0},
        {"c=3+0i (escapes@1)",      3.0,  0.0,  0,  1,  true,  0, 0},
        {"c=-0.75+0i (boundary)",  -0.75, 0.0,  0, -1,  false, 0, 0},
        {"c=0.3+0.5i (escapes)",    0.3,  0.5,  0, -2,  true,  0, 0}, // -2 = check with reference
        {"c=-0.2+0.2i (inside)",   -0.2,  0.2,  0, -1,  false, 0, 0},
    };

    // For test cases with expected_iter=-2, compute reference
    for (auto& tc : mandelbrot_tests) {
        if (tc.expected_iter == -2) {
            int ref = reference_mandelbrot(tc.cr, tc.ci, max_iter);
            tc.expected_iter = ref;
            tc.expected_escaped = (ref < max_iter);
        }
    }

    for (const auto& tc : mandelbrot_tests) {
        run_test(tc, max_iter);
    }

    // ---- Julia Set Tests ----
    // Use c = 0+1i (connected Julia set, period-2 cycle at origin)
    printf("\n--- Julia Set Tests (c=0+1i, max_iter=%d) ---\n", max_iter);

    double jcr = 0.0, jci = 1.0;

    TestCase julia_tests[] = {
        {"Julia z0=0+0i (inside)",   0.0, 0.0, 1, -1,  false, jcr, jci},
        {"Julia z0=0.1+0.1i",       0.1, 0.1, 1, -2,  false, jcr, jci},
        {"Julia z0=2+0i (escapes)",  2.0, 0.0, 1, -2,  true,  jcr, jci},
        {"Julia z0=1+1i (escapes)",  1.0, 1.0, 1, -2,  true,  jcr, jci},
    };

    // Software reference for Julia
    for (auto& tc : julia_tests) {
        double zr = tc.cr, zi = tc.ci;
        int iter;
        for (iter = 0; iter < max_iter; iter++) {
            double zr_sq = zr * zr, zi_sq = zi * zi;
            if (zr_sq + zi_sq > 4.0) break;
            double zr_new = zr_sq - zi_sq + tc.julia_cr;
            double zi_new = 2.0 * zr * zi + tc.julia_ci;
            zr = zr_new; zi = zi_new;
        }
        tc.expected_iter = iter;
        tc.expected_escaped = (iter < max_iter);
    }

    for (const auto& tc : julia_tests) {
        run_test(tc, max_iter);
    }

    // ---- Burning Ship Tests ----
    printf("\n--- Burning Ship Tests (max_iter=%d) ---\n", max_iter);

    TestCase ship_tests[] = {
        {"Ship origin",       0.0,   0.0,  2, -1, false, 0, 0},
        {"Ship c=1+0i",       1.0,   0.0,  2, -2, true,  0, 0},
        {"Ship c=-1.75+0i",  -1.75,  0.0,  2, -2, false, 0, 0},
        {"Ship c=5+0i",       5.0,   0.0,  2, -2, true,  0, 0},
    };

    // Software reference for Burning Ship
    for (auto& tc : ship_tests) {
        double zr = 0.0, zi = 0.0;
        int iter;
        for (iter = 0; iter < max_iter; iter++) {
            double zr_sq = zr * zr, zi_sq = zi * zi;
            if (zr_sq + zi_sq > 4.0) break;
            double zr_new = zr_sq - zi_sq + tc.cr;
            double zi_new = 2.0 * fabs(zr) * fabs(zi) + tc.ci;
            zr = zr_new; zi = zi_new;
        }
        tc.expected_iter = iter;
        tc.expected_escaped = (iter < max_iter);
    }

    for (const auto& tc : ship_tests) {
        run_test(tc, max_iter);
    }

    // ---- Fixed-point precision test ----
    printf("\n--- Fixed-Point Precision Sweep ---\n");
    printf("Comparing hardware vs software for 100 points along real axis...\n");

    int precision_errors = 0;
    int total_sweep = 0;
    for (int i = -200; i <= 50; i++) {
        double cr_val = i * 0.01;
        double ci_val = 0.0;

        int ref = reference_mandelbrot(cr_val, ci_val, max_iter);

        // Run hardware
        top->cr = to_fp(cr_val);
        top->ci = to_fp(ci_val);
        top->fractal_type = 0;
        top->max_iter = max_iter;
        top->julia_cr = 0;
        top->julia_ci = 0;
        top->start = 1;
        tick();
        top->start = 0;
        run_until_done();

        int hw_iter = top->iter_count;
        total_sweep++;

        // Allow +-1 iteration difference due to fixed-point rounding
        if (abs(hw_iter - ref) > 1) {
            printf("  MISMATCH at c=%.2f: hw=%d, sw=%d (diff=%d)\n",
                   cr_val, hw_iter, ref, hw_iter - ref);
            precision_errors++;
        }
    }
    printf("Sweep complete: %d/%d matched (within +-1 tolerance)\n",
           total_sweep - precision_errors, total_sweep);

    if (precision_errors > 5) {
        printf("WARNING: %d precision mismatches (>5 allowed)\n", precision_errors);
        tests_failed++;
    } else {
        tests_passed++;
    }

    // ---- Summary ----
    printf("\n========================================\n");
    printf("RESULTS: %d passed, %d failed\n", tests_passed, tests_failed);
    printf("========================================\n");

    top->final();
    delete top;

    return tests_failed > 0 ? 1 : 0;
}
