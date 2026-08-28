#include "Vblocksel.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int kSaWidth = 16;
constexpr int kAbuf = 12;
constexpr int kBbuf = 12;
constexpr int kAcc = 16;

struct Case {
    uint32_t m;
    uint32_t n;
    uint32_t k;
    uint32_t batch;
    uint32_t bm;
    uint32_t bn;
};

[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error(message);
}

class Testbench {
public:
    Testbench() {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
        dut_.eval();
        for (int i = 0; i < 3; ++i) tick();
        dut_.rst_n = 1;
        tick();
    }

    void run_case(const Case& tc) {
        uint32_t tag = 0x1000u + tc.m * 17u + tc.n;
        while (dut_.cmd_ready_o == 0) tick();

        dut_.cmd_valid_i = 1;
        dut_.cmd_a_base_i = 0x10000000u + tag;
        dut_.cmd_b_base_i = 0x20000000u + tag;
        dut_.cmd_c_base_i = 0x30000000u + tag;
        dut_.cmd_m_i = tc.m;
        dut_.cmd_n_i = tc.n;
        dut_.cmd_k_i = tc.k;
        dut_.cmd_batch_i = tc.batch;
        if (dut_.cmd_ready_o == 0) fail("selector did not accept command");
        tick();
        dut_.cmd_valid_i = 0;

        for (int cycle = 0; cycle < 100; ++cycle) {
            if (dut_.gemm_valid_o != 0) {
                check_output(tc, tag);
                dut_.gemm_ready_i = 1;
                tick();
                dut_.gemm_ready_i = 0;
                if (dut_.cmd_ready_o == 0) {
                    fail("selector did not return to idle after output handshake");
                }
                return;
            }
            tick();
        }
        std::ostringstream os;
        os << "timeout selecting block for M=" << tc.m << " N=" << tc.n;
        fail(os.str());
    }

private:
    Vblocksel dut_;

    void clear_inputs() {
        dut_.cmd_valid_i = 0;
        dut_.cmd_a_base_i = 0;
        dut_.cmd_b_base_i = 0;
        dut_.cmd_c_base_i = 0;
        dut_.cmd_m_i = 0;
        dut_.cmd_n_i = 0;
        dut_.cmd_k_i = 0;
        dut_.cmd_batch_i = 0;
        dut_.gemm_ready_i = 0;
    }

    void tick() {
        dut_.clk = 0;
        dut_.eval();
        dut_.clk = 1;
        dut_.eval();
        dut_.clk = 0;
        dut_.eval();
    }

    void check_output(const Case& tc, uint32_t tag) {
        if (dut_.block_m_o != tc.bm || dut_.block_n_o != tc.bn) {
            std::ostringstream os;
            os << "wrong block for M=" << tc.m << " N=" << tc.n
               << ": got " << static_cast<unsigned>(dut_.block_m_o)
               << "x" << static_cast<unsigned>(dut_.block_n_o)
               << ", expected " << tc.bm << "x" << tc.bn;
            fail(os.str());
        }
        if (dut_.gemm_a_base_o != 0x10000000u + tag ||
            dut_.gemm_b_base_o != 0x20000000u + tag ||
            dut_.gemm_c_base_o != 0x30000000u + tag ||
            dut_.gemm_m_o != tc.m || dut_.gemm_n_o != tc.n ||
            dut_.gemm_k_o != tc.k || dut_.gemm_batch_o != tc.batch) {
            fail("GEMM command was not transparently forwarded");
        }
    }
};

}  // namespace

int main() {
    try {
        Testbench tb;
        tb.run_case({16, 256, 256, 3, 1, 12});
        tb.run_case({256, 256, 256, 1, 4, 4});
        tb.run_case({256, 16, 256, 2, 12, 1});
        tb.run_case({32, 256, 64, 1, 2, 8});
        tb.run_case({17, 17, 32, 1, 2, 2});
        std::cout << "blocksel tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "blocksel test failed: " << error.what() << "\n";
        return 1;
    }
}
