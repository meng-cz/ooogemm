#include "Vpe.h"
#include "verilated.h"

#include <cfenv>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace {

#ifndef GEMM_LANE_NUM_TEST
#define GEMM_LANE_NUM_TEST 4
#endif
#ifndef PACC_NUM_TEST
#define PACC_NUM_TEST 8
#endif
#ifndef PACC_IDX_WIDTH_TEST
#define PACC_IDX_WIDTH_TEST 3
#endif
#ifndef PACC_EXP_WIDTH_TEST
#define PACC_EXP_WIDTH_TEST 10
#endif
#ifndef PACC_SIG_WIDTH_TEST
#define PACC_SIG_WIDTH_TEST 40
#endif

constexpr int kLaneNum = GEMM_LANE_NUM_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kPaccIdxWidth = PACC_IDX_WIDTH_TEST;
constexpr int kPaccExpWidth = PACC_EXP_WIDTH_TEST;
constexpr int kPaccSigWidth = PACC_SIG_WIDTH_TEST;
constexpr int kFdotLatency = 2;
constexpr int kFdotToPaccregReduceLatency = 1;
constexpr int kPaccregAccumLatency = 7;
// Includes the synchronous read cycle of sram2r1w.
constexpr int kGetaccLatency = 5;
constexpr int64_t kPseudoNanExp = (int64_t{1} << (kPaccExpWidth - 1)) - 1;
constexpr int kFdotAccFracBits = 18;

struct LaneIn {
    uint8_t valid = 0;
    uint8_t a = 0;
    uint8_t first = 0;
    uint8_t last = 0;
    uint32_t paccidx = 0;
    uint8_t accum = 0;
    uint8_t b = 0;
};

struct Pair {
    uint8_t a = 0;
    uint8_t b = 0;
};

struct DecodedFp8 {
    bool sign = false;
    bool zero = false;
    bool nan = false;
    int sig = 0;
    int exp2 = 0;
};

struct Pseudo {
    int64_t exp = 0;
    int64_t sig = 0;
};

struct ExpectedGet {
    uint64_t due_cycle = 0;
    uint32_t bits = 0;
    std::string name;
};

uint64_t low_mask(int width) {
    return width >= 64 ? ~uint64_t{0} : ((uint64_t{1} << width) - 1u);
}

int64_t sign_extend(uint64_t value, int width) {
    if (width >= 64) {
        return static_cast<int64_t>(value);
    }
    const uint64_t mask = low_mask(width);
    const uint64_t sign = uint64_t{1} << (width - 1);
    value &= mask;
    if ((value & sign) != 0) {
        value |= ~mask;
    }
    return static_cast<int64_t>(value);
}

uint64_t bits_of_signed(int64_t value, int width) {
    return static_cast<uint64_t>(value) & low_mask(width);
}

