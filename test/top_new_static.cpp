#include "Vtop_new_static.h"
#include "verilated.h"

#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <sstream>
#include <string>
#include <type_traits>

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 2
#endif
#ifndef SUBTILE_K_TEST
#define SUBTILE_K_TEST 2
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
#ifndef STORE_ROWS_PER_CYCLE_TEST
#define STORE_ROWS_PER_CYCLE_TEST 1
#endif
#ifndef LOAD_DATA_WIDTH_TEST
#define LOAD_DATA_WIDTH_TEST 1024
#endif
#ifndef TOP_NEW_STATIC_PERF_TEST
#define TOP_NEW_STATIC_PERF_TEST 0
#endif
#ifndef PERF_M_TEST
#define PERF_M_TEST 256
#endif
#ifndef PERF_N_TEST
#define PERF_N_TEST 256
#endif
#ifndef PERF_K_TEST
#define PERF_K_TEST 256
#endif
#ifndef PERF_BATCH_TEST
#define PERF_BATCH_TEST 1
#endif

namespace {
struct Response { uint64_t due; uint32_t id; };

template <typename T>
void clear_load_data(T& data) {
    data = 0;
}

template <std::size_t N>
void clear_load_data(VlWide<N>& data) {
    for (std::size_t i = 0; i < N; ++i) data[i] = 0;
}

template <typename T>
void fill_load_data(T& data, uint8_t value) {
    const uint32_t word = uint32_t(value) | (uint32_t(value) << 8) |
                          (uint32_t(value) << 16) | (uint32_t(value) << 24);
    data = static_cast<T>(word);
}

template <std::size_t N>
void fill_load_data(VlWide<N>& data, uint8_t value) {
    const uint32_t word = uint32_t(value) | (uint32_t(value) << 8) |
                          (uint32_t(value) << 16) | (uint32_t(value) << 24);
    for (std::size_t i = 0; i < N; ++i) data[i] = word;
}

template <typename T>
bool store_data_matches(const T& data, uint32_t expected) {
    static_assert(std::is_integral<T>::value, "scalar store port must be integral");
    using unsigned_t = typename std::make_unsigned<T>::type;
    unsigned_t value = static_cast<unsigned_t>(data);
    for (unsigned bit = 0; bit < sizeof(T) * 8; bit += 32) {
        if (static_cast<uint32_t>(value >> bit) != expected) return false;
    }
    return true;
}

template <std::size_t N>
bool store_data_matches(const VlWide<N>& data, uint32_t expected) {
    for (std::size_t word = 0; word < N; ++word) {
        if (data[word] != expected) return false;
    }
    return true;
}

constexpr int choose_block_m(int remaining_m, int remaining_n,
                             int a_group, int b_group, int block_cap) {
    int best_m = 1, best_area = 0, best_balance = 1 << 30;
    for (int cm = 1; cm <= a_group; ++cm) {
        for (int cn = 1; cn <= b_group; ++cn) {
            if (cm > remaining_m || cn > remaining_n || cm * cn > block_cap) continue;
            const int area = cm * cn;
            const int balance = cm >= cn ? cm - cn : cn - cm;
            if (area > best_area ||
                (area == best_area && balance < best_balance) ||
                (area == best_area && balance == best_balance && cm > best_m)) {
                best_m = cm;
                best_area = area;
                best_balance = balance;
            }
        }
    }
    return best_m;
}

constexpr int choose_block_n(int remaining_m, int remaining_n,
                             int a_group, int b_group, int block_cap) {
    int best_m = 1, best_n = 1, best_area = 0, best_balance = 1 << 30;
    for (int cm = 1; cm <= a_group; ++cm) {
        for (int cn = 1; cn <= b_group; ++cn) {
            if (cm > remaining_m || cn > remaining_n || cm * cn > block_cap) continue;
            const int area = cm * cn;
            const int balance = cm >= cn ? cm - cn : cn - cm;
            if (area > best_area ||
                (area == best_area && balance < best_balance) ||
                (area == best_area && balance == best_balance && cm > best_m)) {
                best_m = cm;
                best_n = cn;
                best_area = area;
                best_balance = balance;
            }
        }
    }
    return best_n;
}

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

class Tb {
public:
    Vtop_new_static dut;
    uint64_t cycle = 0;
    std::deque<Response> responses;
    uint64_t load_requests = 0;
    uint64_t store_writes = 0;
    bool command_sent = false;
    uint64_t issue_cycle = 0;

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
        dut.load_mem_req_ready_i = 1;
        dut.load_mem_rsp_valid_i = 0;
        dut.load_mem_rsp_id_i = 0;
        dut.store_mem_wr_ready_i = 1;
        clear_load_data(dut.load_mem_rsp_data_i);
        dut.eval();
        for (int i = 0; i < 5; ++i) tick();
        dut.rst_n = 1;
    }
};

