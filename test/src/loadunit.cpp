#include "Vloadunit.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <map>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 4
#endif
#ifndef SUBTILE_K_TEST
#define SUBTILE_K_TEST 4
#endif
#ifndef ABUF_SIZE_TEST
#define ABUF_SIZE_TEST 8
#endif
#ifndef BBUF_SIZE_TEST
#define BBUF_SIZE_TEST 8
#endif
#ifndef BUS_ID_WIDTH_TEST
#define BUS_ID_WIDTH_TEST 3
#endif

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kSubtileK = SUBTILE_K_TEST;
constexpr int kABufSize = ABUF_SIZE_TEST;
constexpr int kBBufSize = BBUF_SIZE_TEST;
constexpr int kBusIdWidth = BUS_ID_WIDTH_TEST;
constexpr int kOutstandingNum = 1 << kBusIdWidth;

static_assert(kSaWidth > 0, "SA_WIDTH_TEST must be positive");
static_assert(kSubtileK <= 4, "this testbench expects ROW_DATA_WIDTH <= 32");
static_assert(kOutstandingNum >= kSaWidth, "ID space must fit one full tile");

struct Load {
    bool is_b = false;
    uint32_t addr = 0;
    uint32_t abuf = 0;
    uint32_t bbuf = 0;
    uint32_t valid_rows = 0;
    std::string name;
};

struct ReqInfo {
    bool is_b = false;
    uint32_t addr = 0;
    uint32_t id = 0;
    uint32_t bufidx = 0;
    uint32_t row = 0;
    uint32_t data = 0;
    bool last = false;
    int age = 0;
    std::string name;
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

uint32_t row_addr(uint32_t tile_addr, int row) {
    return tile_addr * static_cast<uint32_t>(kSaWidth) + static_cast<uint32_t>(row);
}

uint32_t data_for(uint32_t addr, uint32_t id) {
    return 0xa5000000u ^ (addr * 0x45d9f3bu) ^ (id * 0x10203u);
}

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x10ad1234u;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        const std::string prefix = "--seed=";
        if (arg.rfind(prefix, 0) == 0) {
            seed = static_cast<uint32_t>(std::stoul(arg.substr(prefix.size()), nullptr, 0));
        }
    }
    return seed;
}

class LoadUnitTest {
public:
    explicit LoadUnitTest(uint32_t seed) : seed_(seed), rng_(seed) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
        dut_.eval();
    }

    int run() {
        reset();
        directed_tests();
        random_tests();
        std::cout << "loadunit: passed, seed=" << hex32(seed_) << "\n";
        return 0;
    }

