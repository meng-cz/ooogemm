#include "Vnew_static_uopparse.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <stdexcept>

namespace {

struct Completion {
    uint64_t due_cycle;
    char kind;
};

void tick(Vnew_static_uopparse& dut, uint64_t& cycle) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
    ++cycle;
}

void print_addr(uint32_t addr) {
    std::cout << "0x" << std::hex << std::setw(8) << std::setfill('0')
              << addr << std::dec << std::setfill(' ');
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vnew_static_uopparse dut;
    uint64_t cycle = 0;

    dut.clk = 0;
    dut.rst_n = 0;
    dut.cmd_valid_i = 0;
    dut.load_ready_i = 1;
    dut.gemm_ready_i = 1;
    dut.output_ready_i = 1;
    dut.load_done_valid_i = 0;
    dut.gemm_done_valid_i = 0;
    dut.output_done_valid_i = 0;
    dut.cmd_a_base_i = 0x00010000;
    dut.cmd_b_base_i = 0x00020000;
    dut.cmd_c_base_i = 0x00030000;
    dut.cmd_m_i = 64;
    dut.cmd_n_i = 64;
    dut.cmd_k_i = 64;
    dut.cmd_batch_i = 1;
    dut.eval();
    for (int i = 0; i < 3; ++i) tick(dut, cycle);
    dut.rst_n = 1;

    // Different fixed completion delays exercise the parser's independent
    // streams while retaining a deterministic, easy-to-read trace.
    constexpr uint64_t kLoadLatency = 3;
    constexpr uint64_t kGemmLatency = 7;
    constexpr uint64_t kOutputLatency = 5;
    std::deque<Completion> completions;
    bool cmd_sent = false;
    bool saw_any_uop = false;
    uint64_t instruction_group = 0;
    uint64_t load_count = 0, gemm_count = 0, output_count = 0;

    for (unsigned guard = 0; guard < 100000; ++guard) {
        dut.cmd_valid_i = cmd_sent ? 0 : 1;
        dut.load_done_valid_i = 0;
        dut.gemm_done_valid_i = 0;
        dut.output_done_valid_i = 0;

        // The interface supplies one completion indication per unit per cycle.
        for (auto it = completions.begin(); it != completions.end();) {
            if (it->due_cycle <= cycle) {
                if (it->kind == 'L' && !dut.load_done_valid_i) {
                    dut.load_done_valid_i = 1;
                    it = completions.erase(it);
                    continue;
                }
                if (it->kind == 'G' && !dut.gemm_done_valid_i) {
                    dut.gemm_done_valid_i = 1;
                    it = completions.erase(it);
                    continue;
                }
                if (it->kind == 'O' && !dut.output_done_valid_i) {
                    dut.output_done_valid_i = 1;
                    it = completions.erase(it);
                    continue;
                }
            }
            ++it;
        }

        dut.eval();
        if (dut.cmd_valid_i && dut.cmd_ready_o) cmd_sent = true;

        const bool load_fire = dut.load_valid_o && dut.load_ready_i;
        const bool gemm_fire = dut.gemm_valid_o && dut.gemm_ready_i;
        const bool output_fire = dut.output_valid_o && dut.output_ready_i;

        // load/gemm/output_group_o identify physical ping-pong halves, not
        // logical instruction groups.  A logical group begins when the first
        // GEMM of a K-wave or the first OUTPUT of an output block is issued.
        // LOAD issued in that cycle belongs to the same group and prepares the
        // following group's GEMM input.
        constexpr unsigned kPaccGroupSize = 4;
        const bool starts_gemm_group = gemm_fire &&
            (static_cast<unsigned>(dut.gemm_paccidx_o) % kPaccGroupSize) == 0;
        const bool starts_output_group = output_fire &&
            (static_cast<unsigned>(dut.output_paccidx_o) % kPaccGroupSize) == 0;
        if (saw_any_uop && (starts_gemm_group || starts_output_group)) {
            std::cout << '\n';
            ++instruction_group;
        }

        if (load_fire) {
            const unsigned group = static_cast<unsigned>(dut.load_group_o);
            std::cout << (dut.load_is_b_o ? "LOAD_B" : "LOAD_A")
                      << " igroup=" << instruction_group
                      << " cycle=" << cycle << " group=" << group << " addr=";
            print_addr(static_cast<uint32_t>(dut.load_addr_o));
            if (dut.load_is_b_o) {
                std::cout << " bbuf=" << static_cast<unsigned>(dut.load_bbufidx_o);
            } else {
                std::cout << " abuf=" << static_cast<unsigned>(dut.load_abufidx_o);
            }
            std::cout << " rows=" << static_cast<unsigned>(dut.load_valid_rows_o) << '\n';
            completions.push_back({cycle + kLoadLatency, 'L'});
            ++load_count;
        }
        if (gemm_fire) {
            std::cout << "GEMM   igroup=" << instruction_group
                      << " cycle=" << cycle
                      << " group=" << static_cast<unsigned>(dut.gemm_group_o)
                      << " abuf=" << static_cast<unsigned>(dut.gemm_abufidx_o)
                      << " bbuf=" << static_cast<unsigned>(dut.gemm_bbufidx_o)
                      << " pacc=" << static_cast<unsigned>(dut.gemm_paccidx_o)
                      << " accum=" << static_cast<unsigned>(dut.gemm_accum_o) << '\n';
            completions.push_back({cycle + kGemmLatency, 'G'});
            ++gemm_count;
        }
        if (output_fire) {
            std::cout << "OUTPUT igroup=" << instruction_group
                      << " cycle=" << cycle
                      << " group=" << static_cast<unsigned>(dut.output_group_o) << " addr=";
            print_addr(static_cast<uint32_t>(dut.output_addr_o));
            std::cout << " pacc=" << static_cast<unsigned>(dut.output_paccidx_o) << '\n';
            completions.push_back({cycle + kOutputLatency, 'O'});
            ++output_count;
        }
        saw_any_uop = saw_any_uop || load_fire || gemm_fire || output_fire;

        tick(dut, cycle);
        if (cmd_sent && dut.cmd_done_valid_o) {
            if (!completions.empty()) throw std::runtime_error("command completed before uop completions");
            if (load_count != 256 || gemm_count != 256 || output_count != 64) {
                throw std::runtime_error("unexpected uop counts");
            }
            return 0;
        }
    }

    throw std::runtime_error("uop export timed out");
}