void run_case(const std::string& name, int m, int n, int k, int batch,
              int load_delay, int expected_loads, int expected_stores,
              float expected_value) {
    Tb tb;
    tb.reset();
    tb.dut.cmd_a_base_i = 0x10000;
    tb.dut.cmd_b_base_i = 0x20000;
    tb.dut.cmd_c_base_i = 0x30000;
    tb.dut.cmd_m_i = m;
    tb.dut.cmd_n_i = n;
    tb.dut.cmd_k_i = k;
    tb.dut.cmd_batch_i = batch;

    for (uint64_t guard = 0; guard < 20000000; ++guard) {
        tb.dut.cmd_valid_i = tb.command_sent ? 0 : 1;
#if TOP_NEW_STATIC_PERF_TEST
        tb.dut.load_mem_req_ready_i = 1;
        tb.dut.store_mem_wr_ready_i = 1;
#else
        tb.dut.load_mem_req_ready_i = (tb.cycle % 13) != 5;
        tb.dut.store_mem_wr_ready_i = (tb.cycle % 17) != 7;
#endif
        tb.dut.load_mem_rsp_valid_i = 0;
        tb.dut.load_mem_rsp_id_i = 0;
        clear_load_data(tb.dut.load_mem_rsp_data_i);
        if (!tb.responses.empty() && tb.responses.front().due <= tb.cycle) {
            tb.dut.load_mem_rsp_valid_i = 1;
            tb.dut.load_mem_rsp_id_i = tb.responses.front().id;
            // E4M3 0x38 is exactly 1.0.  Every valid operand is one, so
            // every output element is the K-length dot product.
            fill_load_data(tb.dut.load_mem_rsp_data_i, 0x38);
        }
        tb.dut.eval();

        const bool cmd_fire = tb.dut.cmd_valid_i && tb.dut.cmd_ready_o;
        const bool req_fire = tb.dut.load_mem_req_valid_o &&
                              tb.dut.load_mem_req_ready_i;
        const bool rsp_fire = tb.dut.load_mem_rsp_valid_i &&
                              tb.dut.load_mem_rsp_ready_o;
        const bool wr_fire = tb.dut.store_mem_wr_valid_o &&
                             tb.dut.store_mem_wr_ready_i;
        if (cmd_fire) {
            tb.command_sent = true;
            tb.issue_cycle = tb.cycle;
        }
        if (req_fire) {
            ++tb.load_requests;
            tb.responses.push_back({tb.cycle + static_cast<uint64_t>(load_delay),
                                    static_cast<uint32_t>(tb.dut.load_mem_req_id_o)});
        }
        if (rsp_fire) {
            if (tb.responses.empty()) fail(name + ": unexpected load response");
            tb.responses.pop_front();
        }
        if (wr_fire) {
            ++tb.store_writes;
            uint32_t expected_bits = 0;
            std::memcpy(&expected_bits, &expected_value, sizeof(expected_bits));
            if (!store_data_matches(tb.dut.store_mem_wr_data_o, expected_bits)) {
                fail(name + ": write data mismatch, expected each word=0x" +
                     [&] { std::ostringstream os; os << std::hex << expected_bits; return os.str(); }());
            }
        }
        tb.tick();

        if (tb.command_sent && tb.dut.cmd_done_valid_o) {
            if (!tb.responses.empty()) fail(name + ": command done with pending loads");
            if (tb.load_requests != static_cast<uint64_t>(expected_loads)) {
                fail(name + ": load request count=" + std::to_string(tb.load_requests) +
                     " expected=" + std::to_string(expected_loads));
            }
            if (tb.store_writes != static_cast<uint64_t>(expected_stores)) {
                fail(name + ": store write count=" + std::to_string(tb.store_writes) +
                     " expected=" + std::to_string(expected_stores));
            }
            std::cout << name << ": passed cycle=" << tb.cycle
                      << " loads=" << tb.load_requests
                      << " stores=" << tb.store_writes << "\n";
#if TOP_NEW_STATIC_PERF_TEST
            const double elapsed = static_cast<double>(tb.cycle - tb.issue_cycle + 1);
            const double scalar_macs =
                static_cast<double>(batch) * m * n * k;
            const double peak_macs_per_cycle =
                static_cast<double>(SA_WIDTH_TEST) * SA_WIDTH_TEST;
            const double ideal_compute_cycles = scalar_macs / peak_macs_per_cycle;
            const double cmd_throughput_per_kcycle = 1000.0 / elapsed;
            const double ideal_cmd_throughput_per_kcycle =
                1000.0 / ideal_compute_cycles;
            const double mac_utilization = ideal_compute_cycles / elapsed;
            std::cout << name << ": elapsed=" << elapsed
                      << " ideal_compute_cycles=" << ideal_compute_cycles
                      << " throughput=" << cmd_throughput_per_kcycle
                      << "(GEMM cmd per KCycle)"
                      << " ideal_throughput=" << ideal_cmd_throughput_per_kcycle
                      << "(GEMM cmd per KCycle)"
                      << " mac_utilization=" << mac_utilization << "\n";
#endif
            return;
        }
    }
    fail(name + ": timeout cycle=" + std::to_string(tb.cycle) +
         " loads=" + std::to_string(tb.load_requests) +
         " stores=" + std::to_string(tb.store_writes));
}
}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
#if TOP_NEW_STATIC_PERF_TEST
        const auto env_dimension = [](const char* name, int fallback) {
            const char* value = std::getenv(name);
            if (value == nullptr) return fallback;
            const int parsed = std::stoi(value);
            if (parsed <= 0) fail(std::string(name) + " must be positive");
            return parsed;
        };
        const int perf_m = env_dimension("PERF_RUN_M", PERF_M_TEST);
        const int perf_n = env_dimension("PERF_RUN_N", PERF_N_TEST);
        const int perf_k = env_dimension("PERF_RUN_K", PERF_K_TEST);
        const int perf_batch = env_dimension("PERF_RUN_BATCH", PERF_BATCH_TEST);

        // The performance dimensions may be overridden at run time so one
        // compiled RTL model can cover multiple GEMM command shapes.
        // Calculate bus transactions from tile dimensions and the fixed
        // configured load bus rather than hard-coding a small-test count.
        const int tm = (perf_m + SA_WIDTH_TEST - 1) / SA_WIDTH_TEST;
        const int tn = (perf_n + SA_WIDTH_TEST - 1) / SA_WIDTH_TEST;
        const int tk = (perf_k + SUBTILE_K_TEST - 1) / SUBTILE_K_TEST;
        constexpr int a_group = ABUF_SIZE_TEST / 2;
        constexpr int b_group = BBUF_SIZE_TEST / 2;
        constexpr int acc_group = PACC_NUM_TEST / 2;
        constexpr int block_cap = acc_group;
        constexpr int merge_cap = (a_group < b_group) ?
            ((a_group < acc_group) ? a_group : acc_group) :
            ((b_group < acc_group) ? b_group : acc_group);
        const int block_m = choose_block_m(tm, tn, a_group, b_group, block_cap);
        const int block_n = choose_block_n(tm, tn, a_group, b_group, block_cap);
        const int blocks_m = (tm + block_m - 1) / block_m;
        const int blocks_n = (tn + block_n - 1) / block_n;
        constexpr int row_width_bytes = SUBTILE_K_TEST;
        constexpr int load_row_bits = row_width_bytes * 8;
        constexpr int rows_per_load_beat =
            LOAD_DATA_WIDTH_TEST >= load_row_bits ?
            (LOAD_DATA_WIDTH_TEST / load_row_bits) : 1;
        constexpr int beats_per_load_row =
            LOAD_DATA_WIDTH_TEST >= load_row_bits ?
            1 : (load_row_bits / LOAD_DATA_WIDTH_TEST);
        constexpr int load_beats_per_tile =
            ((SA_WIDTH_TEST + rows_per_load_beat - 1) / rows_per_load_beat) *
            beats_per_load_row;
        const bool merge_batch = tm * tn < merge_cap;
        const int expected_loads = merge_batch ?
            (2 * perf_batch * tm * tn * tk * load_beats_per_tile) :
            (perf_batch * blocks_m * blocks_n * tk *
             (block_m + block_n) * load_beats_per_tile);
        const int expected_stores = perf_batch * tm * tn *
            (SA_WIDTH_TEST / STORE_ROWS_PER_CYCLE_TEST);
        run_case("perf_batched_gemm", perf_m, perf_n, perf_k, perf_batch, 0,
                 expected_loads, expected_stores, static_cast<float>(perf_k));
#else
        // The 1024-bit load bus covers each tiny operand tile in one beat.
        run_case("one_wave", 2, 2, 2, 1, 3, 2,
                 2 / STORE_ROWS_PER_CYCLE_TEST, 2.0f);
        run_case("multi_k_wave", 4, 4, 8, 1, 9, 24,
                 8 / STORE_ROWS_PER_CYCLE_TEST, 8.0f);
        run_case("merged_batch", 2, 2, 2, 2, 5, 4,
                 4 / STORE_ROWS_PER_CYCLE_TEST, 2.0f);
#endif
        std::cout << "top_new_static tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << "top_new_static test failed: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
