// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Minimal Verilator 4.x driver for tests/iommu_ds_if_write_tb.sv.
// Drives clk_i/rst_n, evaluates the model, and stops only on normal $finish.
// A timeout returns nonzero; $fatal is left to Verilator's fatal handler.

#include "Viommu_ds_if_write_tb.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>

static const int RESET_CYCLES = 10;
static const int MAX_CYCLES   = 25000;  // > SV MaxCycles (20000)
static vluint64_t sim_time = 0;
double sc_time_stamp() { return static_cast<double>(sim_time); }

static void tick(Viommu_ds_if_write_tb* top) {
    top->clk_i = 0;
    ++sim_time;
    top->eval();
    top->clk_i = 1;
    ++sim_time;
    top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    Viommu_ds_if_write_tb* top = new Viommu_ds_if_write_tb;

    top->clk_i = 0;
    top->rst_n = 0;
    top->eval();

    for (int i = 0; i < RESET_CYCLES; ++i) {
        tick(top);
    }

    top->rst_n = 1;
    top->eval();

    int cycles = 0;
    while (!Verilated::gotFinish() && cycles < MAX_CYCLES) {
        tick(top);
        ++cycles;
    }

    if (!Verilated::gotFinish()) {
        std::fprintf(stderr,
                     "iommu_ds_if_write_tb: timeout after %d cycles "
                     "(no normal $finish)\n",
                     cycles);
        top->final();
        delete top;
        return 1;
    }

    top->final();
    delete top;
    return 0;
}
