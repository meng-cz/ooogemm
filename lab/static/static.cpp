#include "Vtop_static.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 32
#endif
#ifndef SUBTILE_K_TEST
#define SUBTILE_K_TEST 32
#endif
#ifndef LANE_NUM_TEST
#define LANE_NUM_TEST 4
#endif
#ifndef ABUF_SIZE_TEST
#define ABUF_SIZE_TEST 16
#endif
#ifndef BBUF_SIZE_TEST
#define BBUF_SIZE_TEST 16
#endif
#ifndef PACC_NUM_TEST
#define PACC_NUM_TEST 16
#endif
#ifndef STORE_ROWS_PER_CYCLE_TEST
#define STORE_ROWS_PER_CYCLE_TEST 1
#endif
#ifndef LOAD_DATA_WIDTH_TEST
#define LOAD_DATA_WIDTH_TEST 1024
#endif

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kSubtileK = SUBTILE_K_TEST;
constexpr int kLaneNum = LANE_NUM_TEST;
constexpr int kABufSize = ABUF_SIZE_TEST;
constexpr int kBBufSize = BBUF_SIZE_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kStoreRowsPerCycle = STORE_ROWS_PER_CYCLE_TEST;
constexpr int kLoadRowBits = kSubtileK * 8;
constexpr int kLoadRowWords = (kLoadRowBits + 31) / 32;
constexpr int kLoadDataBits = LOAD_DATA_WIDTH_TEST;
constexpr int kLoadBeatWords = (kLoadDataBits + 31) / 32;
constexpr int kWritesPerOutputTile = kSaWidth / kStoreRowsPerCycle;

static_assert(kLaneNum >= 1, "LANE_NUM_TEST must be positive");
static_assert(kABufSize >= 4 && kBBufSize >= 4, "operand buffers must have ping-pong halves");
static_assert(kPaccNum >= 1, "PACC_NUM_TEST must be positive");
static_assert(kStoreRowsPerCycle >= 1,
              "STORE_ROWS_PER_CYCLE_TEST must be positive");
static_assert((kSaWidth % kStoreRowsPerCycle) == 0,
              "SA_WIDTH_TEST must be divisible by STORE_ROWS_PER_CYCLE_TEST");
static_assert((kSubtileK & (kSubtileK - 1)) == 0,
              "SUBTILE_K_TEST must be a power of two");
static_assert((kLoadDataBits & (kLoadDataBits - 1)) == 0,
              "LOAD_DATA_WIDTH_TEST must be a power of two");
static_assert((kLoadDataBits % 8) == 0, "LOAD_DATA_WIDTH_TEST must be byte-aligned");
static_assert((kLoadDataBits >= kLoadRowBits && (kLoadDataBits % kLoadRowBits) == 0) ||
              (kLoadRowBits >= kLoadDataBits && (kLoadRowBits % kLoadDataBits) == 0),
              "load bus and operand row widths must divide each other");

struct LoadBeatData {
    std::array<uint32_t, kLoadBeatWords> words{};
};

struct Rsp {
    uint64_t due = 0;
    uint32_t id = 0;
    LoadBeatData data;
};

