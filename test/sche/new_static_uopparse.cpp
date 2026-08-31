#include "Vnew_static_uopparse.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

#ifndef SUBTILE_M_TEST
#define SUBTILE_M_TEST 8
#endif
#ifndef SUBTILE_N_TEST
#define SUBTILE_N_TEST 8
#endif
#ifndef SUBTILE_K_TEST
#define SUBTILE_K_TEST 16
#endif
#ifndef ABUF_SIZE_TEST
#define ABUF_SIZE_TEST 4
#endif
#ifndef BBUF_SIZE_TEST
#define BBUF_SIZE_TEST 4
#endif
#ifndef PACC_NUM_TEST
#define PACC_NUM_TEST 4
#endif

constexpr uint32_t kSubtileM = SUBTILE_M_TEST;
constexpr uint32_t kSubtileN = SUBTILE_N_TEST;
constexpr uint32_t kSubtileK = SUBTILE_K_TEST;
constexpr uint32_t kPaccGroupSize = PACC_NUM_TEST / 2;
constexpr uint32_t kBlockM = ABUF_SIZE_TEST / 2;
constexpr uint32_t kBlockN =
    (BBUF_SIZE_TEST / 2 < PACC_NUM_TEST / 2) ?
    BBUF_SIZE_TEST / 2 : PACC_NUM_TEST / 2;

struct Event {
    uint64_t due;
    char kind;
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

class Tb {
public:
    Vnew_static_uopparse dut;
    uint64_t cycle = 0;

    void tick() {
        dut.clk = 0;
        dut.eval();
        dut.clk = 1;
        dut.eval();
        dut.clk = 0;
        dut.eval();
        ++cycle;
    }

    void reset() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.cmd_valid_i = 0;
        dut.load_ready_i = 0;
        dut.gemm_ready_i = 0;
        dut.output_ready_i = 0;
        dut.load_done_valid_i = 0;
        dut.gemm_done_valid_i = 0;
        dut.output_done_valid_i = 0;
        dut.eval();
        for (int i = 0; i < 3; ++i) tick();
        dut.rst_n = 1;
    }
};

