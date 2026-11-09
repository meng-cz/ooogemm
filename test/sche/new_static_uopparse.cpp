#include "Vnew_static_uopparse.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <vector>
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
struct BlockShape { uint32_t m, n; };
constexpr BlockShape choose_block() {
    BlockShape best{1, 1};
    uint32_t best_area = 1, best_balance = 0;
    for (uint32_t m = 1; m <= ABUF_SIZE_TEST / 2; ++m) {
        for (uint32_t n = 1; n <= BBUF_SIZE_TEST / 2; ++n) {
            const uint32_t area = m * n;
            const uint32_t balance = m > n ? m - n : n - m;
            if (area <= kPaccGroupSize &&
                (area > best_area || (area == best_area && balance < best_balance))) {
                best = {m, n}; best_area = area; best_balance = balance;
            }
        }
    }
    return best;
}
constexpr uint32_t kBlockM = choose_block().m;
constexpr uint32_t kBlockN = choose_block().n;

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

// Transaction-level reference: describe the three ordered streams without
// duplicating the RTL FSM, prepare/issue stages, or completion counters.
struct LoadUop {
    uint32_t is_b, group, addr, abuf, bbuf, rows;
    size_t block;
    uint32_t wave;
};
struct GemmUop {
    uint32_t group, abuf, bbuf, pacc, accum;
    size_t block;
    uint32_t wave;
};
struct OutputUop { uint32_t group, addr, pacc; };
struct Reference {
    std::vector<LoadUop> load;
    std::vector<GemmUop> gemm;
    std::vector<OutputUop> output;
    size_t blocks = 0;
};
Reference reference_for(int m, int n, int k, int batches) {
    const uint32_t tm = (m + kSubtileM - 1) / kSubtileM;
    const uint32_t tn = (n + kSubtileN - 1) / kSubtileN;
    const uint32_t tk = (k + kSubtileK - 1) / kSubtileK;
    const uint32_t cap = std::min<uint32_t>({ABUF_SIZE_TEST / 2, BBUF_SIZE_TEST / 2, kPaccGroupSize});
    const bool merge = batches > 1 && tm * tn != 0 && tm * tn <= cap / 2;
    struct Block { uint32_t batch, mb, nb, bm, bn, first, count; };
    std::vector<Block> blocks;
    if (merge) {
        const uint32_t batches_per_block = cap / (tm * tn);
        for (uint32_t b = 0; b < static_cast<uint32_t>(batches); b += batches_per_block) {
            const uint32_t count = std::min(batches_per_block, static_cast<uint32_t>(batches) - b);
            blocks.push_back({b, 0, 0, tm, tn, b * tm * tn, count * tm * tn});
        }
    } else {
        for (uint32_t b = 0; b < static_cast<uint32_t>(batches); ++b)
            for (uint32_t mb = 0; mb < tm; mb += kBlockM)
                for (uint32_t nb = 0; nb < tn; nb += kBlockN)
                    blocks.push_back({b, mb, nb, std::min(kBlockM, tm - mb),
                                      std::min(kBlockN, tn - nb), 0, 0});
    }
    const auto rows = [](uint32_t dim, uint32_t tile, uint32_t size) {
        return std::min(size, dim - tile * size);
    };
    Reference ref;
    ref.blocks = blocks.size();
    for (size_t id = 0; id < blocks.size(); ++id) {
        const Block& b = blocks[id];
        const uint32_t acc = static_cast<uint32_t>(id & 1) * kPaccGroupSize;
        for (uint32_t wave = 0; wave < tk; ++wave) {
            const uint32_t group = static_cast<uint32_t>((id * tk + wave) & 1);
            for (uint32_t i = 0; i < (merge ? b.count : b.bm); ++i) {
                const uint32_t flat = b.first + i;
                const uint32_t batch = merge ? flat / (tm * tn) : b.batch;
                const uint32_t row = merge ? (flat % (tm * tn)) / tn : b.mb + i;
                ref.load.push_back({0, group, 0x10000u + batch * tm * tk + row * tk + wave,
                                    group * (ABUF_SIZE_TEST / 2) + i, 0,
                                    rows(m, row, kSubtileM), id, wave});
            }
            for (uint32_t i = 0; i < (merge ? b.count : b.bn); ++i) {
                const uint32_t flat = b.first + i;
                const uint32_t batch = merge ? flat / (tm * tn) : b.batch;
                const uint32_t col = merge ? flat % tn : b.nb + i;
                ref.load.push_back({1, group, 0x20000u + batch * tk * tn + wave * tn + col,
                                    0, group * (BBUF_SIZE_TEST / 2) + i,
                                    rows(n, col, kSubtileN), id, wave});
            }
            for (uint32_t i = 0; i < (merge ? b.count : b.bm); ++i) {
                for (uint32_t j = 0; j < (merge ? 1u : b.bn); ++j) {
                    ref.gemm.push_back({group, group * (ABUF_SIZE_TEST / 2) + i,
                                       group * (BBUF_SIZE_TEST / 2) + (merge ? i : j),
                                       acc + (merge ? i : i * b.bn + j), wave != 0, id, wave});
                }
            }
        }
        for (uint32_t i = 0; i < (merge ? b.count : b.bm); ++i) {
            for (uint32_t j = 0; j < (merge ? 1u : b.bn); ++j) {
                const uint32_t offset = merge ? b.first + i :
                    b.batch * tm * tn + (b.mb + i) * tn + b.nb + j;
                ref.output.push_back({static_cast<uint32_t>(id & 1), 0x30000u + offset,
                                      acc + (merge ? i : i * b.bn + j)});
            }
        }
    }
    return ref;
}

