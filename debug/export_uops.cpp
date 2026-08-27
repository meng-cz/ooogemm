#include "Vstatic_uopparse.h"
#include "verilated.h"

#include <cstdint>
#include <iomanip>
#include <iostream>

namespace {

const char* type_name(unsigned type) {
    switch (type) {
        case 0: return "LOAD_A";
        case 1: return "LOAD_B";
        case 2: return "GEMM";
        case 3: return "OUTPUT";
        case 4: return "BUF_SWAP";
        case 5: return "ACC_FENCE";
        default: return "UNKNOWN";
    }
}

void tick(Vstatic_uopparse& dut, uint64_t& cycle) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
    ++cycle;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vstatic_uopparse dut;
    uint64_t cycle = 0;

    dut.clk = 0;
    dut.rst_n = 0;
    dut.cmd_valid_i = 0;
    dut.uop_ready_i = 1;
    dut.cmd_a_base_i = 0x10000;
    dut.cmd_b_base_i = 0x20000;
    dut.cmd_c_base_i = 0x30000;
    dut.cmd_m_i = 64;
    dut.cmd_n_i = 64;
    dut.cmd_k_i = 64;
    dut.cmd_batch_i = 1;
    dut.eval();

    for (int i = 0; i < 3; ++i) {
        tick(dut, cycle);
    }
    dut.rst_n = 1;

    bool sent = false;
    unsigned count[6] = {};
    uint64_t last_uop_cycle = 0;
    std::cout << "# static_uopparse trace: SA_WIDTH=8 SUBTILE_K=16 "
                 "ABUF_SIZE=4 BBUF_SIZE=4 PACC_NUM=4 "
                 "B=1 M=64 N=64 K=64\n";

    for (unsigned guard = 0; guard < 20000; ++guard) {
        dut.cmd_valid_i = sent ? 0 : 1;
        dut.eval();

        const bool cmd_fire = dut.cmd_valid_i && dut.cmd_ready_o;
        const bool uop_valid = dut.uop_valid_o;
        const bool uop_fire = uop_valid && dut.uop_ready_i;
        if (cmd_fire) {
            sent = true;
            std::cout << "# cmd_fire cycle=" << cycle << "\n";
        }
        if (uop_fire) {
            const unsigned type = static_cast<unsigned>(dut.uop_type_o);
            ++count[type < 6 ? type : 0];
            last_uop_cycle = cycle;
            std::cout << "uop cycle=" << std::setw(5) << cycle
                      << " type=" << type_name(type)
                      << " addr=0x" << std::hex << std::setw(8)
                      << std::setfill('0') << static_cast<uint32_t>(dut.uop_addr_o)
                      << std::dec << std::setfill(' ')
                      << " abuf=" << static_cast<unsigned>(dut.uop_abufidx_o)
                      << " bbuf=" << static_cast<unsigned>(dut.uop_bbufidx_o)
                      << " pacc=" << static_cast<unsigned>(dut.uop_paccidx_o)
                      << " rows=" << static_cast<unsigned>(dut.uop_valid_rows_o)
                      << " accum=" << static_cast<unsigned>(dut.uop_accum_o)
                      << "\n";
        }

        tick(dut, cycle);
        if (sent && !dut.uop_valid_o && dut.cmd_ready_o) {
            std::cout << "# done cycle=" << cycle
                      << " last_uop_cycle=" << last_uop_cycle << "\n"
                      << "# counts LOAD_A=" << count[0]
                      << " LOAD_B=" << count[1]
                      << " GEMM=" << count[2]
                      << " OUTPUT=" << count[3]
                      << " BUF_SWAP=" << count[4]
                      << " ACC_FENCE=" << count[5] << "\n";
            return 0;
        }
    }

    std::cerr << "uop trace timeout\n";
    return 1;
}
