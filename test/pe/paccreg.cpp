#include "Vpaccreg.h"
#include "verilated.h"

#include <cfenv>
#include <array>
#include <algorithm>
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

constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kPaccIdxWidth = PACC_IDX_WIDTH_TEST;
constexpr int kPaccExpWidth = PACC_EXP_WIDTH_TEST;
constexpr int kPaccSigWidth = PACC_SIG_WIDTH_TEST;
constexpr int kAccumLatency = 6;
// Includes the synchronous read cycle of sram2r1w.
constexpr int kGetaccLatency = 5;
constexpr int64_t kPseudoNanExp = (int64_t{1} << (kPaccExpWidth - 1)) - 1;
#ifndef FDOT_ACC_FRAC_BITS_TEST
#define FDOT_ACC_FRAC_BITS_TEST 18
#endif
#ifndef FDOT_CSA_WIDTH_TEST
#define FDOT_CSA_WIDTH_TEST 64
#endif
constexpr int kFdotAccFracBits = FDOT_ACC_FRAC_BITS_TEST;
constexpr int kFdotCsaWidth = FDOT_CSA_WIDTH_TEST;

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

struct Pseudo {
    int64_t exp = 0;
    int64_t sig = 0;
};

struct ExpectedGet {
    uint64_t due_cycle = 0;
    uint32_t bits = 0;
    std::string name;
};

