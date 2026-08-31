#include "Vblocksel.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

#ifndef SUBTILE_M_TEST
#define SUBTILE_M_TEST 16
#endif
#ifndef SUBTILE_N_TEST
#define SUBTILE_N_TEST 16
#endif
#ifndef LOGIC_ABUF_SIZE_TEST
#define LOGIC_ABUF_SIZE_TEST 12
#endif
#ifndef LOGIC_BBUF_SIZE_TEST
#define LOGIC_BBUF_SIZE_TEST 12
#endif
#ifndef LOGIC_ACC_NUM_TEST
#define LOGIC_ACC_NUM_TEST 16
#endif

constexpr int kSaWidth = 16;
constexpr int kSubtileM = SUBTILE_M_TEST;
constexpr int kSubtileN = SUBTILE_N_TEST;
constexpr int kAbuf = LOGIC_ABUF_SIZE_TEST;
constexpr int kBbuf = LOGIC_BBUF_SIZE_TEST;
constexpr int kAcc = LOGIC_ACC_NUM_TEST;

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
        int expected_bm = 1;
        int expected_bn = 1;
        int best_cost = 0x7fffffff;
        int best_area = 1;
        int best_balance = 0x7fffffff;
        const int tm = (tc.m + kSubtileM - 1) / kSubtileM;
        const int tn = (tc.n + kSubtileN - 1) / kSubtileN;
        const int amax = std::min(tm, kAbuf);
        const int bmax = std::min(tn, kBbuf);
        for (int bm = 1; bm <= amax; ++bm) {
            const int bn = std::min(bmax, kAcc / bm);
            if (bn < 1) continue;
            const int cost = tm * ((tn + bn - 1) / bn) +
                             tn * ((tm + bm - 1) / bm);
            const int area = bm * bn;
            const int balance = std::abs(bm - bn);
            if (cost < best_cost ||
                (cost == best_cost && area > best_area) ||
                (cost == best_cost && area == best_area && balance < best_balance)) {
                expected_bm = bm;
                expected_bn = bn;
                best_cost = cost;
                best_area = area;
                best_balance = balance;
            }
        }
        if (dut_.block_m_o != expected_bm || dut_.block_n_o != expected_bn) {
            std::ostringstream os;
            os << "wrong block for M=" << tc.m << " N=" << tc.n
               << ": got " << static_cast<unsigned>(dut_.block_m_o)
               << "x" << static_cast<unsigned>(dut_.block_n_o)
               << ", expected " << expected_bm << "x" << expected_bn;
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
        tb.run_case({16, 256, 256, 3, 0, 0});
        tb.run_case({256, 256, 256, 1, 0, 0});
        tb.run_case({256, 16, 256, 2, 0, 0});
        tb.run_case({32, 256, 64, 1, 0, 0});
        tb.run_case({17, 17, 32, 1, 0, 0});
        std::cout << "blocksel tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "blocksel test failed: " << error.what() << "\n";
        return 1;
    }
}