void run_case(const std::string& name, int m, int n, int k, int batch,
              int load_latency, int gemm_latency, int output_latency,
              bool check_block_boundary_overlap = false,
              bool check_completion_fence = false,
              bool always_ready = false,
              int reset_after = -1) {
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

    if (reset_after >= 0) {
        tb.dut.cmd_valid_i = 1;
        tb.tick();
        tb.dut.cmd_valid_i = 0;
        for (int i = 0; i < reset_after; ++i) tb.tick();
        tb.reset();
        tb.dut.eval();
        if (!tb.dut.cmd_ready_o || tb.dut.load_valid_o || tb.dut.gemm_valid_o ||
            tb.dut.output_valid_o || tb.dut.cmd_done_valid_o)
            fail(name + ": reset did not flush prepared/stalled transactions");
    }

    bool cmd_sent = false;
    uint64_t load_issued = 0, gemm_issued = 0, output_issued = 0;
    uint64_t load_done = 0, gemm_done = 0, output_done = 0;
    using LoadFields = std::array<uint32_t, 6>;
    using GemmFields = std::array<uint32_t, 5>;
    using OutputFields = std::array<uint32_t, 3>;
    bool have_load_hold = false, have_gemm_hold = false, have_output_hold = false;
    LoadFields held_load{};
    GemmFields held_gemm{};
    OutputFields held_output{};
    bool saw_next_wave_before_gemm_completion = false;
    int output_half_outstanding[2] = {0, 0};
    const Reference ref = reference_for(m, n, k, batch);
    std::vector<uint64_t> wave0_first(ref.blocks, UINT64_MAX), wave0_last(ref.blocks, 0);
    std::vector<uint64_t> wave1_load_first(ref.blocks, UINT64_MAX), wave1_load_last(ref.blocks, 0);
    uint64_t last_load_cycle = 0, last_gemm_cycle = 0, last_output_cycle = 0;
    std::deque<uint32_t> output_halves;
    std::deque<Event> events;

    for (int guard = 0; guard < 200000; ++guard) {
        tb.dut.cmd_valid_i = cmd_sent ? 0 : 1;
        tb.dut.load_ready_i = always_ready || ((tb.cycle % 19) >= 7);
        tb.dut.gemm_ready_i = always_ready || ((tb.cycle % 23) >= 9);
        tb.dut.output_ready_i = always_ready || ((tb.cycle % 29) >= 11);
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

        const LoadFields load_fields{static_cast<uint32_t>(tb.dut.load_is_b_o),
            static_cast<uint32_t>(tb.dut.load_group_o), static_cast<uint32_t>(tb.dut.load_addr_o),
            static_cast<uint32_t>(tb.dut.load_abufidx_o), static_cast<uint32_t>(tb.dut.load_bbufidx_o),
            static_cast<uint32_t>(tb.dut.load_valid_rows_o)};
        const GemmFields gemm_fields{static_cast<uint32_t>(tb.dut.gemm_group_o),
            static_cast<uint32_t>(tb.dut.gemm_abufidx_o), static_cast<uint32_t>(tb.dut.gemm_bbufidx_o),
            static_cast<uint32_t>(tb.dut.gemm_paccidx_o), static_cast<uint32_t>(tb.dut.gemm_accum_o)};
        const OutputFields output_fields{static_cast<uint32_t>(tb.dut.output_group_o),
            static_cast<uint32_t>(tb.dut.output_addr_o), static_cast<uint32_t>(tb.dut.output_paccidx_o)};
        if (have_load_hold && (!tb.dut.load_valid_o || load_fields != held_load))
            fail(name + ": LOAD changed or valid dropped while stalled");
        if (have_gemm_hold && (!tb.dut.gemm_valid_o || gemm_fields != held_gemm))
            fail(name + ": GEMM changed or valid dropped while stalled");
        if (have_output_hold && (!tb.dut.output_valid_o || output_fields != held_output))
            fail(name + ": OUTPUT changed or valid dropped while stalled");
        have_load_hold = tb.dut.load_valid_o && !load_fire;
        have_gemm_hold = tb.dut.gemm_valid_o && !gemm_fire;
        have_output_hold = tb.dut.output_valid_o && !output_fire;
        held_load = load_fields; held_gemm = gemm_fields; held_output = output_fields;

        if (load_fire) {
            if (load_issued >= ref.load.size()) fail(name + ": extra LOAD");
            const LoadUop& e = ref.load[load_issued];
            if (load_fields != LoadFields{e.is_b, e.group, e.addr, e.abuf, e.bbuf, e.rows})
                fail(name + ": LOAD fields/order mismatch at " + std::to_string(load_issued) +
                     " addr=" + std::to_string(load_fields[2]) + " expected=" + std::to_string(e.addr));
            if (last_load_cycle && tb.cycle - last_load_cycle < 2) fail(name + ": LOAD issue interval < 2");
            if (always_ready && load_issued && ref.load[load_issued - 1].block == e.block &&
                ref.load[load_issued - 1].wave == e.wave && tb.cycle - last_load_cycle != 2)
                fail(name + ": LOAD continuous throughput is not one per two cycles");
            last_load_cycle = tb.cycle;
            if (e.wave == 1) {
                wave1_load_first[e.block] = std::min(wave1_load_first[e.block], tb.cycle);
                wave1_load_last[e.block] = tb.cycle;
            }
        }
        if (gemm_fire) {
            if (gemm_issued >= ref.gemm.size()) fail(name + ": extra GEMM");
            const GemmUop& e = ref.gemm[gemm_issued];
            if (gemm_fields != GemmFields{e.group, e.abuf, e.bbuf, e.pacc, e.accum})
                fail(name + ": GEMM fields/order mismatch at " + std::to_string(gemm_issued));
            if (last_gemm_cycle && tb.cycle - last_gemm_cycle < 2) fail(name + ": GEMM issue interval < 2");
            if (always_ready && gemm_issued && ref.gemm[gemm_issued - 1].block == e.block &&
                ref.gemm[gemm_issued - 1].wave == e.wave && tb.cycle - last_gemm_cycle != 2)
                fail(name + ": GEMM continuous throughput is not one per two cycles");
            last_gemm_cycle = tb.cycle;
            if (e.wave == 0) {
                wave0_first[e.block] = std::min(wave0_first[e.block], tb.cycle);
                wave0_last[e.block] = tb.cycle;
            }
        }
        if (output_fire) {
            if (output_issued >= ref.output.size()) fail(name + ": extra OUTPUT");
            const OutputUop& e = ref.output[output_issued];
            if (output_fields != OutputFields{e.group, e.addr, e.pacc})
                fail(name + ": OUTPUT fields/order mismatch at " + std::to_string(output_issued));
            if (last_output_cycle && tb.cycle - last_output_cycle < 2) fail(name + ": OUTPUT issue interval < 2");
            if (always_ready && output_issued && ref.output[output_issued - 1].group == e.group &&
                tb.cycle - last_output_cycle != 2)
                fail(name + ": OUTPUT continuous throughput is not one per two cycles");
            last_output_cycle = tb.cycle;
        }

        if (cmd_fire) cmd_sent = true;
        if (load_fire) {
            ++load_issued;
            events.push_back({tb.cycle + static_cast<uint64_t>(load_latency), 'L'});
        }
        if (gemm_fire) {
            ++gemm_issued;
            events.push_back({tb.cycle + static_cast<uint64_t>(gemm_latency), 'G'});
        }
        if (output_fire) {
            ++output_issued;
            const uint32_t output_half =
                static_cast<uint32_t>(tb.dut.output_paccidx_o) / kPaccGroupSize;
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
            const uint64_t tm = (static_cast<uint64_t>(m) + kSubtileM - 1) / kSubtileM;
            const uint64_t tn = (static_cast<uint64_t>(n) + kSubtileN - 1) / kSubtileN;
            const uint64_t tk = (static_cast<uint64_t>(k) + kSubtileK - 1) / kSubtileK;
            const uint64_t expected_load = ref.load.size();
            if (load_issued != expected_load) {
                fail(name + ": LOAD count=" + std::to_string(load_issued) +
                     " expected=" + std::to_string(expected_load));
            }
            // Two-cycle issue adds bubbles in valid; compare execution
            // windows rather than requiring LOAD/GEMM valid in the same cycle.
            if (check_block_boundary_overlap && ref.blocks > 1 && tk > 1) {
                bool overlap = false;
                for (size_t block = 1; block < ref.blocks; ++block) {
                    if (wave1_load_first[block] < wave0_last[block] + gemm_latency &&
                        wave0_first[block] < wave1_load_last[block] + load_latency)
                        overlap = true;
                }
                if (!overlap) fail(name + ": no block-boundary LOAD/GEMM execution overlap");
            }
            if (check_completion_fence &&
                !saw_next_wave_before_gemm_completion) {
                fail(name + ": GEMM completion still blocked K-group progress");
            }
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
        run_case("single_batch_multi_tile_no_merge", 8, 16, 32, 1, 11, 17, 23);
        run_case("independent_full_batch_blocks", 16, 16, 32, 2, 7, 15, 27);
        run_case("slow_completion_fence", 8, 16, 128, 1, 3, 100, 7,
                 false, true);
        run_case("tail_rows_batched", kSubtileM + 1, 2 * kSubtileN - 1,
                 3 * kSubtileK + 1, 5, 3, 17, 29);
        run_case("merged_mn_rollover", 2 * kSubtileM - 1, 2 * kSubtileN - 1,
                 2 * kSubtileK, 5, 5, 13, 23);
        run_case("two_cycle_continuous_streams", 2 * kBlockM * kSubtileM,
                 2 * kBlockN * kSubtileN, 3 * kSubtileK, 1,
                 5, 13, 23, true, false, true);
        run_case("reset_during_setup", kSubtileM, kSubtileN, 2 * kSubtileK,
                 1, 3, 7, 11, false, false, true, 0);
        run_case("reset_with_stalled_load", kSubtileM, kSubtileN, 2 * kSubtileK,
                 1, 3, 7, 11, false, false, true, 9);
        std::cout << "new_static_uopparse tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << "new_static_uopparse test failed: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
