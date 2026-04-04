//============================================================================
// Verilator Testbench for iter_pair (v0.10.0)
//
// Tests the dual-context time-shared DSP iterator against a software
// double-precision Mandelbrot/Julia reference.
//
// Coverage:
//   - Context A and B independently
//   - Dual concurrent A+B operation
//   - Julia mode (fractal_type=1)
//   - Cardioid / period-2 bulb precheck early exit
//   - Restart from S_DONE
//   - A/B independence (no cross-talk)
//============================================================================

#include "Viter_pair.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static Viter_pair* top;
static int tests_passed = 0;
static int tests_failed = 0;

// 8.56 fixed-point conversion
static int64_t to_fp(double val) {
    return (int64_t)std::llround(val * (double)(1ULL << 56));
}

static double from_fp(int64_t val) {
    return (double)val / (double)(1ULL << 56);
}

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
}

static void reset() {
    top->rst_n = 0;
    top->start_a = 0; top->start_b = 0;
    top->fractal_type = 0;
    top->julia_cr = 0; top->julia_ci = 0;
    top->max_iter = 64;
    top->cr_a = 0; top->ci_a = 0;
    top->cr_b = 0; top->ci_b = 0;
    for (int i = 0; i < 6; ++i) tick();
    top->rst_n = 1;
    tick();
}

// Software reference Mandelbrot (double precision, quantized inputs)
static int ref_mandelbrot(double cr, double ci, int max_iter) {
    // Quantize to 8.56 and back to match DUT input
    double qcr = from_fp(to_fp(cr));
    double qci = from_fp(to_fp(ci));
    double zr = 0.0, zi = 0.0;
    for (int i = 0; i < max_iter; i++) {
        double zr2 = zr * zr, zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) return i;
        double zr_new = zr2 - zi2 + qcr;
        zi = 2.0 * zr * zi + qci;
        zr = zr_new;
    }
    return max_iter;
}

// Software reference Julia
static int ref_julia(double z0r, double z0i, double cr, double ci, int max_iter) {
    double qz0r = from_fp(to_fp(z0r)), qz0i = from_fp(to_fp(z0i));
    double qcr = from_fp(to_fp(cr)), qci = from_fp(to_fp(ci));
    double zr = qz0r, zi = qz0i;
    for (int i = 0; i < max_iter; i++) {
        double zr2 = zr * zr, zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) return i;
        double zr_new = zr2 - zi2 + qcr;
        zi = 2.0 * zr * zi + qci;
        zr = zr_new;
    }
    return max_iter;
}

// Run a single Mandelbrot test on context A, return cycle count
static int run_ctx_a(double cr, double ci, int max_iter, int max_cycles = 4096) {
    top->fractal_type = 0;
    top->julia_cr = 0; top->julia_ci = 0;
    top->max_iter = max_iter;
    top->cr_a = to_fp(cr); top->ci_a = to_fp(ci);
    top->start_a = 1; tick(); top->start_a = 0;
    int cyc = 0;
    while (!top->done_a && cyc < max_cycles) { tick(); ++cyc; }
    return cyc;
}

// Run a single Mandelbrot test on context B, return cycle count
static int run_ctx_b(double cr, double ci, int max_iter, int max_cycles = 4096) {
    top->fractal_type = 0;
    top->julia_cr = 0; top->julia_ci = 0;
    top->max_iter = max_iter;
    top->cr_b = to_fp(cr); top->ci_b = to_fp(ci);
    top->start_b = 1; tick(); top->start_b = 0;
    int cyc = 0;
    while (!top->done_b && cyc < max_cycles) { tick(); ++cyc; }
    return cyc;
}

