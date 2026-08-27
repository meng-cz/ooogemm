#include "Vstoreunit.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 2
#endif
#ifndef PACC_NUM_TEST
#define PACC_NUM_TEST 8
#endif
#ifndef PACC_IDX_WIDTH_TEST
#define PACC_IDX_WIDTH_TEST 3
#endif
#ifndef ROW_WRITE_BEATS_TEST
#define ROW_WRITE_BEATS_TEST 2
#endif
#ifndef MEM_DATA_WIDTH_TEST
#define MEM_DATA_WIDTH_TEST ((SA_WIDTH_TEST * 32) / ROW_WRITE_BEATS_TEST)
#endif

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kPaccIdxMask = (1 << PACC_IDX_WIDTH_TEST) - 1;
constexpr int kRowWriteBeats = ROW_WRITE_BEATS_TEST;
constexpr int kMemDataWidth = MEM_DATA_WIDTH_TEST;

static_assert(kSaWidth >= 1, "SA_WIDTH_TEST must be positive");
static_assert(kSaWidth <= 2, "this testbench expects ROW_DATA_WIDTH <= 64");
static_assert(kRowWriteBeats >= 1, "ROW_WRITE_BEATS_TEST must be positive");
static_assert((kRowWriteBeats & (kRowWriteBeats - 1)) == 0,
              "ROW_WRITE_BEATS_TEST must be one or a power of two");
static_assert((kSaWidth * 32) % kRowWriteBeats == 0,
              "row data width must be divisible by ROW_WRITE_BEATS_TEST");
static_assert(kMemDataWidth <= 64, "this testbench expects MEM_DATA_WIDTH <= 64");

struct Uop {
    uint32_t addr = 0;
    uint32_t pacc = 0;
    std::string name;
};

struct WriteBeat {
    uint32_t addr = 0;
    uint64_t data = 0;
    bool last_of_uop = false;
    std::string name;
};

struct SaBurst {
    bool active = false;
    uint32_t base_addr = 0;
    uint32_t pacc = 0;
    int row = 0;
    int delay = 0;
    std::string name;
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

std::string hex64(uint64_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(16) << std::setfill('0') << value;
    return os.str();
}

uint64_t low_mask(int width) {
    return width >= 64 ? ~uint64_t{0} : ((uint64_t{1} << width) - 1u);
}

uint32_t beat_addr(uint32_t tile_addr, int row, int beat) {
    return tile_addr * static_cast<uint32_t>(kSaWidth * kRowWriteBeats) +
           static_cast<uint32_t>(row * kRowWriteBeats + beat);
}

uint64_t row_data(uint32_t pacc, int row) {
    uint64_t data = 0;
    for (int col = 0; col < kSaWidth; ++col) {
        const uint32_t word = 0x3f800000u ^
            (pacc * 0x00100100u) ^
            (static_cast<uint32_t>(row) * 0x00010001u) ^
            (static_cast<uint32_t>(col) * 0x01000001u);
        data |= static_cast<uint64_t>(word) << (32 * col);
    }
    return data;
}

uint64_t beat_data(uint64_t row, int beat) {
    return (row >> (beat * kMemDataWidth)) & low_mask(kMemDataWidth);
}

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x5700e123u;
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        const std::string prefix = "--seed=";
        if (arg.rfind(prefix, 0) == 0) {
            seed = static_cast<uint32_t>(std::stoul(arg.substr(prefix.size()), nullptr, 0));
        }
    }
    return seed;
}

class StoreUnitTest {
public:
    explicit StoreUnitTest(uint32_t seed) : seed_(seed), rng_(seed) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
        dut_.eval();
    }

    int run() {
        reset();
        directed_tests();
        random_tests();
        std::cout << "storeunit: passed, seed=" << hex64(seed_) << "\n";
        return 0;
    }

