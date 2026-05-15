// Verilator testbench for rtl/iter_quad.v
//
// Drives a list of (cr, ci, max_iter) cases through context A and prints
// the (iter_count, escaped) outputs.  Other contexts (B-F) are left idle
// for now — testing one context at a time keeps the harness simple and
// the iter_quad shares its multiplier pipeline across contexts so a
// single-context test still exercises the whole datapath.
//
// To add tests: append to the `cases[]` array.  When `expected_iter` is
// negative, the test only prints actual values (use this for "what does
// the FPGA do" exploration); when non-negative, the test pass/fails on
// match.
//
// Note: bit-exact comparison against a software golden model would catch
// truncated-multiply rounding bugs.  See golden.py for a Python
// reference; pipe its output to generate `expected_iter` values.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "Viter_quad.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static uint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static VerilatedFstC* tfp = nullptr;

static void tick(Viter_quad* dut) {
    dut->clk = 0;
    dut->eval();
    if (tfp) tfp->dump(main_time);
    main_time++;

    dut->clk = 1;
    dut->eval();
    if (tfp) tfp->dump(main_time);
    main_time++;
}

static void reset(Viter_quad* dut) {
    dut->rst_n   = 0;
    dut->clk     = 0;
    dut->max_iter = 0;
    dut->start_a = 0; dut->cr_a = 0; dut->ci_a = 0;
    dut->start_b = 0; dut->cr_b = 0; dut->ci_b = 0;
    dut->start_c = 0; dut->cr_c = 0; dut->ci_c = 0;
    dut->start_d = 0; dut->cr_d = 0; dut->ci_d = 0;
    dut->start_e = 0; dut->cr_e = 0; dut->ci_e = 0;
    dut->start_f = 0; dut->cr_f = 0; dut->ci_f = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_n = 1;
    for (int i = 0; i < 4; i++) tick(dut);
}

// Convert a double to signed 8.56 fixed-point (int64).
// 8.56 means 8 integer bits + 56 fractional bits, two's complement.
static int64_t to_8_56(double v) {
    return (int64_t)(v * (double)((uint64_t)1 << 56));
}

// Convert int64 8.56 back to double for printing.
static double from_8_56(int64_t v) {
    return (double)v / (double)((uint64_t)1 << 56);
}

struct TestCase {
    const char* name;
    double cr;
    double ci;
    uint16_t max_iter;
    int     expected_iter;     // -1 = "exploration", just print
    int     expected_escaped;  // ignored if expected_iter < 0
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    bool trace = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "+trace") == 0) trace = true;
    }
    if (trace) {
        Verilated::traceEverOn(true);
    }

    Viter_quad* dut = new Viter_quad;
    if (trace) {
        tfp = new VerilatedFstC;
        dut->trace(tfp, 99);
        tfp->open("obj_dir/sim.fst");
    }

    reset(dut);

    // -------- Test cases --------
    // Mandelbrot iteration: z_{n+1} = z_n^2 + c, z_0 = 0.
    // Escape: |z|^2 > 4.  Interior: |z| stays bounded → iter_count = max_iter.
    //
    // The interior precheck in iter_quad short-circuits points inside
    // the main cardioid OR the period-2 bulb to iter_count = max_iter
    // immediately, without iterating.
    TestCase cases[] = {
        // Origin: cusp of cardioid.  Slightly inside the cardioid in
        // practice; precheck should catch it -> max_iter, escaped=0.
        {"origin",          0.0,   0.0,  100, -1, 0},

        // Cardioid interior (e.g., c = -0.25 + 0i is inside the
        // cardioid). Precheck -> max_iter, escaped=0.
        {"cardioid_-0.25",  -0.25, 0.0,  100, -1, 0},

        // Period-2 bulb interior: c = -1 + 0i sits in the centre of the
        // P2 bulb. Precheck -> max_iter, escaped=0.
        {"p2_bulb_-1",      -1.0,  0.0,  100, -1, 0},

        // Outside the set: c = 2 + 0i. z_1 = 0+2 = 2, |z_1|^2 = 4
        // (escape threshold).  Should escape on iter 1 or 2.
        {"escape_2",        2.0,   0.0,  100, -1, 1},

        // Outside the set: c = 1 + 0i. z escapes after a few iterations.
        {"escape_1",        1.0,   0.0,  100, -1, 1},

        // Boundary point near the cardioid cusp (very high iter count
        // expected, may approach max_iter).
        {"near_cusp",       0.249, 0.0,  500, -1, 0},

        // Period-3 island (Misiurewicz region around c = -1.75 + 0i).
        // Interior point — should not escape but also won't pass the
        // precheck (it's outside cardioid + P2 bulb), so will iterate
        // to max_iter.
        {"p3_island",       -1.75, 0.0,  500, -1, 0},

        // Seahorse Valley boundary point (escapes after many iters).
        {"seahorse_edge",   -0.745, 0.113, 500, -1, 1},
    };

    int n_cases = sizeof(cases) / sizeof(cases[0]);
    int n_pass = 0, n_fail = 0;

    for (int i = 0; i < n_cases; i++) {
        const TestCase& tc = cases[i];

        // Drive context A
        dut->max_iter = tc.max_iter;
        dut->cr_a = (uint64_t)to_8_56(tc.cr);
        dut->ci_a = (uint64_t)to_8_56(tc.ci);
        dut->start_a = 1;
        tick(dut);
        dut->start_a = 0;

        // Wait for done_a (or timeout)
        int timeout = 200000;
        while (!dut->done_a && timeout-- > 0) {
            tick(dut);
        }

        if (timeout <= 0) {
            printf("[TIMEOUT] %-20s cr=%+8.4f ci=%+8.4f max=%d\n",
                   tc.name, tc.cr, tc.ci, tc.max_iter);
            n_fail++;
            continue;
        }

        int got_iter = (int)dut->iter_count_a;
        int got_esc  = (int)dut->escaped_a;
        const char* tag;
        if (tc.expected_iter < 0) {
            tag = "INFO";
        } else if (got_iter == tc.expected_iter && got_esc == tc.expected_escaped) {
            tag = "PASS"; n_pass++;
        } else {
            tag = "FAIL"; n_fail++;
        }
        printf("[%s] %-20s cr=%+9.5f ci=%+9.5f max=%4d -> iter=%4d esc=%d\n",
               tag, tc.name, tc.cr, tc.ci, tc.max_iter, got_iter, got_esc);

        // Tick a few more cycles for the next dispatch to settle
        for (int j = 0; j < 4; j++) tick(dut);
    }

    printf("\n%d/%d cases evaluated; %d explicit pass, %d fail\n",
           n_pass + n_fail, n_cases, n_pass, n_fail);

    if (tfp) { tfp->close(); delete tfp; }
    delete dut;
    return n_fail == 0 ? 0 : 1;
}