static void check(const char* name, bool cond) {
    if (cond) { std::printf("  PASS: %s\n", name); tests_passed++; }
    else      { std::printf("  FAIL: %s\n", name); tests_failed++; }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Viter_pair;

    const int MAX_ITER = 64;

    // ====================================================================
    std::printf("=== iter_pair Testbench ===\n\n");

    // ---- 1. Context A: basic Mandelbrot cases ----
    std::printf("--- Context A: Mandelbrot basics ---\n");
    reset();

    struct { const char* name; double cr, ci; int expect; bool escaped; } cases[] = {
        {"c=3+0i",   3.0,  0.0,  1, true},
        {"c=1+0i",   1.0,  0.0,  3, true},
        {"c=0+0i",   0.0,  0.0, MAX_ITER, false},
        {"c=-0.5+0i",-0.5, 0.0, MAX_ITER, false},  // inside cardioid
        {"c=-1+0i", -1.0,  0.0, MAX_ITER, false},   // period-2 bulb
    };

    for (auto& tc : cases) {
        reset();
        run_ctx_a(tc.cr, tc.ci, MAX_ITER);
        int iter = top->iter_count_a;
        bool esc = top->escaped_a;
        int ref = ref_mandelbrot(tc.cr, tc.ci, MAX_ITER);
        char buf[128];
        std::snprintf(buf, sizeof(buf), "A %s: iter=%d (ref=%d) escaped=%d", tc.name, iter, ref, esc);
        // Allow +-1 for non-precheck cases
        check(buf, (std::abs(iter - tc.expect) <= 1) && (esc == tc.escaped));
    }

    // ---- 2. Context B: same cases ----
    std::printf("\n--- Context B: Mandelbrot basics ---\n");
    for (auto& tc : cases) {
        reset();
        run_ctx_b(tc.cr, tc.ci, MAX_ITER);
        int iter = top->iter_count_b;
        bool esc = top->escaped_b;
        char buf[128];
        std::snprintf(buf, sizeof(buf), "B %s: iter=%d escaped=%d", tc.name, iter, esc);
        check(buf, (std::abs(iter - tc.expect) <= 1) && (esc == tc.escaped));
    }

    // ---- 3. Dual concurrent operation ----
    std::printf("\n--- Dual concurrent A+B ---\n");
    reset();
    top->fractal_type = 0;
    top->julia_cr = 0; top->julia_ci = 0;
    top->max_iter = MAX_ITER;
    // A gets c=1+0i (escapes@3), B gets c=0+0i (bounded)
    top->cr_a = to_fp(1.0); top->ci_a = to_fp(0.0);
    top->cr_b = to_fp(0.0); top->ci_b = to_fp(0.0);
    top->start_a = 1; top->start_b = 1;
    tick();
    top->start_a = 0; top->start_b = 0;

    int cyc = 0;
    bool a_done = false, b_done = false;
    int a_iter = 0, b_iter = 0;
    bool a_esc = false, b_esc = false;
    while ((!a_done || !b_done) && cyc < 4096) {
        tick(); ++cyc;
        if (top->done_a && !a_done) { a_done = true; a_iter = top->iter_count_a; a_esc = top->escaped_a; }
        if (top->done_b && !b_done) { b_done = true; b_iter = top->iter_count_b; b_esc = top->escaped_b; }
    }
    check("Dual: A(1+0i) escaped@3", a_done && std::abs(a_iter - 3) <= 1 && a_esc);
    check("Dual: B(0+0i) bounded@max", b_done && b_iter == MAX_ITER && !b_esc);

    // ---- 4. Julia mode ----
    std::printf("\n--- Julia mode ---\n");
    reset();
    double jcr = -0.4, jci = 0.6;
    top->fractal_type = 1;
    top->julia_cr = to_fp(jcr); top->julia_ci = to_fp(jci);
    top->max_iter = MAX_ITER;
    top->cr_a = to_fp(2.0); top->ci_a = to_fp(0.0);  // z0 = 2+0i (should escape)
    top->start_a = 1; tick(); top->start_a = 0;
    cyc = 0;
    while (!top->done_a && cyc < 4096) { tick(); ++cyc; }
    int julia_ref = ref_julia(2.0, 0.0, jcr, jci, MAX_ITER);
    char jbuf[128];
    std::snprintf(jbuf, sizeof(jbuf), "Julia z0=2+0i: iter=%d (ref=%d) esc=%d",
                  (int)top->iter_count_a, julia_ref, (int)top->escaped_a);
    check(jbuf, std::abs((int)top->iter_count_a - julia_ref) <= 1);

    // ---- 5. Cardioid precheck early exit ----
    std::printf("\n--- Cardioid precheck timing ---\n");
    reset();
    int cardioid_cyc = run_ctx_a(0.0, 0.0, MAX_ITER);
    char cbuf[128];
    std::snprintf(cbuf, sizeof(cbuf), "c=0+0i precheck in %d cycles (expect <50)", cardioid_cyc);
    check(cbuf, cardioid_cyc < 50);

    reset();
    int bulb_cyc = run_ctx_a(-1.0, 0.0, MAX_ITER);
    std::snprintf(cbuf, sizeof(cbuf), "c=-1+0i bulb precheck in %d cycles (expect <50)", bulb_cyc);
    check(cbuf, bulb_cyc < 50);

    // ---- 6. Restart from S_DONE ----
    std::printf("\n--- Restart from S_DONE ---\n");
    reset();
    run_ctx_a(3.0, 0.0, MAX_ITER);  // c=3+0i, escapes fast
    check("First run done", top->done_a == 1);
    // Now restart without reset
    top->cr_a = to_fp(1.0); top->ci_a = to_fp(0.0);
    top->start_a = 1; tick(); top->start_a = 0;
    cyc = 0;
    while (!top->done_a && cyc < 4096) { tick(); ++cyc; }
    check("Restart: iter=3 (c=1+0i)", std::abs((int)top->iter_count_a - 3) <= 1 && top->escaped_a);

    // ---- 7. A/B independence ----
    std::printf("\n--- A/B independence ---\n");
    reset();
    // Start only A
    run_ctx_a(3.0, 0.0, MAX_ITER);
    check("A done, B untouched (done_b=0)", top->done_b == 0);
    // Now start only B
    run_ctx_b(3.0, 0.0, MAX_ITER);
    // A should still show its old results
    check("B done, A still shows old (done_a=1)", top->done_a == 1);

    // ---- 8. Software reference sweep ----
    std::printf("\n--- Reference sweep (real axis) ---\n");
    int mismatches = 0, total = 0;
    for (int i = -200; i <= 50; i += 5) {
        double cr = i * 0.01;
        reset();
        run_ctx_a(cr, 0.0, MAX_ITER);
        int hw = top->iter_count_a;
        int sw = ref_mandelbrot(cr, 0.0, MAX_ITER);
        total++;
        if (std::abs(hw - sw) > 1) {
            std::printf("  MISMATCH c=%.2f: hw=%d sw=%d\n", cr, hw, sw);
            mismatches++;
        }
    }
    std::printf("  Sweep: %d/%d matched (+-1 tolerance)\n", total - mismatches, total);
    check("Reference sweep <5 mismatches", mismatches < 5);

    // ---- Summary ----
    std::printf("\n========================================\n");
    std::printf("RESULTS: %d passed, %d failed\n", tests_passed, tests_failed);
    std::printf("========================================\n");

    top->final();
    delete top;
    return tests_failed > 0 ? 1 : 0;
}
