#include "Vpixel_pipeline.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <set>

static Vpixel_pipeline* top;

static int64_t to_fp(double val) {
    return (int64_t)std::llround(val * (double)(1ULL << 56));
}

static void tick() {
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

static void reset() {
    top->rst_n = 0;
    top->start_frame = 0;
    for (int i = 0; i < 4; ++i) tick();
    top->rst_n = 1;
    tick();
}

static int sw_iter(double cr, double ci, int max_iter) {
    double zr = 0.0;
    double zi = 0.0;
    for (int i = 0; i < max_iter; ++i) {
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
    top = new Vpixel_pipeline;

    const int H_RES = 8;
    const int V_RES = 8;
    const int max_iter = 32;

    reset();

    top->fractal_type = 0;
    top->max_iter = max_iter;
    top->julia_cr = 0;
    top->julia_ci = 0;
    top->center_x = to_fp(-0.5);
    top->center_y = to_fp(0.0);
    top->step = to_fp(0.5);

    top->start_frame = 1;
    tick();
    top->start_frame = 0;

    int iter_map[V_RES][H_RES];
    bool esc_map[V_RES][H_RES];
    for (int y = 0; y < V_RES; ++y) {
        for (int x = 0; x < H_RES; ++x) {
            iter_map[y][x] = -1;
            esc_map[y][x] = false;
        }
    }

    int cycles = 0;
    while (!top->frame_done && cycles < 20000) {
        tick();
        ++cycles;
        if (top->result_valid) {
            int x = top->result_x;
            int y = top->result_y;
            iter_map[y][x] = top->result_iter;
            esc_map[y][x] = top->result_escaped;
        }
    }

    bool ok = top->frame_done;
    if (!ok) std::printf("frame_done timeout\n");

    for (int y = 0; y < V_RES; ++y) {
        for (int x = 0; x < H_RES; ++x) {
            double cr = -2.5 + x * 0.5;
            double ci = -2.0 + y * 0.5;
            int ref = sw_iter(cr, ci, max_iter);
            bool ref_esc = ref < max_iter;
            if (iter_map[y][x] != ref || esc_map[y][x] != ref_esc) {
                std::printf("mismatch (%d,%d): hw iter=%d esc=%d ref iter=%d esc=%d\n",
                            x, y, iter_map[y][x], esc_map[y][x], ref, ref_esc);
                ok = false;
            }
        }
    }

    top->final();
    delete top;
    return ok ? 0 : 1;
}