private:
    Vstoreunit dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;

    std::deque<Uop> pending_getacc_;
    std::deque<WriteBeat> expected_writes_;
    SaBurst burst_;

    bool getacc_hold_active_ = false;
    uint32_t getacc_hold_idx_ = 0;
    bool wr_hold_active_ = false;
    uint32_t wr_hold_addr_ = 0;
    uint64_t wr_hold_data_ = 0;

    void clear_inputs() {
        dut_.uop_valid_i = 0;
        dut_.uop_addr_i = 0;
        dut_.uop_paccidx_i = 0;
        dut_.sa_getacc_ready_i = 0;
        dut_.sa_getacc_data_valid_i = 0;
        dut_.sa_getacc_data_i = 0;
        dut_.mem_wr_ready_i = 0;
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

    void drive_uop(const Uop& uop) {
        dut_.uop_valid_i = 1;
        dut_.uop_addr_i = uop.addr;
        dut_.uop_paccidx_i = uop.pacc & kPaccIdxMask;
    }

    void clear_uop() {
        dut_.uop_valid_i = 0;
        dut_.uop_addr_i = 0;
        dut_.uop_paccidx_i = 0;
    }

    bool drive_sa_response() {
        if (!burst_.active || burst_.delay > 0) {
            dut_.sa_getacc_data_valid_i = 0;
            dut_.sa_getacc_data_i = 0;
            return false;
        }

        dut_.sa_getacc_data_valid_i = 1;
        dut_.sa_getacc_data_i = row_data(burst_.pacc, burst_.row);
        return true;
    }

    void check_getacc_stability(bool fire) {
        if (dut_.sa_getacc_valid_o && !dut_.sa_getacc_ready_i) {
            if (!getacc_hold_active_) {
                getacc_hold_active_ = true;
                getacc_hold_idx_ = dut_.sa_getacc_idx_o;
            } else if (getacc_hold_idx_ != dut_.sa_getacc_idx_o) {
                fail("sa_getacc_idx_o changed while getacc request was stalled");
            }
        }
        if (fire || !dut_.sa_getacc_valid_o) {
            getacc_hold_active_ = false;
        }
    }

    void check_write_output(bool fire) {
        if (!dut_.mem_wr_valid_o) {
            if (wr_hold_active_) {
                fail("mem_wr_valid_o dropped while write request was stalled");
            }
            if (dut_.done_valid_o) {
                fail("done_valid_o asserted without a valid write");
            }
            return;
        }

        if (expected_writes_.empty()) {
            std::ostringstream os;
            os << "unexpected write at cycle " << cycle_
               << ": addr=" << dut_.mem_wr_addr_o
               << " data=" << hex64(dut_.mem_wr_data_o);
            fail(os.str());
        }

        const WriteBeat& exp = expected_writes_.front();
        if (dut_.mem_wr_addr_o != exp.addr ||
            static_cast<uint64_t>(dut_.mem_wr_data_o) != exp.data) {
            std::ostringstream os;
            os << "write mismatch at cycle " << cycle_
               << " for " << exp.name
               << ": got addr=" << dut_.mem_wr_addr_o
               << " data=" << hex64(dut_.mem_wr_data_o)
               << ", expected addr=" << exp.addr
               << " data=" << hex64(exp.data);
            fail(os.str());
        }

        const bool expect_done = fire && exp.last_of_uop;
        if (static_cast<bool>(dut_.done_valid_o) != expect_done) {
            std::ostringstream os;
            os << "done_valid_o mismatch at cycle " << cycle_
               << " for " << exp.name
               << ": got " << static_cast<int>(dut_.done_valid_o)
               << ", expected " << static_cast<int>(expect_done);
            fail(os.str());
        }

        if (!dut_.mem_wr_ready_i) {
            if (!wr_hold_active_) {
                wr_hold_active_ = true;
                wr_hold_addr_ = dut_.mem_wr_addr_o;
                wr_hold_data_ = dut_.mem_wr_data_o;
            } else if (wr_hold_addr_ != dut_.mem_wr_addr_o ||
                       wr_hold_data_ != static_cast<uint64_t>(dut_.mem_wr_data_o)) {
                fail("write addr/data changed while write channel was stalled");
            }
        }
        if (fire) {
            wr_hold_active_ = false;
        }
    }

    void start_burst_from_getacc(const Uop& uop) {
        if (burst_.active) {
            fail("storeunit issued overlapping getacc bursts");
        }
        std::uniform_int_distribution<int> delay_dist(0, 5);
        burst_.active = true;
        burst_.base_addr = uop.addr;
        burst_.pacc = uop.pacc & kPaccIdxMask;
        burst_.row = 0;
        burst_.delay = delay_dist(rng_);
        burst_.name = uop.name;
    }

    void update_after_tick(bool uop_fire, const Uop& uop,
                           bool getacc_fire, uint32_t getacc_idx,
                           bool rsp_fire,
                           bool wr_fire) {
        if (uop_fire) {
            pending_getacc_.push_back(uop);
        }

        if (getacc_fire) {
            if (pending_getacc_.empty()) {
                fail("storeunit issued getacc with no accepted uop");
            }
            Uop exp = pending_getacc_.front();
            pending_getacc_.pop_front();
            if (getacc_idx != (exp.pacc & kPaccIdxMask)) {
                fail("wrong sa_getacc_idx_o");
            }
            start_burst_from_getacc(exp);
        }

        if (rsp_fire) {
            const uint64_t full_row = row_data(burst_.pacc, burst_.row);
            for (int beat = 0; beat < kRowWriteBeats; ++beat) {
                WriteBeat exp;
                exp.addr = beat_addr(burst_.base_addr, burst_.row, beat);
                exp.data = beat_data(full_row, beat);
                exp.last_of_uop =
                    (burst_.row == kSaWidth - 1) && (beat == kRowWriteBeats - 1);
                exp.name = burst_.name;
                expected_writes_.push_back(exp);
            }

            if (burst_.row == kSaWidth - 1) {
                burst_ = SaBurst{};
            } else {
                ++burst_.row;
            }
        } else if (burst_.active && burst_.delay > 0) {
            --burst_.delay;
        }

        if (wr_fire) {
            expected_writes_.pop_front();
        }
    }

    void run_sequence(const std::string& name,
                      const std::vector<Uop>& uops,
                      int max_cycles,
                      bool check_fifo_overlap = false) {
        size_t uop_idx = 0;
        size_t accepted_before_first_done = 0;
        bool first_done_seen = false;
        bool saw_getacc_write_overlap = false;
        uint64_t prior_accept_cycle = 0;
        std::bernoulli_distribution getacc_ready_dist(0.60);
        std::bernoulli_distribution wr_ready_dist(0.45);

        while (cycle_ < static_cast<uint64_t>(max_cycles)) {
            const Uop cur_uop = (uop_idx < uops.size()) ? uops[uop_idx] : Uop{};
            if (uop_idx < uops.size()) {
                drive_uop(cur_uop);
            } else {
                clear_uop();
            }
            dut_.sa_getacc_ready_i = getacc_ready_dist(rng_) ? 1 : 0;
            dut_.mem_wr_ready_i = wr_ready_dist(rng_) ? 1 : 0;
            const bool rsp_fire = drive_sa_response();
            dut_.eval();

            const bool uop_fire = dut_.uop_valid_i && dut_.uop_ready_o;
            const bool getacc_fire = dut_.sa_getacc_valid_o && dut_.sa_getacc_ready_i;
            const uint32_t getacc_idx = dut_.sa_getacc_idx_o;
            const bool wr_fire = dut_.mem_wr_valid_o && dut_.mem_wr_ready_i;

            if (uop_fire && !first_done_seen) {
                if (check_fifo_overlap && accepted_before_first_done != 0 &&
                    cycle_ != prior_accept_cycle + 1) {
                    fail(name + ": OUTPUT uops were not accepted consecutively");
                }
                ++accepted_before_first_done;
                prior_accept_cycle = cycle_;
            }
            if (getacc_fire && dut_.mem_wr_valid_o) {
                saw_getacc_write_overlap = true;
            }
            if (dut_.done_valid_o) first_done_seen = true;

            check_getacc_stability(getacc_fire);
            check_write_output(wr_fire);

            tick_raw();
            update_after_tick(uop_fire, cur_uop, getacc_fire, getacc_idx,
                              rsp_fire, wr_fire);
            if (uop_fire) {
                ++uop_idx;
            }

            if (uop_idx == uops.size() &&
                pending_getacc_.empty() &&
                !burst_.active &&
                expected_writes_.empty() &&
                !dut_.mem_wr_valid_o &&
                !dut_.sa_getacc_valid_o) {
                if (check_fifo_overlap && accepted_before_first_done != uops.size()) {
                    fail(name + ": descriptor FIFO did not absorb all directed uops");
                }
                if (check_fifo_overlap && !saw_getacc_write_overlap) {
                    fail(name + ": getacc and bus writeback never overlapped");
                }
                std::cout << name << ": passed, uops=" << uops.size()
                          << " cycles=" << cycle_ << "\n";
                return;
            }
        }

        std::ostringstream os;
        os << name << ": timeout, accepted=" << uop_idx << "/" << uops.size()
           << " pending_getacc=" << pending_getacc_.size()
           << " expected_writes=" << expected_writes_.size()
           << " burst_active=" << burst_.active;
        fail(os.str());
    }

    void directed_tests() {
        run_sequence(
            "directed_backpressure",
            {
                Uop{0x100, 0, "out0"},
                Uop{0x104, 3, "out1"},
                Uop{0x120, 7, "out2"},
                Uop{0x121, 1, "out3"},
            },
            2000,
            true
        );
    }

    void random_tests() {
        std::uniform_int_distribution<uint32_t> addr_dist(0, 0x3fff);
        std::uniform_int_distribution<int> pacc_dist(0, kPaccNum - 1);

        std::vector<Uop> uops;
        for (int i = 0; i < 100; ++i) {
            Uop uop;
            uop.addr = 0x1000u + addr_dist(rng_) + static_cast<uint32_t>(i * 9);
            uop.pacc = static_cast<uint32_t>(pacc_dist(rng_));
            uop.name = "rand" + std::to_string(i);
            uops.push_back(uop);
        }
        run_sequence("random_stress", uops, 20000);
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const uint32_t seed = parse_seed(argc, argv);
        StoreUnitTest test(seed);
        return test.run();
    } catch (const std::exception& e) {
        std::cerr << "storeunit test failed: " << e.what() << "\n";
        return 1;
    }
}