struct Options {
    int m = 1;
    int n = 1;
    int k = 1;
    int count = 1;
    uint64_t max_cycles = 0;
    uint32_t load_rsp_delay = 4;
    std::string out_path;
    std::string out_dir;
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

int ceil_div(int value, int divisor) {
    return (value + divisor - 1) / divisor;
}

LoadBeatData make_load_data(uint32_t addr) {
    LoadBeatData data;
    for (int i = 0; i < kLoadBeatWords; ++i) {
        // Keep operands finite and non-zero: byte 0x38 is FP8 E4M3 +1.0.
        data.words[static_cast<size_t>(i)] =
            0x38383838u ^ (addr * 0x01010101u) ^ (static_cast<uint32_t>(i) * 0x11111111u);
    }
    return data;
}

std::string result_filename(int m, int n, int k, int count) {
    std::ostringstream os;
    os << "L" << kLaneNum
       << "_W" << kSaWidth
       << "_AB" << kABufSize;
    if (kBBufSize != kABufSize) {
        os << "_BB" << kBBufSize;
    }
    os << "_ACC" << kPaccNum
       << "_" << m << "X" << n << "X" << k
       << "_Cnt" << count << ".txt";
    return os.str();
}

std::string join_path(const std::string& dir, const std::string& file) {
    if (dir.empty() || dir == ".") {
        return file;
    }
    if (dir.back() == '/') {
        return dir + file;
    }
    return dir + "/" + file;
}

bool path_is_dir(const std::string& path) {
    struct stat st {};
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

void ensure_dir(const std::string& path) {
    if (path.empty() || path == ".") {
        return;
    }
    if (path_is_dir(path)) {
        return;
    }

    size_t pos = 0;
    while (pos < path.size()) {
        pos = path.find('/', pos + 1);
        const std::string part = path.substr(0, pos);
        if (part.empty()) {
            continue;
        }
        if (path_is_dir(part)) {
            continue;
        }
        if (mkdir(part.c_str(), 0775) != 0 && errno != EEXIST) {
            fail("failed to create output directory " + part + ": " + std::strerror(errno));
        }
        if (pos == std::string::npos) {
            break;
        }
    }
}

class StaticLab {
public:
    explicit StaticLab(const Options& opt) : opt_(opt) {
        if (opt_.m <= 0 || opt_.n <= 0 || opt_.k <= 0 || opt_.count <= 0) {
            fail("M, N, K, and Count must all be positive");
        }
        output_tiles_per_cmd_ =
            static_cast<uint64_t>(ceil_div(opt_.m, kSaWidth)) *
            static_cast<uint64_t>(ceil_div(opt_.n, kSaWidth));
        expected_writes_per_cmd_ = output_tiles_per_cmd_ * kWritesPerOutputTile;
        if (expected_writes_per_cmd_ == 0) {
            fail("expected writes per command is zero");
        }
        cmd_tile_stride_ = output_tiles_per_cmd_ + 1024u;
        const uint64_t last_c_base = c_base_for_cmd(static_cast<uint64_t>(opt_.count - 1));
        const uint64_t max_tile_addr =
            ((uint64_t{1} << 32) - 1u) / static_cast<uint64_t>(kWritesPerOutputTile);
        if (last_c_base + output_tiles_per_cmd_ >= max_tile_addr) {
            fail("Count is too large for the simple 32-bit address layout");
        }

        issue_cycles_.assign(static_cast<size_t>(opt_.count), 0);
        completion_cycles_.assign(static_cast<size_t>(opt_.count), 0);
        writes_seen_.assign(static_cast<size_t>(opt_.count), 0);

        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
        dut_.eval();
    }

    void run() {
        reset();
        run_until_done();
        write_result();
        std::cout << "static_lab: passed"
                  << " L=" << kLaneNum
                  << " W=" << kSaWidth
                  << " MNK=" << opt_.m << "x" << opt_.n << "x" << opt_.k
                  << " Count=" << opt_.count
                  << " cycles=" << (last_completion_cycle_ - first_issue_cycle_ + 1)
                  << " throughput=" << throughput_per_kcycle_
                  << " latency=" << latency_kcycle_
                  << " input_bus_util=" << input_bus_util_
                  << " output_bus_util=" << output_bus_util_
                  << "\n";
    }

private:
    static constexpr uint32_t kABase = 0x00010000u;
    static constexpr uint32_t kBBase = 0x00020000u;
    static constexpr uint32_t kCBase = 0x00030000u;

    Options opt_;
    Vtop_static dut_;
    uint64_t cycle_ = 0;
    uint64_t output_tiles_per_cmd_ = 0;
    uint64_t expected_writes_per_cmd_ = 0;
    uint64_t cmd_tile_stride_ = 0;
    std::deque<Rsp> pending_rsp_;
    int next_cmd_ = 0;
    int completed_cmds_ = 0;
    uint64_t first_issue_cycle_ = 0;
    uint64_t last_completion_cycle_ = 0;
    uint64_t input_bus_payload_cycles_ = 0;
    uint64_t output_bus_payload_cycles_ = 0;
    double throughput_per_kcycle_ = 0.0;
    double latency_kcycle_ = 0.0;
    double input_bus_util_ = 0.0;
    double output_bus_util_ = 0.0;
    std::vector<uint64_t> issue_cycles_;
    std::vector<uint64_t> completion_cycles_;
    std::vector<uint64_t> writes_seen_;

    uint64_t c_base_for_cmd(uint64_t idx) const {
        return static_cast<uint64_t>(kCBase) + idx * cmd_tile_stride_;
    }

    void clear_inputs() {
        dut_.cmd_valid_i = 0;
        dut_.cmd_a_base_i = 0;
        dut_.cmd_b_base_i = 0;
        dut_.cmd_c_base_i = 0;
        dut_.cmd_m_i = 0;
        dut_.cmd_n_i = 0;
        dut_.cmd_k_i = 0;
        dut_.cmd_batch_i = 0;
        dut_.load_mem_req_ready_i = 0;
        dut_.load_mem_rsp_valid_i = 0;
        dut_.load_mem_rsp_id_i = 0;
        drive_load_rsp_data(LoadBeatData{});
        dut_.store_mem_wr_ready_i = 0;
    }

    void drive_load_rsp_data(const LoadBeatData& data) {
#if LOAD_DATA_WIDTH_TEST <= 32
        dut_.load_mem_rsp_data_i = data.words[0];
#else
        for (int i = 0; i < kLoadBeatWords; ++i) {
            dut_.load_mem_rsp_data_i[i] = data.words[static_cast<size_t>(i)];
        }
#endif
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 8; ++i) {
            tick_once();
        }
        dut_.rst_n = 1;
        for (int i = 0; i < 4; ++i) {
            tick_once();
        }
    }

    void tick_once() {
        dut_.clk = 0;
        dut_.eval();
        dut_.clk = 1;
        dut_.eval();
        dut_.clk = 0;
        dut_.eval();
        ++cycle_;
    }

    uint64_t default_max_cycles() const {
        const uint64_t tm = static_cast<uint64_t>(ceil_div(opt_.m, kSaWidth));
        const uint64_t tn = static_cast<uint64_t>(ceil_div(opt_.n, kSaWidth));
        const uint64_t tk = static_cast<uint64_t>(ceil_div(opt_.k, kSubtileK));
        const uint64_t rough_per_cmd =
            5000u + 200u * (tm + tn + tk) + 128u * tm * tn * std::max<uint64_t>(1, tk);
        return std::max<uint64_t>(200000u, rough_per_cmd * static_cast<uint64_t>(opt_.count) * 4u);
    }

    void run_until_done() {
        const uint64_t max_cycles = opt_.max_cycles != 0 ? opt_.max_cycles : default_max_cycles();
        for (uint64_t i = 0; i < max_cycles; ++i) {
            drive_cycle();
            if (completed_cmds_ == opt_.count) {
                compute_metrics();
                return;
            }
        }

        std::ostringstream os;
        os << "timeout: issued=" << next_cmd_ << "/" << opt_.count
           << " completed=" << completed_cmds_ << "/" << opt_.count
           << " pending_rsp=" << pending_rsp_.size()
           << " cycle=" << cycle_
           << " max_cycles=" << max_cycles;
        fail(os.str());
    }

    void drive_cycle() {
        clear_inputs();

        if (next_cmd_ < opt_.count) {
            dut_.cmd_valid_i = 1;
            dut_.cmd_a_base_i = kABase;
            dut_.cmd_b_base_i = kBBase;
            dut_.cmd_c_base_i = static_cast<uint32_t>(c_base_for_cmd(next_cmd_));
            dut_.cmd_m_i = static_cast<uint32_t>(opt_.m);
            dut_.cmd_n_i = static_cast<uint32_t>(opt_.n);
            dut_.cmd_k_i = static_cast<uint32_t>(opt_.k);
            dut_.cmd_batch_i = 1;
        }

        dut_.load_mem_req_ready_i = 1;
        dut_.store_mem_wr_ready_i = 1;

        int rsp_index = -1;
        for (size_t i = 0; i < pending_rsp_.size(); ++i) {
            if (pending_rsp_[i].due <= cycle_) {
                rsp_index = static_cast<int>(i);
                break;
            }
        }
        Rsp rsp;
        if (rsp_index >= 0) {
            rsp = pending_rsp_[static_cast<size_t>(rsp_index)];
            dut_.load_mem_rsp_valid_i = 1;
            dut_.load_mem_rsp_id_i = rsp.id;
            drive_load_rsp_data(rsp.data);
        }

        dut_.clk = 0;
        dut_.eval();

        const bool cmd_fire = dut_.cmd_valid_i && dut_.cmd_ready_o;
        const bool req_fire = dut_.load_mem_req_valid_o && dut_.load_mem_req_ready_i;
        const bool rsp_fire = dut_.load_mem_rsp_valid_i && dut_.load_mem_rsp_ready_o;
        const bool wr_fire = dut_.store_mem_wr_valid_o && dut_.store_mem_wr_ready_i;
        const uint32_t req_addr_fire = static_cast<uint32_t>(dut_.load_mem_req_addr_o);
        const uint32_t req_id_fire = static_cast<uint32_t>(dut_.load_mem_req_id_o);
        const uint32_t wr_addr_fire = static_cast<uint32_t>(dut_.store_mem_wr_addr_o);

        dut_.clk = 1;
        dut_.eval();

        if (cmd_fire) {
            issue_cycles_[static_cast<size_t>(next_cmd_)] = cycle_;
            if (next_cmd_ == 0) {
                first_issue_cycle_ = cycle_;
            }
            ++next_cmd_;
        }
        if (req_fire) {
            Rsp new_rsp;
            new_rsp.due = cycle_ + opt_.load_rsp_delay;
            new_rsp.id = req_id_fire;
            new_rsp.data = make_load_data(req_addr_fire);
            pending_rsp_.push_back(new_rsp);
        }
        if (rsp_fire) {
            if (rsp_index < 0) {
                fail("response fired without a selected pending response");
            }
            pending_rsp_.erase(pending_rsp_.begin() + rsp_index);
            ++input_bus_payload_cycles_;
        }
        if (wr_fire) {
            ++output_bus_payload_cycles_;
            record_store(wr_addr_fire);
        }

        dut_.clk = 0;
        dut_.eval();
        ++cycle_;
    }

    void record_store(uint32_t wr_addr) {
        const uint64_t tile_addr = static_cast<uint64_t>(wr_addr) / kWritesPerOutputTile;
        if (tile_addr < kCBase) {
            fail("store write below C base at addr " + hex32(wr_addr));
        }
        const uint64_t rel = tile_addr - kCBase;
        const uint64_t cmd_idx = rel / cmd_tile_stride_;
        const uint64_t tile_off = rel % cmd_tile_stride_;
        if (cmd_idx >= static_cast<uint64_t>(opt_.count) || tile_off >= output_tiles_per_cmd_) {
            fail("store write outside command ranges at addr " + hex32(wr_addr));
        }

        uint64_t& seen = writes_seen_[static_cast<size_t>(cmd_idx)];
        ++seen;
        if (seen == expected_writes_per_cmd_) {
            completion_cycles_[static_cast<size_t>(cmd_idx)] = cycle_;
            last_completion_cycle_ = cycle_;
            ++completed_cmds_;
            const uint64_t latency_cycles =
                completion_cycles_[static_cast<size_t>(cmd_idx)] -
                issue_cycles_[static_cast<size_t>(cmd_idx)] + 1;
            std::cout << "static_lab: progress completed=" << completed_cmds_
                      << "/" << opt_.count
                      << " cmd=" << cmd_idx
                      << " cycle=" << cycle_
                      << " latency=" << std::fixed << std::setprecision(6)
                      << (static_cast<double>(latency_cycles) / 1000.0)
                      << "(KCycle)\n";
            std::cout.flush();
        } else if (seen > expected_writes_per_cmd_) {
            fail("too many store writes for command " + std::to_string(cmd_idx));
        }
    }

    void compute_metrics() {
        if (opt_.count <= 0 || last_completion_cycle_ < first_issue_cycle_) {
            fail("cannot compute metrics");
        }
        const uint64_t elapsed_cycles = last_completion_cycle_ - first_issue_cycle_ + 1;
        throughput_per_kcycle_ =
            static_cast<double>(opt_.count) * 1000.0 / static_cast<double>(elapsed_cycles);
        input_bus_util_ =
            static_cast<double>(input_bus_payload_cycles_) / static_cast<double>(elapsed_cycles);
        output_bus_util_ =
            static_cast<double>(output_bus_payload_cycles_) / static_cast<double>(elapsed_cycles);

        uint64_t latency_sum = 0;
        for (int i = 0; i < opt_.count; ++i) {
            if (completion_cycles_[static_cast<size_t>(i)] < issue_cycles_[static_cast<size_t>(i)]) {
                fail("completion before issue for command " + std::to_string(i));
            }
            latency_sum += completion_cycles_[static_cast<size_t>(i)] -
                           issue_cycles_[static_cast<size_t>(i)] + 1;
        }
        latency_kcycle_ =
            static_cast<double>(latency_sum) / static_cast<double>(opt_.count) / 1000.0;
    }

    void write_result() const {
        std::string out_path = opt_.out_path;
        if (out_path.empty() && !opt_.out_dir.empty()) {
            out_path = join_path(
                opt_.out_dir,
                result_filename(opt_.m, opt_.n, opt_.k, opt_.count)
            );
        }
        if (out_path.empty()) {
            return;
        }
        if (!opt_.out_dir.empty()) {
            ensure_dir(opt_.out_dir);
        }
        std::ofstream out(out_path);
        if (!out) {
            fail("failed to open output file: " + out_path);
        }
        out << std::fixed << std::setprecision(6)
            << "throughput=" << throughput_per_kcycle_ << "(GEMM cmd per KCycle)\n"
            << "latency=" << latency_kcycle_ << "(KCycle)\n"
            << "input_bus_util=" << input_bus_util_ << "(payload cycle per cycle)\n"
            << "output_bus_util=" << output_bus_util_ << "(payload cycle per cycle)\n";
    }
};

int parse_int_arg(const std::string& arg, const std::string& name) {
    const std::string prefix = "--" + name + "=";
    if (arg.rfind(prefix, 0) != 0) {
        fail("internal parser error for " + name);
    }
    return std::stoi(arg.substr(prefix.size()));
}

uint64_t parse_u64_arg(const std::string& arg, const std::string& name) {
    const std::string prefix = "--" + name + "=";
    if (arg.rfind(prefix, 0) != 0) {
        fail("internal parser error for " + name);
    }
    return static_cast<uint64_t>(std::stoull(arg.substr(prefix.size()), nullptr, 0));
}

Options parse_options(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg.rfind("--m=", 0) == 0) {
            opt.m = parse_int_arg(arg, "m");
        } else if (arg.rfind("--n=", 0) == 0) {
            opt.n = parse_int_arg(arg, "n");
        } else if (arg.rfind("--k=", 0) == 0) {
            opt.k = parse_int_arg(arg, "k");
        } else if (arg.rfind("--count=", 0) == 0) {
            opt.count = parse_int_arg(arg, "count");
        } else if (arg.rfind("--out=", 0) == 0) {
            opt.out_path = arg.substr(std::string("--out=").size());
        } else if (arg.rfind("--out-dir=", 0) == 0) {
            opt.out_dir = arg.substr(std::string("--out-dir=").size());
        } else if (arg.rfind("--max-cycles=", 0) == 0) {
            opt.max_cycles = parse_u64_arg(arg, "max-cycles");
        } else if (arg.rfind("--load-rsp-delay=", 0) == 0) {
            opt.load_rsp_delay = static_cast<uint32_t>(parse_u64_arg(arg, "load-rsp-delay"));
        }
    }
    return opt;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const Options opt = parse_options(argc, argv);
        StaticLab lab(opt);
        lab.run();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "static_lab failed: " << e.what() << "\n";
        return 1;
    }
}