struct FixedInput {
    int64_t sum = 0;
    int64_t carry = 0;
    bool nan = false;
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

bool pseudo_is_nan(const Pseudo& value) {
    return value.exp == kPseudoNanExp && value.sig != 0;
}

Pseudo pseudo_nan() {
    return Pseudo{kPseudoNanExp, 1};
}

Pseudo pseudo_from_long_double(long double value) {
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

Pseudo pseudo_from_fixed(int64_t fixed, bool nan = false) {
    if (nan) {
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

int64_t fixed_from_long_double(long double value) {
    return static_cast<int64_t>(std::llround(std::ldexp(value, kFdotAccFracBits)));
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
        return Pseudo{target_exp + 1, sign_extend(bits_of_signed(arithmetic_shift_right_one(sum), kPaccSigWidth), kPaccSigWidth)};
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

    const long double real_value = std::ldexp(static_cast<long double>(value.sig), static_cast<int>(value.exp));
    uint32_t bits = float_to_bits(static_cast<float>(real_value));
    if ((bits & 0x7fffffffu) == 0) {
        bits = 0;
    }
    return bits;
}

class PaccregTest {
public:
    explicit PaccregTest(uint32_t seed) : seed_(seed), rng_(seed), model_(kPaccNum) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
    }

    int run() {
        std::fesetround(FE_TONEAREST);
        reset();
        directed_tests();
        random_tests();
        idle(kGetaccLatency + 5);

        if (!expected_.empty()) {
            fail("test finished with pending getacc output");
        }

        std::cout << "paccreg: passed, seed=" << seed_ << "\n";
        return 0;
    }

private:
    Vpaccreg dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;
    std::vector<Pseudo> model_;
    std::deque<ExpectedGet> expected_;

    void clear_inputs() {
        dut_.valid_i = 0;
        dut_.psum_sum_i = 0;
        dut_.psum_carry_i = 0;
        dut_.psum_nan_i = 0;
        dut_.paccidx_i = 0;
        dut_.accum_i = 0;
        dut_.getacc_i = 0;
        dut_.getacc_idx_i = 0;
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 5; ++i) {
            tick();
        }
        dut_.rst_n = 1;
        idle(2);
    }

    void tick() {
        dut_.clk = 0;
        dut_.eval();

        dut_.clk = 1;
        dut_.eval();
        ++cycle_;
        check_output();

        dut_.clk = 0;
        dut_.eval();
    }

    void check_output() {
        if (!expected_.empty() && expected_.front().due_cycle < cycle_) {
            fail("missed getacc output for " + expected_.front().name);
        }

        if (dut_.getacc_o) {
            if (expected_.empty()) {
                std::ostringstream os;
                os << "unexpected getacc_o at cycle " << cycle_
                   << ", data=" << hex32(dut_.getacc_data_o);
                fail(os.str());
            }

            const ExpectedGet exp = expected_.front();
            expected_.pop_front();
            if (exp.due_cycle != cycle_) {
                std::ostringstream os;
                os << "getacc_o at wrong cycle for " << exp.name
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
        } else if (!expected_.empty() && expected_.front().due_cycle == cycle_) {
            fail("missing getacc_o for " + expected_.front().name);
        }
    }

    void idle(int cycles) {
        for (int i = 0; i < cycles; ++i) {
            clear_inputs();
            tick();
        }
    }

    void send_acc(int idx, const FixedInput& value, bool accum) {
        dut_.valid_i = 1;
        dut_.psum_sum_i = bits_of_signed(value.sum, kFdotCsaWidth);
        dut_.psum_carry_i = bits_of_signed(value.carry, kFdotCsaWidth);
        dut_.psum_nan_i = value.nan ? 1 : 0;
        dut_.paccidx_i = idx;
        dut_.accum_i = accum ? 1 : 0;
        dut_.getacc_i = 0;
        dut_.getacc_idx_i = 0;

        model_[idx] = add_pseudo(
            model_[idx],
            pseudo_from_fixed(value.sum + value.carry, value.nan),
            accum
        );
        tick();
    }

    void send_value(int idx, long double value, bool accum) {
        send_acc(idx, FixedInput{fixed_from_long_double(value), 0, false}, accum);
    }

    void send_split_value(int idx, long double value, int64_t carry, bool accum) {
        const int64_t fixed = fixed_from_long_double(value);
        send_acc(idx, FixedInput{fixed - carry, carry, false}, accum);
    }

    void send_nan(int idx, bool accum) {
        send_acc(idx, FixedInput{0, 0, true}, accum);
    }

    void request_get(int idx, const std::string& name) {
        dut_.valid_i = 0;
        dut_.psum_sum_i = 0;
        dut_.psum_carry_i = 0;
        dut_.psum_nan_i = 0;
        dut_.paccidx_i = 0;
        dut_.accum_i = 0;
        dut_.getacc_i = 1;
        dut_.getacc_idx_i = idx;

        expected_.push_back(ExpectedGet{cycle_ + 1 + kGetaccLatency,
                                        pseudo_to_fp32_bits(model_[idx]),
                                        name});
        tick();
    }

    void get_all(const std::string& prefix) {
        idle(kAccumLatency + 1);
        for (int i = 0; i < kPaccNum; ++i) {
            std::ostringstream name;
            name << prefix << "_idx" << i;
            request_get(i, name.str());
        }
        idle(kGetaccLatency + 1);
    }

    void directed_tests() {
        get_all("reset");

        send_value(0, 1.5L, false);
        get_all("cover_1p5");

        send_value(0, 2.25L, true);
        get_all("accum_2p25");

        send_value(0, -4.0L, false);
        get_all("cover_negative");

        send_value(1, 8.0L, false);
        send_value(2, -3.5L, false);
        idle(2);
        send_value(1, 0.5L, true);
        get_all("independent_regs");

        send_split_value(3, 1.0L, 12345, false);
        idle(3);
        send_split_value(3, 2.0L, -54321, true);
        idle(3);
        send_value(3, 3.0L, true);
        get_all("back_to_back_same_idx");

        send_nan(4, false);
        idle(3);
        send_value(4, 1.0L, true);
        get_all("nan_sticky");

        send_value(4, 7.0L, false);
        get_all("nan_cover_clear");
    }

    void random_tests() {
        std::uniform_int_distribution<int> idx_dist(0, kPaccNum - 1);
        std::uniform_int_distribution<int> batch_dist(1, 24);
        std::uniform_int_distribution<int> value_dist(-4096, 4096);
        std::bernoulli_distribution accum_dist(0.65);
        std::bernoulli_distribution nan_dist(0.01);

        for (int batch = 0; batch < 250; ++batch) {
            const int count = batch_dist(rng_);
            std::array<int, 3> recent_idx = {-1, -1, -1};
            for (int i = 0; i < count; ++i) {
                const int idx = idx_dist(rng_);
                while (std::find(recent_idx.begin(), recent_idx.end(), idx) !=
                       recent_idx.end()) {
                    idle(1);
                    recent_idx[2] = recent_idx[1];
                    recent_idx[1] = recent_idx[0];
                    recent_idx[0] = -1;
                }
                const long double real_value =
                    static_cast<long double>(value_dist(rng_)) / 16.0L;
                FixedInput value;
                if (nan_dist(rng_)) {
                    value.nan = true;
                } else {
                    const int64_t fixed = fixed_from_long_double(real_value);
                    const int64_t carry = (i & 1) ? int64_t{17} : int64_t{0};
                    value.sum = fixed - carry;
                    value.carry = carry;
                }
                const bool accum = accum_dist(rng_);
                send_acc(idx, value, accum);
                recent_idx[2] = recent_idx[1];
                recent_idx[1] = recent_idx[0];
                recent_idx[0] = idx;
            }
            get_all("random_batch_" + std::to_string(batch));
        }
    }

    [[noreturn]] void fail(const std::string& message) {
        std::cerr << "FAIL at cycle " << cycle_ << ": " << message << "\n";
        std::exit(1);
    }
};

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0xacc123u;
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
    PaccregTest test(parse_seed(argc, argv));
    return test.run();
}