void run_case(const std::string& name, int m, int n, int k, int batch,
              int load_latency, int gemm_latency, int output_latency,
              bool check_block_boundary_overlap = false,
              bool check_completion_fence = false) {
    Tb tb;
    tb.reset();
    tb.dut.cmd_a_base_i = 0x10000;
    tb.dut.cmd_b_base_i = 0x20000;
    tb.dut.cmd_c_base_i = 0x30000;
    tb.dut.cmd_m_i = m;
    tb.dut.cmd_n_i = n;
    tb.dut.cmd_k_i = k;
    tb.dut.cmd_batch_i = batch;
    tb.dut.block_m_i = kBlockM;
    tb.dut.block_n_i = kBlockN;

    bool cmd_sent = false;
    uint64_t load_issued = 0, gemm_issued = 0, output_issued = 0;
    uint64_t load_done = 0, gemm_done = 0, output_done = 0;
    bool have_load_hold = false, have_gemm_hold = false, have_output_hold = false;
    uint32_t held_load_addr = 0, held_gemm_pacc = 0, held_output_addr = 0;
    bool boundary_overlap_checked = false;
    bool saw_next_wave_before_gemm_completion = false;
    bool have_last_load_group = false, have_last_gemm_group = false;
    bool loaded_group_seen[2] = {false, false};
    uint32_t last_load_group = 0, last_gemm_group = 0;
    uint32_t last_gemm_pacc_half = 0;
    int output_half_outstanding[2] = {0, 0};
    std::deque<uint32_t> output_halves;
    std::deque<Event> events;

    for (int guard = 0; guard < 200000; ++guard) {
        tb.dut.cmd_valid_i = cmd_sent ? 0 : 1;
        tb.dut.load_ready_i = ((tb.cycle % 5) != 1);
        tb.dut.gemm_ready_i = ((tb.cycle % 7) != 2);
        tb.dut.output_ready_i = ((tb.cycle % 11) != 3);
        tb.dut.load_done_valid_i = 0;
        tb.dut.gemm_done_valid_i = 0;
        tb.dut.output_done_valid_i = 0;

        for (auto it = events.begin(); it != events.end();) {
            if (it->due <= tb.cycle) {
                if (it->kind == 'L' && !tb.dut.load_done_valid_i) {
                    tb.dut.load_done_valid_i = 1;
                    ++load_done;
                    it = events.erase(it);
                    continue;
                }
                if (it->kind == 'G' && !tb.dut.gemm_done_valid_i) {
                    tb.dut.gemm_done_valid_i = 1;
                    ++gemm_done;
                    it = events.erase(it);
                    continue;
                }
                if (it->kind == 'O' && !tb.dut.output_done_valid_i) {
                    tb.dut.output_done_valid_i = 1;
                    ++output_done;
                    if (output_halves.empty()) {
                        fail(name + ": OUTPUT completion has no issued PACC half");
                    }
                    --output_half_outstanding[output_halves.front()];
                    output_halves.pop_front();
                    it = events.erase(it);
                    continue;
                }
            }
            ++it;
        }

        tb.dut.eval();
        const bool cmd_fire = tb.dut.cmd_valid_i && tb.dut.cmd_ready_o;
        const bool load_fire = tb.dut.load_valid_o && tb.dut.load_ready_i;
        const bool gemm_fire = tb.dut.gemm_valid_o && tb.dut.gemm_ready_i;
        const bool output_fire = tb.dut.output_valid_o && tb.dut.output_ready_i;

        if (check_completion_fence && gemm_fire && tb.dut.gemm_accum_o &&
            gemm_done == 0) {
            saw_next_wave_before_gemm_completion = true;
        }
        // A following block may already have issued GEMMs while the previous
        // block's OUTPUT is being released.  The parser only needs a prior
        // GEMM completion, not a globally empty GEMM pipeline.
        if (check_completion_fence && output_fire && gemm_done == 0) {
            fail(name + ": OUTPUT started before its GEMM completion fence");
        }

        if (check_block_boundary_overlap && !boundary_overlap_checked &&
            tb.dut.gemm_valid_o && !tb.dut.gemm_accum_o && gemm_issued != 0 &&
            (static_cast<uint32_t>(tb.dut.gemm_paccidx_o) %
             kPaccGroupSize) == 0) {
            if (!tb.dut.load_valid_o) {
                fail(name + ": next KWave wave0 GEMM has no overlapping wave1 LOAD");
            }
            if (!have_last_load_group || !have_last_gemm_group) {
                fail(name + ": missing pre-boundary LOAD/GEMM history");
            }
            const uint32_t boundary_gemm_group =
                static_cast<uint32_t>(tb.dut.gemm_group_o);
            if (!loaded_group_seen[boundary_gemm_group]) {
                fail(name + ": next-block wave0 GEMM used a group with no prior LOAD");
            }
            if (last_gemm_group == last_load_group) {
                fail(name + ": final GEMM and next-block wave0 LOAD used the same half");
            }
            if (static_cast<uint32_t>(tb.dut.load_group_o) == boundary_gemm_group) {
                fail(name + ": boundary-group wave1 LOAD did not use the opposite half");
            }
            const uint32_t gemm_half =
                static_cast<uint32_t>(tb.dut.gemm_paccidx_o) / 2;
            if (last_gemm_pacc_half == gemm_half) {
                fail(name + ": KWave advance did not switch the PACC half");
            }
            boundary_overlap_checked = true;
        }

        if (tb.dut.load_valid_o) {
            const uint32_t addr = static_cast<uint32_t>(tb.dut.load_addr_o);
            if (have_load_hold && !load_fire && addr != held_load_addr) {
                fail(name + ": LOAD changed while stalled");
            }
            if (!load_fire) {
                have_load_hold = true;
                held_load_addr = addr;
            } else {
                have_load_hold = false;
            }
        }
        if (tb.dut.gemm_valid_o) {
            const uint32_t pacc = static_cast<uint32_t>(tb.dut.gemm_paccidx_o);
            if (have_gemm_hold && !gemm_fire && pacc != held_gemm_pacc) {
                fail(name + ": GEMM changed while stalled");
            }
            if (!gemm_fire) {
                have_gemm_hold = true;
                held_gemm_pacc = pacc;
            } else {
                have_gemm_hold = false;
            }
        }
        if (tb.dut.output_valid_o) {
            const uint32_t addr = static_cast<uint32_t>(tb.dut.output_addr_o);
            if (have_output_hold && !output_fire && addr != held_output_addr) {
                fail(name + ": OUTPUT changed while stalled");
            }
            if (!output_fire) {
                have_output_hold = true;
                held_output_addr = addr;
            } else {
                have_output_hold = false;
            }
        }

        if (cmd_fire) cmd_sent = true;
        if (load_fire) {
            ++load_issued;
            have_last_load_group = true;
            last_load_group = static_cast<uint32_t>(tb.dut.load_group_o);
            loaded_group_seen[last_load_group] = true;
            events.push_back({tb.cycle + static_cast<uint64_t>(load_latency), 'L'});
        }
        if (gemm_fire) {
            ++gemm_issued;
            have_last_gemm_group = true;
            last_gemm_group = static_cast<uint32_t>(tb.dut.gemm_group_o);
            last_gemm_pacc_half =
                static_cast<uint32_t>(tb.dut.gemm_paccidx_o) / 2;
            if (check_block_boundary_overlap) {
            }
            events.push_back({tb.cycle + static_cast<uint64_t>(gemm_latency), 'G'});
        }
        if (output_fire) {
            ++output_issued;
            const uint32_t output_half =
                static_cast<uint32_t>(tb.dut.output_paccidx_o) / 2;
            ++output_half_outstanding[output_half];
            output_halves.push_back(output_half);
            events.push_back({tb.cycle + static_cast<uint64_t>(output_latency), 'O'});
        }

        tb.tick();
        if (cmd_sent && tb.dut.cmd_done_valid_o) {
            if (!events.empty()) fail(name + ": command done with pending completions");
            if (load_issued != load_done || gemm_issued != gemm_done || output_issued != output_done) {
                fail(name + ": issue/complete mismatch");
            }
            if (load_issued == 0 || gemm_issued == 0 || output_issued == 0) {
                fail(name + ": missing uop class");
            }
            if (check_block_boundary_overlap && !boundary_overlap_checked) {
                fail(name + ": block-boundary overlap was not observed");
            }
            if (check_completion_fence &&
                !saw_next_wave_before_gemm_completion) {
                fail(name + ": GEMM completion still blocked K-group progress");
            }
            const uint64_t tm = (static_cast<uint64_t>(m) + kSubtileM - 1) / kSubtileM;
            const uint64_t tn = (static_cast<uint64_t>(n) + kSubtileN - 1) / kSubtileN;
            const uint64_t tk = (static_cast<uint64_t>(k) + kSubtileK - 1) / kSubtileK;
            const uint64_t expected_gemm = tm * tn * tk * static_cast<uint64_t>(batch);
            const uint64_t expected_output = tm * tn * static_cast<uint64_t>(batch);
            if (gemm_issued != expected_gemm) {
                fail(name + ": GEMM count=" + std::to_string(gemm_issued) +
                     " expected=" + std::to_string(expected_gemm));
            }
            if (output_issued != expected_output) {
                fail(name + ": OUTPUT count=" + std::to_string(output_issued) +
                     " expected=" + std::to_string(expected_output));
            }
            std::cout << name << ": passed cycle=" << tb.cycle
                      << " LOAD=" << load_issued
                      << " GEMM=" << gemm_issued
                      << " OUTPUT=" << output_issued << "\n";
            return;
        }
    }
    fail(name + ": timeout issued L/G/O=" + std::to_string(load_issued) + "/" +
         std::to_string(gemm_issued) + "/" + std::to_string(output_issued) +
         " completed=" + std::to_string(load_done) + "/" +
         std::to_string(gemm_done) + "/" + std::to_string(output_done));
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        run_case("single_wave_variable_latency", 8, 16, 16, 1, 3, 11, 17);
        run_case("multi_wave_variable_latency", 16, 16, 64, 1, 7, 5, 23);
        run_case("larger_k_depth_gemm", 16, 16, 128, 1, 13, 17, 29);
        run_case("multi_block_square_gemm", 32, 32, 64, 1, 9, 13, 21, true);
        run_case("rectangular_multi_block_gemm", 64, 32, 32, 1, 5, 19, 11);
        run_case("large_square_gemm", 128, 128, 256, 1, 17, 23, 31);
        run_case("large_rectangular_gemm", 256, 128, 128, 1, 29, 11, 37);
        run_case("merged_batch_single_tile", 8, 8, 64, 4, 7, 13, 19);
        run_case("merged_batch_partial_block", 8, 16, 32, 3, 11, 17, 23);
        run_case("independent_full_batch_blocks", 16, 16, 32, 2, 7, 15, 27);
        run_case("slow_completion_fence", 8, 16, 128, 1, 3, 100, 7,
                 false, true);
        std::cout << "new_static_uopparse tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << "new_static_uopparse test failed: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
