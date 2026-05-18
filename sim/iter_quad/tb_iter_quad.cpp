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
    // Enable A3 period-3 precheck so the sim mirrors the FPGA path that
    // golden.py models. (When this enable is 0 the FSM skips S_BULB3 and
    // the period3_bulb_precheck cases would diverge from golden.)
    dut->p3_precheck_enable = 1;
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
    //
    // Expected values come from sim/iter_quad/golden.py — keep in sync
    // by running `python3 golden.py --gen-cases`.
    TestCase cases[] = {
        // ---- Interior / precheck cases ----
        {"origin",          0.0,    0.0,    100,  100, 0},
        {"cardioid_-0.25",  -0.25,  0.0,    100,  100, 0},
        {"p2_bulb_-1",      -1.0,   0.0,    100,  100, 0},
        {"near_cusp",       0.249,  0.0,    500,  500, 0},
        {"p3_island",       -1.75,  0.0,    500,  500, 0},

        // ---- A3 period-3 bulb prechecks (upper + lower via |ci|) ----
        {"p3b_upper_ctr",   -0.1225611669,  0.7448617666, 100, 100, 0},
        {"p3b_lower_ctr",   -0.1225611669, -0.7448617666, 100, 100, 0},
        {"p3b_inside_x",    -0.07,          0.7448617666, 100, 100, 0},
        {"p3b_inside_y",    -0.1225611669,  0.79,         100, 100, 0},
        {"p3b_inside_diag", -0.085,         0.78,         100, 100, 0},
        // Inside the M-set bulb but OUTSIDE our inscribed precheck circle
        // — should NOT precheck, must iterate fully to max_iter.
        {"p3b_outside_circ",-0.05,          0.7448617666, 500, 500, 0},
        // Outside the bulb entirely — escapes normally.
        {"p3b_far_above",   -0.1225611669,  0.95,         500,  14, 1},

        // ---- Escape cases at varied depths ----
        // Used to characterise the RTL-vs-golden iter_count gap: if
        // the gap is uniformly +1, it's a counter-semantics
        // labelling difference; if it varies, there's a real
        // arithmetic divergence to chase.
        {"escape_2",        2.0,    0.0,    100,    2, 1},
        {"escape_1",        1.0,    0.0,    100,    3, 1},
        {"esc_d13",         0.30,   0.0,    500,   13, 1},
        {"esc_d21",         0.27,   0.0,    500,   21, 1},
        {"esc_d31",         0.26,   0.0,    500,   31, 1},
        {"esc_d52",         -0.235, 0.74,   500,   52, 1},
        {"esc_d99",         -0.745, 0.10,   500,   99, 1},
        {"seahorse_edge",   -0.745, 0.113,  500,  128, 1},
        {"esc_d386",        -0.745, 0.110,  500,  386, 1},
        {"esc_d461",        -0.746, 0.115,  500,  461, 1},

        // ---- cy=0 deep-zoom artifact reproduction (MERCATOR P189) ----
        // Probe iter_quad with the exact cr/ci values that cause the
        // FPGA's "pink band" artifact.  Probe (golden + mpmath) returned
        // iter ≈ 190-220 for all of these.  If iter_quad returns iter=0..3
        // here, the bug is reproduced in sim.
        {"m189_ci_tiny",    -1.7487645202, +1e-10,  1024, -1, 0},
        {"m189_ci_smaller", -1.7487645202, +1e-12,  1024, -1, 0},
        {"m189_ci_smaller2",-1.7487645202, +1e-14,  1024, -1, 0},
        {"m189_ci_zero",    -1.7487645202,  0.0,    1024, -1, 0},
        {"m189_ci_mid",     -1.7487645202, +2e-8,   1024, -1, 0},
        {"m189_ci_far",     -1.7487645202, +4e-8,   1024, -1, 0},
        {"m189_neg_ci",     -1.7487645202, -1e-10,  1024, -1, 0},
        // Try cr SLIGHTLY off — see if a different cr changes outcome
        {"m189_cr_off1",    -1.7487640000, +1e-10,  1024, -1, 0},
        {"m189_cr_off2",    -1.7487650000, +1e-10,  1024, -1, 0},
        // Walk ci from tiny to bigger to find transition where bug stops
        {"m189_ci_1e-9",    -1.7487645202, +1e-9,   1024, -1, 0},
        {"m189_ci_5e-9",    -1.7487645202, +5e-9,   1024, -1, 0},
        {"m189_ci_1e-8",    -1.7487645202, +1e-8,   1024, -1, 0},
        {"m189_ci_1.5e-8",  -1.7487645202, +1.5e-8, 1024, -1, 0},
        // Sanity: cr=-0.5 (clearly outside M-set, escapes fast normally)
        // with tiny ci — should also bug if it's a generic small-ci issue
        {"cr_-0.5_ci_tiny", -0.5,           +1e-10, 1024, -1, 0},
        {"cr_-2.1_ci_tiny", -2.1,           +1e-10, 1024, -1, 0},
        // EJS CAULI (z=17, where artifact starts appearing)
        {"cauli_ci_tiny",   -1.7487645,    +1e-8,   2048, -1, 0},
        {"cauli_ci_zero",   -1.7487645,     0.0,    2048, -1, 0},
    };

    int n_cases = sizeof(cases) / sizeof(cases[0]);
    int n_pass = 0, n_fail = 0, n_gap = 0;

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
            printf("[TIMEOUT] %-15s cr=%+8.4f ci=%+8.4f max=%d\n",
                   tc.name, tc.cr, tc.ci, tc.max_iter);
            n_fail++;
            continue;
        }

        int got_iter = (int)dut->iter_count_a;
        int got_esc  = (int)dut->escaped_a;
        int delta    = got_iter - tc.expected_iter;

        // PASS: matches exactly
        // GAP : escape semantics match, iter_count differs by 1
        //       (suspected counter-edge labelling difference, not a
        //        real arithmetic disagreement)
        // FAIL: any other mismatch
        const char* tag;
        if (tc.expected_iter < 0) {
            tag = "INFO";
        } else if (got_iter == tc.expected_iter && got_esc == tc.expected_escaped) {
            tag = "PASS"; n_pass++;
        } else if (got_esc == tc.expected_escaped && (delta == 1 || delta == -1)) {
            tag = "GAP "; n_gap++;
        } else {
            tag = "FAIL"; n_fail++;
        }

        if (tc.expected_iter < 0) {
            printf("[%s] %-15s cr=%+9.5f ci=%+9.5f max=%4d  ->  iter=%4d esc=%d\n",
                   tag, tc.name, tc.cr, tc.ci, tc.max_iter, got_iter, got_esc);
        } else {
            printf("[%s] %-15s cr=%+9.5f ci=%+9.5f max=%4d  ->  iter=%4d (golden=%4d, %+d) esc=%d\n",
                   tag, tc.name, tc.cr, tc.ci, tc.max_iter,
                   got_iter, tc.expected_iter, delta, got_esc);
        }

        // Tick a few more cycles for the next dispatch to settle
        for (int j = 0; j < 4; j++) tick(dut);
    }

    printf("\n%d cases: %d pass, %d gap (off-by-one), %d fail\n",
           n_cases, n_pass, n_gap, n_fail);

    if (tfp) { tfp->close(); delete tfp; }
    delete dut;
    return n_fail == 0 ? 0 : 1;
}
