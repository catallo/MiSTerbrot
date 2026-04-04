#include "Viter_pair.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>

static Viter_pair* top;

static int64_t to_fp(double val) {
    return (int64_t)std::llround(val * (double)(1ULL << 56));
}

static double from_fp(int64_t val) {
    return (double)val / (double)(1ULL << 56);
}

static void tick() {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

static void reset() {
    top->rst_n = 0;
    top->start_a = 0;
    top->start_b = 0;
    for (int i = 0; i < 4; ++i) tick();
    top->rst_n = 1;
    tick();
}

static bool run_case(const char* name, double cr, double ci, int expected_iter, bool expected_escaped) {
    top->fractal_type = 0;
    top->julia_cr = 0;
    top->julia_ci = 0;
    top->max_iter = 64;
    top->cr_a = to_fp(cr);
    top->ci_a = to_fp(ci);
    top->cr_b = 0;
    top->ci_b = 0;

    top->start_a = 1;
    tick();
    top->start_a = 0;

    int cycles = 0;
    while (!top->done_a && cycles < 512) {
        tick();
        ++cycles;
    }

    int iter = top->iter_count_a;
    bool escaped = top->escaped_a;
    bool pass = (iter == expected_iter) && (escaped == expected_escaped);

    std::printf(
        "%s: iter=%d escaped=%d mag_sq=%.6f %s\n",
        name, iter, escaped, from_fp((int64_t)top->final_mag_sq_a), pass ? "PASS" : "FAIL"
    );

    return pass;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Viter_pair;

    reset();

    bool ok = true;
    ok &= run_case("c=3+0i", 3.0, 0.0, 1, true);
    ok &= run_case("c=1+0i", 1.0, 0.0, 3, true);
    ok &= run_case("c=0+0i", 0.0, 0.0, 64, false);

    top->final();
    delete top;
    return ok ? 0 : 1;
}
