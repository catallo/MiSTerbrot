// Focused debug for the cy=0 deep-zoom artifact.
// Runs ONE test case (cr=-1.7487645202, ci=1e-10, max_iter=1024) and
// prints iter_count_a + escaped_a + a small set of internal signals
// every cycle until done_a goes high.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include "Viter_quad.h"
#include "Viter_quad___024root.h"
#include "verilated.h"

static uint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static void tick(Viter_quad* dut) {
    dut->clk = 0;
    dut->eval();
    main_time++;
    dut->clk = 1;
    dut->eval();
    main_time++;
}

static int64_t to_8_56(double v) {
    return (int64_t)(v * (double)((uint64_t)1 << 56));
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Viter_quad* dut = new Viter_quad;

    // Reset
    dut->rst_n = 0;
    dut->max_iter = 1024;
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

    // Drive one case
    double cr = -1.7487645202;
    double ci = 1e-10;
    dut->cr_a = (uint64_t)to_8_56(cr);
    dut->ci_a = (uint64_t)to_8_56(ci);
    dut->start_a = 1;
    tick(dut);
    dut->start_a = 0;

    printf("cr=%+.10e ci=%+.10e max_iter=1024\n", cr, ci);
    printf("cycle     iter  esc done   ctx_state[0]\n");

    auto* root = dut->rootp;
    uint64_t cycle = 0;
    // Trace EVERY cycle once we're in S_ITER to catch the iter=2 escape moment
    printf("cycle st ctx_it ctx_iter_cnt esc done phase_d4 escape_pl  mag_sq_r\n");
    while (!dut->done_a && cycle < 200) {
        tick(dut);
        cycle++;
        int it  = (int)root->iter_quad__DOT__ctx_iter[0];
        int ic  = (int)root->iter_quad__DOT__ctx_iter_count[0];
        int esc = (int)dut->escaped_a;
        int dn  = (int)dut->done_a;
        int st  = (int)root->iter_quad__DOT__ctx_state[0];
        int pd4 = (int)root->iter_quad__DOT__phase_d4;
        int ep  = (int)root->iter_quad__DOT__escape_pl;
        int zro = (int)root->iter_quad__DOT__zr_sq_ovf;
        int zio = (int)root->iter_quad__DOT__zi_sq_ovf;
        double mag_sq_r_d = (double)(int64_t)root->iter_quad__DOT__mag_sq_r / (double)((uint64_t)1 << 56);
        double mag_sq_w_d = (double)(int64_t)root->iter_quad__DOT__mag_sq_w / (double)((uint64_t)1 << 56);
        double zr_sq_d = (double)(int64_t)root->iter_quad__DOT__zr_sq / (double)((uint64_t)1 << 56);
        double zi_sq_d = (double)(int64_t)root->iter_quad__DOT__zi_sq / (double)((uint64_t)1 << 56);
        const char* sn = "?";
        switch(st) { case 0:sn="IDL";break;case 1:sn="PQ ";break;case 2:sn="CAR";break;
                      case 3:sn="BUL";break;case 4:sn="BL3";break;case 5:sn="ITR";break;case 6:sn="DON";break;}
        // Also extract raw zi_sq for sign-bit inspection
        uint64_t zi_sq_raw = (uint64_t)root->iter_quad__DOT__zi_sq;
        printf("%4lu %s it=%d ic=%d esc=%d dn=%d p4=%d ep=%d zr_ovf=%02x zi_ovf=%02x "
               "zi_sq_bit63=%d msw=%+.4f zr_sq=%+.4f zi_sq=%+.4f zi_sq_raw=0x%016lx\n",
               cycle, sn, it, ic, esc, dn, pd4, ep, zro, zio,
               (int)(zi_sq_raw >> 63), mag_sq_w_d, zr_sq_d, zi_sq_d, zi_sq_raw);
    }
    printf("\nFinal: iter_count_a=%d escaped_a=%d done_a=%d  (cycle=%lu)\n",
           (int)dut->iter_count_a, (int)dut->escaped_a, (int)dut->done_a, cycle);

    delete dut;
    return 0;
}