private:
    Vloadunit dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;

    std::deque<ReqInfo> expected_reqs_;
    std::deque<ReqInfo> pending_outputs_;
    std::map<uint32_t, ReqInfo> inflight_;
    int a_rows_left_[kABufSize] = {};
    int b_rows_left_[kBBufSize] = {};
    uint32_t a_model_[kABufSize][kSaWidth] = {};
    uint32_t b_model_[kBBufSize][kSaWidth] = {};

    bool hold_active_ = false;
    uint32_t hold_id_ = 0;
    uint32_t hold_addr_ = 0;

    void clear_inputs() {
        dut_.uop_valid_i = 0;
        dut_.uop_is_b_i = 0;
        dut_.uop_addr_i = 0;
        dut_.uop_abufidx_i = 0;
        dut_.uop_bbufidx_i = 0;
        dut_.uop_valid_rows_i = 0;
        dut_.mem_req_ready_i = 0;
        dut_.mem_rsp_valid_i = 0;
        dut_.mem_rsp_id_i = 0;
        dut_.mem_rsp_data_i = 0;
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 5; ++i) {
            tick_raw();
        }
        dut_.rst_n = 1;
        for (int i = 0; i < 2; ++i) {
            tick_raw();
        }
    }

    void tick_raw() {
        dut_.clk = 0;
        dut_.eval();
        dut_.clk = 1;
        dut_.eval();
        dut_.clk = 0;
        dut_.eval();
        ++cycle_;
    }

    void drive_load(const Load& load) {
        dut_.uop_valid_i = 1;
        dut_.uop_is_b_i = load.is_b ? 1 : 0;
        dut_.uop_addr_i = load.addr;
        dut_.uop_abufidx_i = load.abuf;
        dut_.uop_bbufidx_i = load.bbuf;
        dut_.uop_valid_rows_i = load.valid_rows;
    }

    void clear_load() {
        dut_.uop_valid_i = 0;
        dut_.uop_is_b_i = 0;
        dut_.uop_addr_i = 0;
        dut_.uop_abufidx_i = 0;
        dut_.uop_bbufidx_i = 0;
        dut_.uop_valid_rows_i = 0;
    }

    int rows_eff(const Load& load) const {
        if (load.valid_rows == 0 || load.valid_rows > static_cast<uint32_t>(kSaWidth)) {
            return kSaWidth;
        }
        return static_cast<int>(load.valid_rows);
    }

    void enqueue_expected_reqs(const Load& load) {
        const uint32_t bufidx = load.is_b ? load.bbuf : load.abuf;
        int& rows_left = load.is_b ? b_rows_left_[bufidx] : a_rows_left_[bufidx];
        if (rows_left != 0) {
            std::ostringstream os;
            os << "DUT accepted overlapping load for "
               << (load.is_b ? "B" : "A") << " buffer " << bufidx
               << " while " << rows_left << " rows are still outstanding";
            fail(os.str());
        }
        const int rows = rows_eff(load);
        rows_left = rows;

        for (int row = rows; row < kSaWidth; ++row) {
            if (load.is_b) {
                b_model_[bufidx][row] = 0;
            } else {
                a_model_[bufidx][row] = 0;
            }
        }

        for (int row = 0; row < rows; ++row) {
            ReqInfo req;
            req.is_b = load.is_b;
            req.addr = row_addr(load.addr, row);
            req.bufidx = bufidx;
            req.row = static_cast<uint32_t>(row);
            req.name = load.name;
            expected_reqs_.push_back(req);
        }
    }

    void check_zero_init_outputs(const Load& load) {
        const int rows = rows_eff(load);
        if (rows == kSaWidth) {
            check_no_pending_outputs();
            return;
        }

        uint32_t expected_mask = 0;
        for (int row = rows; row < kSaWidth; ++row) {
            expected_mask |= uint32_t{1} << row;
        }

        if (load.is_b) {
            if (dut_.abuf_wr_valid_o || dut_.abuf_ready_valid_o ||
                dut_.bbuf_ready_valid_o ||
                !dut_.bbuf_wr_valid_o ||
                dut_.bbuf_wr_idx_o != load.bbuf ||
                dut_.bbuf_wr_bank_en_o != expected_mask) {
                std::ostringstream os;
                os << "B zero-init mismatch at cycle " << cycle_
                   << " for " << load.name
                   << ": expected mask=" << hex32(expected_mask)
                   << " got valid=" << static_cast<int>(dut_.bbuf_wr_valid_o)
                   << " idx=" << static_cast<uint32_t>(dut_.bbuf_wr_idx_o)
                   << " mask=" << hex32(static_cast<uint32_t>(dut_.bbuf_wr_bank_en_o));
                fail(os.str());
            }
            for (int row = rows; row < kSaWidth; ++row) {
                if (dut_.bbuf_wr_data_o[row] != 0) {
                    fail("B zero-init wrote non-zero data");
                }
            }
        } else {
            if (dut_.bbuf_wr_valid_o || dut_.bbuf_ready_valid_o ||
                dut_.abuf_ready_valid_o ||
                !dut_.abuf_wr_valid_o ||
                dut_.abuf_wr_idx_o != load.abuf ||
                dut_.abuf_wr_bank_en_o != expected_mask) {
                std::ostringstream os;
                os << "A zero-init mismatch at cycle " << cycle_
                   << " for " << load.name
                   << ": expected mask=" << hex32(expected_mask)
                   << " got valid=" << static_cast<int>(dut_.abuf_wr_valid_o)
                   << " idx=" << static_cast<uint32_t>(dut_.abuf_wr_idx_o)
                   << " mask=" << hex32(static_cast<uint32_t>(dut_.abuf_wr_bank_en_o));
                fail(os.str());
            }
            for (int row = rows; row < kSaWidth; ++row) {
                if (dut_.abuf_wr_data_o[row] != 0) {
                    fail("A zero-init wrote non-zero data");
                }
            }
        }
    }

    bool choose_response(ReqInfo& rsp) {
        std::vector<uint32_t> ids;
        for (const auto& item : inflight_) {
            if (item.second.age >= 1) {
                ids.push_back(item.first);
            }
        }
        if (ids.empty()) {
            return false;
        }
        std::uniform_int_distribution<size_t> dist(0, ids.size() - 1);
        const uint32_t id = ids[dist(rng_)];
        rsp = inflight_.at(id);
        return true;
    }

    void drive_response(const ReqInfo* rsp) {
        if (rsp == nullptr) {
            dut_.mem_rsp_valid_i = 0;
            dut_.mem_rsp_id_i = 0;
            dut_.mem_rsp_data_i = 0;
        } else {
            dut_.mem_rsp_valid_i = 1;
            dut_.mem_rsp_id_i = rsp->id;
            dut_.mem_rsp_data_i = rsp->data;
        }
    }

    void check_no_pending_outputs() {
        if (dut_.abuf_wr_valid_o || dut_.bbuf_wr_valid_o ||
            dut_.abuf_ready_valid_o || dut_.bbuf_ready_valid_o) {
            std::ostringstream os;
            os << "unexpected buffer output without pending response at cycle " << cycle_;
            fail(os.str());
        }
    }

    void check_response_outputs(const ReqInfo& rsp) {
        const uint32_t onehot = uint32_t{1} << rsp.row;

        if (rsp.is_b) {
            if (dut_.abuf_wr_valid_o || dut_.abuf_ready_valid_o) {
                fail("A output asserted for B response");
            }
            if (!dut_.bbuf_wr_valid_o ||
                dut_.bbuf_wr_idx_o != rsp.bufidx ||
                dut_.bbuf_wr_bank_en_o != onehot ||
                dut_.bbuf_wr_data_o[rsp.row] != rsp.data) {
                std::ostringstream os;
                os << "B write mismatch at cycle " << cycle_
                   << " for " << rsp.name
                   << ": buf=" << rsp.bufidx
                   << " row=" << rsp.row
                   << " data=" << hex32(rsp.data);
                fail(os.str());
            }
            if ((dut_.bbuf_ready_valid_o != (rsp.last ? 1 : 0)) ||
                (rsp.last && dut_.bbuf_ready_idx_o != rsp.bufidx)) {
                fail("B ready pulse mismatch");
            }
        } else {
            if (dut_.bbuf_wr_valid_o || dut_.bbuf_ready_valid_o) {
                fail("B output asserted for A response");
            }
            if (!dut_.abuf_wr_valid_o ||
                dut_.abuf_wr_idx_o != rsp.bufidx ||
                dut_.abuf_wr_bank_en_o != onehot ||
                dut_.abuf_wr_data_o[rsp.row] != rsp.data) {
                std::ostringstream os;
                os << "A write mismatch at cycle " << cycle_
                   << " for " << rsp.name
                   << ": buf=" << rsp.bufidx
                   << " row=" << rsp.row
                   << " data=" << hex32(rsp.data);
                fail(os.str());
            }
            if ((dut_.abuf_ready_valid_o != (rsp.last ? 1 : 0)) ||
                (rsp.last && dut_.abuf_ready_idx_o != rsp.bufidx)) {
                fail("A ready pulse mismatch");
            }
        }
    }

    void check_pending_output() {
        if (pending_outputs_.empty()) {
            check_no_pending_outputs();
            return;
        }

        const ReqInfo rsp = pending_outputs_.front();
        pending_outputs_.pop_front();
        check_response_outputs(rsp);
    }

    void update_model_for_response(const ReqInfo& rsp) {
        if (rsp.is_b) {
            b_model_[rsp.bufidx][rsp.row] = rsp.data;
            --b_rows_left_[rsp.bufidx];
        } else {
            a_model_[rsp.bufidx][rsp.row] = rsp.data;
            --a_rows_left_[rsp.bufidx];
        }
        inflight_.erase(rsp.id);
    }

    void check_request_stability(bool req_fire) {
        if (dut_.mem_req_valid_o && !dut_.mem_req_ready_i) {
            if (!hold_active_) {
                hold_active_ = true;
                hold_id_ = dut_.mem_req_id_o;
                hold_addr_ = dut_.mem_req_addr_o;
            } else if (hold_id_ != dut_.mem_req_id_o ||
                       hold_addr_ != dut_.mem_req_addr_o) {
                std::ostringstream os;
                os << "request payload changed while stalled at cycle " << cycle_
                   << ": previous id=" << hold_id_ << " addr=" << hex32(hold_addr_)
                   << ", current id=" << static_cast<uint32_t>(dut_.mem_req_id_o)
                   << " addr=" << hex32(dut_.mem_req_addr_o);
                fail(os.str());
            }
        }
        if (req_fire || !dut_.mem_req_valid_o) {
            hold_active_ = false;
        }
    }

    ReqInfo check_request_fire() {
        if (expected_reqs_.empty()) {
            fail("DUT issued request with no expected row");
        }

        ReqInfo req = expected_reqs_.front();
        expected_reqs_.pop_front();
        req.id = static_cast<uint32_t>(dut_.mem_req_id_o);
        req.data = data_for(req.addr, req.id);

        if (dut_.mem_req_addr_o != req.addr) {
            std::ostringstream os;
            os << "request address mismatch at cycle " << cycle_
               << " for " << req.name
               << ": got " << hex32(dut_.mem_req_addr_o)
               << ", expected " << hex32(req.addr);
            fail(os.str());
        }
        if (req.id >= kOutstandingNum) {
            fail("DUT issued out-of-range transaction ID");
        }
        if (inflight_.find(req.id) != inflight_.end()) {
            fail("DUT reused an outstanding transaction ID");
        }
        return req;
    }

    void run_sequence(const std::string& name,
                      const std::vector<Load>& loads,
                      int max_cycles) {
        size_t load_idx = 0;
        std::bernoulli_distribution ready_dist(0.65);
        std::bernoulli_distribution rsp_dist(0.75);

        while (cycle_ < static_cast<uint64_t>(max_cycles)) {
            ReqInfo rsp;
            const bool have_rsp = rsp_dist(rng_) && choose_response(rsp);
            drive_response(have_rsp ? &rsp : nullptr);

            dut_.mem_req_ready_i = ready_dist(rng_) ? 1 : 0;
            if (load_idx < loads.size()) {
                drive_load(loads[load_idx]);
            } else {
                clear_load();
            }
            dut_.eval();

            const bool uop_fire = dut_.uop_valid_i && dut_.uop_ready_o;
            const bool req_fire = dut_.mem_req_valid_o && dut_.mem_req_ready_i;

            if (pending_outputs_.empty() && uop_fire) {
                check_zero_init_outputs(loads[load_idx]);
            } else {
                check_pending_output();
            }

            if (uop_fire) {
                enqueue_expected_reqs(loads[load_idx]);
            }

            if (have_rsp) {
                int* rows_left_arr = rsp.is_b ? b_rows_left_ : a_rows_left_;
                rsp.last = rows_left_arr[rsp.bufidx] == 1;
            }

            check_request_stability(req_fire);
            ReqInfo fired_req;
            bool have_fired_req = false;
            if (req_fire) {
                fired_req = check_request_fire();
                have_fired_req = true;
            }

            tick_raw();

            if (have_rsp) {
                update_model_for_response(rsp);
                pending_outputs_.push_back(rsp);
            }
            if (have_fired_req) {
                inflight_[fired_req.id] = fired_req;
            }
            for (auto& item : inflight_) {
                ++item.second.age;
            }
            if (uop_fire) {
                ++load_idx;
            }

            if (load_idx == loads.size() &&
                expected_reqs_.empty() &&
                pending_outputs_.empty() &&
                inflight_.empty() &&
                !dut_.mem_req_valid_o) {
                std::cout << name << ": passed, loads=" << loads.size()
                          << " cycles=" << cycle_ << "\n";
                return;
            }
        }

        std::ostringstream os;
        os << name << ": timeout, accepted_loads=" << load_idx
           << "/" << loads.size()
           << " expected_reqs=" << expected_reqs_.size()
           << " inflight=" << inflight_.size();
        fail(os.str());
    }

    void directed_tests() {
        run_sequence(
            "directed_mixed_ooo",
            {
                Load{false, 0x100, 2, 0, 0, "A0"},
                Load{true,  0x240, 0, 5, 0, "B0"},
                Load{false, 0x111, 3, 0, 1, "A1_partial_one_row"},
                Load{true,  0x280, 0, 1, 3, "B1_partial_three_rows"},
                Load{false, 0x130, 2, 0, 0, "A0_reuse_after_ready"},
            },
            2000
        );
    }

    void random_tests() {
        std::uniform_int_distribution<int> kind_dist(0, 1);
        std::uniform_int_distribution<int> abuf_dist(0, kABufSize - 1);
        std::uniform_int_distribution<int> bbuf_dist(0, kBBufSize - 1);
        std::uniform_int_distribution<uint32_t> addr_dist(0, 0x3fff);

        std::vector<Load> loads;
        for (int i = 0; i < 80; ++i) {
            Load load;
            load.is_b = kind_dist(rng_) != 0;
            load.addr = 0x1000u + addr_dist(rng_) + static_cast<uint32_t>(i * 17);
            load.abuf = static_cast<uint32_t>(abuf_dist(rng_));
            load.bbuf = static_cast<uint32_t>(bbuf_dist(rng_));
            load.valid_rows = static_cast<uint32_t>(i % (kSaWidth + 1));
            load.name = "rand" + std::to_string(i);
            loads.push_back(load);
        }
        run_sequence("random_stress", loads, 20000);
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const uint32_t seed = parse_seed(argc, argv);
        LoadUnitTest test(seed);
        return test.run();
    } catch (const std::exception& e) {
        std::cerr << "loadunit test failed: " << e.what() << "\n";
        return 1;
    }
}