uint32_t float_to_bits(float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

DecodedFp8 decode_e4m3(uint8_t x) {
    DecodedFp8 dec;
    const int exp = (x >> 3) & 0xf;
    const int frac = x & 0x7;
    dec.sign = (x & 0x80) != 0;
    if (exp == 0) {
        dec.zero = frac == 0;
        dec.sig = frac;
        dec.exp2 = -9;
    } else {
        dec.nan = exp == 0xf && frac == 0x7;
        dec.sig = 8 + frac;
        dec.exp2 = exp - 10;
    }
    return dec;
}

bool is_nan_e4m3(uint8_t x) {
    return ((x & 0x78) == 0x78) && ((x & 0x07) == 0x07);
}

uint8_t random_finite_e4m3(std::mt19937& rng) {
    std::uniform_int_distribution<int> dist(0, 255);
    uint8_t value = 0;
    do {
        value = static_cast<uint8_t>(dist(rng));
    } while (is_nan_e4m3(value));
    return value;
}

int64_t fp8_product_fixed(uint8_t a, uint8_t b, bool& saw_nan) {
    const DecodedFp8 da = decode_e4m3(a);
    const DecodedFp8 db = decode_e4m3(b);
    if (da.nan || db.nan) {
        saw_nan = true;
        return 0;
    }
    if (da.zero || db.zero) {
        return 0;
    }

    const int shift = da.exp2 + db.exp2 + kFdotAccFracBits;
    int64_t value = 0;
    if (shift >= 0) {
        value = static_cast<int64_t>(da.sig * db.sig) << shift;
    } else {
        value = static_cast<int64_t>(da.sig * db.sig) >> -shift;
    }
    return (da.sign ^ db.sign) ? -value : value;
}

Pseudo pseudo_nan() {
    return Pseudo{kPseudoNanExp, 1};
}

bool pseudo_is_nan(const Pseudo& value) {
    return value.exp == kPseudoNanExp && value.sig != 0;
}

Pseudo pseudo_from_long_double(long double value, bool saw_nan = false) {
    if (saw_nan) {
        return pseudo_nan();
    }
    if (value == 0.0L) {
        return Pseudo{};
    }

    const bool neg = value < 0.0L;
    long double abs_value = neg ? -value : value;
    int frexp_exp = 0;
    std::frexp(abs_value, &frexp_exp);
    const int top_exp = frexp_exp - 1;
    const int sig_top = kPaccSigWidth - 2;
    const long double scaled = std::ldexp(abs_value, sig_top - top_exp);
    const uint64_t mag = static_cast<uint64_t>(scaled);
    const int64_t sig = neg ? -static_cast<int64_t>(mag) : static_cast<int64_t>(mag);
    return Pseudo{top_exp - sig_top, sig};
}

Pseudo pseudo_from_fixed(int64_t fixed, bool saw_nan = false) {
    if (saw_nan) {
        return pseudo_nan();
    }
    if (fixed == 0) {
        return Pseudo{};
    }

    const bool neg = fixed < 0;
    uint64_t abs_value = neg ? static_cast<uint64_t>(-fixed) : static_cast<uint64_t>(fixed);
    int msb = 0;
    for (int i = 0; i < 63; ++i) {
        if ((abs_value & (uint64_t{1} << i)) != 0) {
            msb = i;
        }
    }

    uint64_t mag = 0;
    for (int i = 0; i < kPaccSigWidth - 1; ++i) {
        const int src = msb - (kPaccSigWidth - 2) + i;
        if (src >= 0 && src < 63 && ((abs_value & (uint64_t{1} << src)) != 0)) {
            mag |= uint64_t{1} << i;
        }
    }

    const int64_t sig = neg ? -static_cast<int64_t>(mag) : static_cast<int64_t>(mag);
    return Pseudo{msb - kFdotAccFracBits - (kPaccSigWidth - 2), sig};
}

Pseudo reference_dot_pseudo(const std::vector<Pair>& pairs) {
    bool saw_nan = false;
    int64_t sum = 0;
    for (const Pair& p : pairs) {
        sum += fp8_product_fixed(p.a, p.b, saw_nan);
    }
    return pseudo_from_fixed(sum, saw_nan);
}

int64_t trunc_shift_abs_signed(int64_t sig, int shift) {
    if (sig == 0 || shift >= kPaccSigWidth) {
        return 0;
    }
    const bool neg = sig < 0;
    uint64_t mag = neg ? static_cast<uint64_t>(-sig) : static_cast<uint64_t>(sig);
    if (shift > 0) {
        mag >>= shift;
    }
    const int64_t shifted = static_cast<int64_t>(mag);
    return neg ? -shifted : shifted;
}

int64_t arithmetic_shift_right_one(int64_t value) {
    if (value >= 0) {
        return value >> 1;
    }
    return -(((-value) + 1) >> 1);
}

Pseudo add_pseudo(const Pseudo& cur, const Pseudo& in, bool accum) {
    if (pseudo_is_nan(in) || (accum && pseudo_is_nan(cur))) {
        return pseudo_nan();
    }
    if (!accum || cur.sig == 0) {
        return in;
    }
    if (in.sig == 0) {
        return cur;
    }

    const int64_t target_exp = cur.exp >= in.exp ? cur.exp : in.exp;
    const int cur_shift = static_cast<int>(target_exp - cur.exp);
    const int in_shift = static_cast<int>(target_exp - in.exp);
    const int64_t sum = trunc_shift_abs_signed(cur.sig, cur_shift) +
                        trunc_shift_abs_signed(in.sig, in_shift);

    if (sum == 0) {
        return Pseudo{};
    }

    const int64_t min_sig = -(int64_t{1} << (kPaccSigWidth - 1));
    const int64_t max_sig = (int64_t{1} << (kPaccSigWidth - 1)) - 1;
    if (sum < min_sig || sum > max_sig) {
        return Pseudo{
            target_exp + 1,
            sign_extend(bits_of_signed(arithmetic_shift_right_one(sum), kPaccSigWidth),
                        kPaccSigWidth)
        };
    }
    return Pseudo{target_exp, sign_extend(bits_of_signed(sum, kPaccSigWidth), kPaccSigWidth)};
}

uint32_t pseudo_to_fp32_bits(const Pseudo& value) {
    if (pseudo_is_nan(value)) {
        return 0x7fc00000u;
    }
    if (value.sig == 0) {
        return 0;
    }

    const long double real_value =
        std::ldexp(static_cast<long double>(value.sig), static_cast<int>(value.exp));
    uint32_t bits = float_to_bits(static_cast<float>(real_value));
    if ((bits & 0x7fffffffu) == 0) {
        bits = 0;
    }
    return bits;
}

class PeTest {
public:
    explicit PeTest(uint32_t seed)
        : seed_(seed), rng_(seed), pacc_model_(kPaccNum), lane_dots_(kLaneNum) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
    }

    int run() {
        std::fesetround(FE_TONEAREST);
        reset();
        directed_tests();
        random_tests();
        idle(kFdotLatency + kFdotToPaccregReduceLatency +
             kPaccregAccumLatency + kGetaccLatency + 8);

        if (!expected_gets_.empty()) {
            fail("test finished with pending getacc output");
        }

        std::cout << "pe: passed, seed=" << seed_ << "\n";
        return 0;
    }

private:
    Vpe dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;
    std::vector<Pseudo> pacc_model_;
    std::vector<std::vector<Pair>> lane_dots_;
    std::deque<ExpectedGet> expected_gets_;
    LaneIn drive_[kLaneNum];

    void clear_inputs() {
        for (int lane = 0; lane < kLaneNum; ++lane) {
            drive_[lane] = LaneIn{};
            apply_lane(lane, drive_[lane]);
        }
        dut_.getacc_i = 0;
        dut_.getacc_idx_i = 0;
    }

    void apply_lane(int lane, const LaneIn& in) {
        dut_.left_valid_i[lane] = in.valid;
        dut_.left_a_i[lane] = in.a;
        dut_.left_first_i[lane] = in.first;
        dut_.left_last_i[lane] = in.last;
        dut_.left_paccidx_i[lane] = in.paccidx;
        dut_.left_accum_i[lane] = in.accum;
        dut_.top_b_i[lane] = in.b;
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 5; ++i) {
            tick(false);
        }
        dut_.rst_n = 1;
        idle(2);
    }

    void tick(bool check_forward = true) {
        dut_.clk = 0;
        dut_.eval();

        dut_.clk = 1;
        dut_.eval();
        ++cycle_;
        if (check_forward) {
            check_forward_outputs();
        }
        check_getacc_output();

        dut_.clk = 0;
        dut_.eval();
    }

    void check_forward_outputs() {
        for (int lane = 0; lane < kLaneNum; ++lane) {
            const LaneIn& exp = drive_[lane];
            if (dut_.right_valid_o[lane] != exp.valid ||
                dut_.right_a_o[lane] != exp.a ||
                dut_.right_first_o[lane] != exp.first ||
                dut_.right_last_o[lane] != exp.last ||
                dut_.right_paccidx_o[lane] != exp.paccidx ||
                dut_.right_accum_o[lane] != exp.accum ||
                dut_.bottom_b_o[lane] != exp.b) {
                std::ostringstream os;
                os << "forward mismatch at cycle " << cycle_ << ", lane " << lane;
                fail(os.str());
            }
        }
    }

    void check_getacc_output() {
        if (!expected_gets_.empty() && expected_gets_.front().due_cycle < cycle_) {
            fail("missed getacc output for " + expected_gets_.front().name);
        }

        if (dut_.getacc_o) {
            if (expected_gets_.empty()) {
                std::ostringstream os;
                os << "unexpected getacc_o at cycle " << cycle_
                   << ", data=" << hex32(dut_.getacc_data_o);
                fail(os.str());
            }

            const ExpectedGet exp = expected_gets_.front();
            expected_gets_.pop_front();
            if (exp.due_cycle != cycle_) {
                std::ostringstream os;
                os << "wrong getacc cycle for " << exp.name
                   << ": got " << cycle_ << ", expected " << exp.due_cycle;
                fail(os.str());
            }
            if (dut_.getacc_data_o != exp.bits) {
                std::ostringstream os;
                os << "wrong getacc data for " << exp.name
                   << ": got " << hex32(dut_.getacc_data_o)
                   << ", expected " << hex32(exp.bits);
                fail(os.str());
            }
        } else if (!expected_gets_.empty() && expected_gets_.front().due_cycle == cycle_) {
            fail("missing getacc_o for " + expected_gets_.front().name);
        }
    }

    void drive_cycle(const std::vector<LaneIn>& lanes) {
        int last_count = 0;
        for (int lane = 0; lane < kLaneNum; ++lane) {
            drive_[lane] = lanes[lane];
            if (drive_[lane].valid && drive_[lane].last) {
                ++last_count;
            }
            apply_lane(lane, drive_[lane]);
        }
        if (last_count > 1) {
            fail("test stimulus violated at-most-one-last constraint");
        }

        dut_.getacc_i = 0;
        dut_.getacc_idx_i = 0;

        for (int lane = 0; lane < kLaneNum; ++lane) {
            if (!drive_[lane].valid) {
                continue;
            }
            if (drive_[lane].first) {
                lane_dots_[lane].clear();
            }
            lane_dots_[lane].push_back(Pair{drive_[lane].a, drive_[lane].b});
            if (drive_[lane].last) {
                const Pseudo dot = reference_dot_pseudo(lane_dots_[lane]);
                const int idx = static_cast<int>(drive_[lane].paccidx);
                pacc_model_[idx] = add_pseudo(pacc_model_[idx], dot, drive_[lane].accum != 0);
                lane_dots_[lane].clear();
            }
        }

        tick();
    }

    void idle(int cycles) {
        for (int i = 0; i < cycles; ++i) {
            std::vector<LaneIn> lanes(kLaneNum);
            drive_cycle(lanes);
        }
    }

    void request_get(int idx, const std::string& name) {
        std::vector<LaneIn> lanes(kLaneNum);
        for (int lane = 0; lane < kLaneNum; ++lane) {
            drive_[lane] = lanes[lane];
            apply_lane(lane, drive_[lane]);
        }

        dut_.getacc_i = 1;
        dut_.getacc_idx_i = idx;
        expected_gets_.push_back(ExpectedGet{cycle_ + 1 + kGetaccLatency,
                                             pseudo_to_fp32_bits(pacc_model_[idx]),
                                             name});
        tick();
        dut_.getacc_i = 0;
        dut_.getacc_idx_i = 0;
    }

    void get_all(const std::string& prefix) {
        idle(kFdotLatency + kFdotToPaccregReduceLatency +
             kPaccregAccumLatency + 2);
        for (int idx = 0; idx < kPaccNum; ++idx) {
            request_get(idx, prefix + "_idx" + std::to_string(idx));
        }
        idle(kGetaccLatency + 1);
    }

    void send_single(int lane,
                     uint8_t a,
                     uint8_t b,
                     int paccidx,
                     bool accum,
                     int gap_after = 0) {
        std::vector<LaneIn> lanes(kLaneNum);
        lanes[lane].valid = 1;
        lanes[lane].a = a;
        lanes[lane].b = b;
        lanes[lane].first = 1;
        lanes[lane].last = 1;
        lanes[lane].paccidx = static_cast<uint32_t>(paccidx);
        lanes[lane].accum = accum ? 1 : 0;
        drive_cycle(lanes);
        idle(gap_after);
    }

    void directed_tests() {
        get_all("reset");

        send_single(0, 0x38, 0x40, 0, false, 1);  // 1.0 * 2.0
        get_all("lane0_cover");

        send_single(1, 0x30, 0x48, 0, true, 1);   // 0.5 * 4.0
        get_all("lane1_accum");

        const int stagger_lane0 = kLaneNum >= 3 ? 2 : 0;
        const int stagger_lane1 = kLaneNum >= 4 ? 3 : 1;

        std::vector<LaneIn> lanes(kLaneNum);
        lanes[stagger_lane0] = LaneIn{1, 0x38, 1, 0, 1, 0, 0x40};
        lanes[stagger_lane1] = LaneIn{1, 0x38, 1, 0, 2, 0, 0x40};
        drive_cycle(lanes);

        lanes = std::vector<LaneIn>(kLaneNum);
        lanes[stagger_lane0] = LaneIn{1, 0x30, 0, 1, 1, 0, 0x48};
        lanes[stagger_lane1] = LaneIn{1, 0x30, 0, 0, 2, 0, 0x48};
        drive_cycle(lanes);

        lanes = std::vector<LaneIn>(kLaneNum);
        lanes[stagger_lane1] = LaneIn{1, 0x30, 0, 1, 2, 0, 0x48};
        drive_cycle(lanes);
        get_all("multi_lane_staggered_last");

        send_single(0, 0x7f, 0x38, 3, false, 0);
        get_all("nan_cover");
    }

    void random_tests() {
        struct Active {
            bool active = false;
            int remaining = 0;
            int paccidx = 0;
            bool accum = false;
        };

        std::vector<Active> active(kLaneNum);
        std::uniform_int_distribution<int> len_dist(1, 8);
        std::uniform_int_distribution<int> idx_dist(0, kPaccNum - 1);
        std::uniform_int_distribution<int> start_dist(0, 99);
        std::bernoulli_distribution accum_dist(0.6);
        std::uniform_int_distribution<int> nan_dist(0, 199);

        int dots_started = 0;
        int dots_finished = 0;
        std::array<int, 3> recent_last_paccidx = {-1, -1, -1};
        constexpr int kTargetDots = 320;

        while (dots_finished < kTargetDots) {
            std::vector<LaneIn> lanes(kLaneNum);
            bool used_last = false;
            bool this_last_valid = false;
            int this_last_paccidx = -1;

            for (int lane = 0; lane < kLaneNum; ++lane) {
                if (!active[lane].active && dots_started < kTargetDots && start_dist(rng_) < 45) {
                    active[lane].active = true;
                    active[lane].remaining = len_dist(rng_);
                    active[lane].paccidx = idx_dist(rng_);
                    active[lane].accum = accum_dist(rng_);
                    ++dots_started;
                }

                if (!active[lane].active) {
                    continue;
                }

                const bool is_first = lane_dots_[lane].empty();
                bool is_last = active[lane].remaining == 1;
                if (is_last && used_last) {
                    continue;
                }
                if (is_last &&
                    std::find(recent_last_paccidx.begin(),
                              recent_last_paccidx.end(),
                              active[lane].paccidx) !=
                        recent_last_paccidx.end()) {
                    continue;
                }

                uint8_t a = random_finite_e4m3(rng_);
                uint8_t b = random_finite_e4m3(rng_);
                if (nan_dist(rng_) == 0) {
                    a = 0x7f;
                }

                lanes[lane].valid = 1;
                lanes[lane].a = a;
                lanes[lane].b = b;
                lanes[lane].first = is_first ? 1 : 0;
                lanes[lane].last = is_last ? 1 : 0;
                lanes[lane].paccidx = static_cast<uint32_t>(active[lane].paccidx);
                lanes[lane].accum = active[lane].accum ? 1 : 0;

                --active[lane].remaining;
                if (is_last) {
                    used_last = true;
                    this_last_valid = true;
                    this_last_paccidx = active[lane].paccidx;
                    active[lane].active = false;
                    ++dots_finished;
                }
            }

            drive_cycle(lanes);
            recent_last_paccidx[2] = recent_last_paccidx[1];
            recent_last_paccidx[1] = recent_last_paccidx[0];
            recent_last_paccidx[0] = this_last_valid ? this_last_paccidx : -1;
        }

        for (;;) {
            bool any_active = false;
            for (const Active& lane : active) {
                any_active |= lane.active;
            }
            if (!any_active) {
                break;
            }
            drive_cycle(std::vector<LaneIn>(kLaneNum));
        }

        get_all("random_final");
    }

    [[noreturn]] void fail(const std::string& message) {
        std::cerr << "FAIL at cycle " << cycle_ << ": " << message << "\n";
        std::exit(1);
    }
};

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x0fee123u;
    const std::string prefix = "--seed=";
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg.rfind(prefix, 0) == 0) {
            seed = static_cast<uint32_t>(std::stoul(arg.substr(prefix.size()), nullptr, 0));
        }
    }
    return seed;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    PeTest test(parse_seed(argc, argv));
    return test.run();
}
