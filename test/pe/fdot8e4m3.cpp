#include "Vfdot8e4m3.h"
#include "verilated.h"

#include <cfenv>
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

constexpr int kLastToOutLatency = 3;
#ifndef PACC_IDX_WIDTH_TEST
#define PACC_IDX_WIDTH_TEST 7
#endif
#ifndef PACC_EXP_WIDTH_TEST
#define PACC_EXP_WIDTH_TEST 10
#endif
#ifndef PACC_SIG_WIDTH_TEST
#define PACC_SIG_WIDTH_TEST 40
#endif
constexpr int kPaccIdxWidth = PACC_IDX_WIDTH_TEST;
constexpr int kPaccExpWidth = PACC_EXP_WIDTH_TEST;
constexpr int kPaccSigWidth = PACC_SIG_WIDTH_TEST;

constexpr uint32_t paccidx_mask() {
    static_assert(kPaccIdxWidth > 0, "PACC_IDX_WIDTH_TEST must be positive");
    static_assert(kPaccIdxWidth <= 32, "PACC_IDX_WIDTH_TEST must fit uint32_t");
    return kPaccIdxWidth == 32
        ? 0xffffffffu
        : static_cast<uint32_t>((uint64_t{1} << kPaccIdxWidth) - 1u);
}

constexpr uint32_t kPaccIdxMask = paccidx_mask();
constexpr int64_t kPseudoNanExp = (int64_t{1} << (kPaccExpWidth - 1)) - 1;
constexpr uint64_t kPaccSigMask = kPaccSigWidth == 64
    ? ~uint64_t{0}
    : ((uint64_t{1} << kPaccSigWidth) - 1u);

struct Pair {
    uint8_t a;
    uint8_t b;
};

struct DecodedFp8 {
    bool sign = false;
    bool zero = false;
    bool nan = false;
    int sig = 0;
    int exp2 = 0;
};

struct Expected {
    uint64_t due_cycle = 0;
    int64_t exp = 0;
    int64_t sig = 0;
    uint32_t paccidx = 0;
    bool accum = false;
    std::string name;
};

std::string hex8(uint8_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(2) << std::setfill('0')
       << static_cast<unsigned>(value);
    return os.str();
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

std::string hex_paccidx(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << value;
    return os.str();
}

std::string hex_sig(int64_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << (static_cast<uint64_t>(value) & kPaccSigMask);
    return os.str();
}

uint32_t float_to_bits(float value) {
    uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value), "float must be 32 bits");
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

DecodedFp8 decode_e4m3(uint8_t x) {
    DecodedFp8 dec;
    const int exp = (x >> 3) & 0xf;
    const int frac = x & 0x7;

    dec.sign = (x & 0x80) != 0;

    if (exp == 0) {
        dec.zero = (frac == 0);
        dec.sig = frac;
        dec.exp2 = -9;
    } else {
        dec.nan = (exp == 0xf) && (frac == 0x7);
        dec.sig = 8 + frac;
        dec.exp2 = exp - 10;
    }

    return dec;
}

long double fp8_product(uint8_t a, uint8_t b, bool& saw_nan) {
    const DecodedFp8 da = decode_e4m3(a);
    const DecodedFp8 db = decode_e4m3(b);

    if (da.nan || db.nan) {
        saw_nan = true;
        return 0.0L;
    }
    if (da.zero || db.zero) {
        return 0.0L;
    }

    const int prod_sig = da.sig * db.sig;
    const int prod_exp2 = da.exp2 + db.exp2;
    long double value = std::ldexp(static_cast<long double>(prod_sig), prod_exp2);
    if (da.sign ^ db.sign) {
        value = -value;
    }
    return value;
}

struct Pseudo {
    int64_t exp = 0;
    int64_t sig = 0;
};

int64_t sign_extend(uint64_t value, int width) {
    if (width >= 64) {
        return static_cast<int64_t>(value);
    }
    const uint64_t mask = (uint64_t{1} << width) - 1u;
    const uint64_t sign = uint64_t{1} << (width - 1);
    value &= mask;
    if ((value & sign) != 0) {
        value |= ~mask;
    }
    return static_cast<int64_t>(value);
}

Pseudo pseudo_nan() {
    return Pseudo{kPseudoNanExp, 1};
}

Pseudo pseudo_from_long_double(long double value, bool saw_nan) {
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

Pseudo reference_dot_pseudo(const std::vector<Pair>& pairs) {
    bool saw_nan = false;
    long double sum = 0.0L;

    for (const Pair& p : pairs) {
        sum += fp8_product(p.a, p.b, saw_nan);
    }

    return pseudo_from_long_double(sum, saw_nan);
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

class FdotTest {
public:
    explicit FdotTest(uint32_t seed) : seed_(seed), rng_(seed) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        dut_.valid_i = 0;
        dut_.a_i = 0;
        dut_.b_i = 0;
        dut_.first_i = 0;
        dut_.last_i = 0;
        dut_.paccidx_i = 0;
        dut_.accum_i = 0;
    }

    int run() {
        std::fesetround(FE_TONEAREST);
        reset();

        directed_tests();
        random_tests();
        idle(kLastToOutLatency + 8);

        if (!expected_.empty()) {
            fail("test finished with pending expected output");
        }
        if (in_dot_) {
            fail("test finished with an open dot product");
        }

        std::cout << "fdot8e4m3: passed " << dots_ << " dot products, "
                  << products_ << " products, seed=" << seed_ << "\n";
        return failures_ == 0 ? 0 : 1;
    }

private:
    Vfdot8e4m3 dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;
    std::deque<Expected> expected_;

    bool in_dot_ = false;
    std::vector<Pair> current_dot_;
    uint64_t dots_ = 0;
    uint64_t products_ = 0;
    int failures_ = 0;

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
            std::ostringstream os;
            os << "missed expected output for " << expected_.front().name
               << ", due cycle " << expected_.front().due_cycle
               << ", now " << cycle_;
            fail(os.str());
        }

        if (dut_.valid_o) {
            if (expected_.empty()) {
                std::ostringstream os;
                os << "unexpected valid_o at cycle " << cycle_
                   << ", exp=" << static_cast<int64_t>(dut_.psum_exp_o)
                   << ", sig=" << hex_sig(sign_extend(dut_.psum_sig_o, kPaccSigWidth));
                fail(os.str());
                return;
            }

            const Expected exp = expected_.front();
            expected_.pop_front();

            if (exp.due_cycle != cycle_) {
                std::ostringstream os;
                os << "valid_o at wrong cycle for " << exp.name
                   << ": got cycle " << cycle_
                   << ", expected cycle " << exp.due_cycle
                   << ", exp=" << static_cast<int64_t>(dut_.psum_exp_o)
                   << ", sig=" << hex_sig(sign_extend(dut_.psum_sig_o, kPaccSigWidth));
                fail(os.str());
                return;
            }

            const int64_t got_exp = sign_extend(dut_.psum_exp_o, kPaccExpWidth);
            const int64_t got_sig = sign_extend(dut_.psum_sig_o, kPaccSigWidth);

            if (got_exp != exp.exp) {
                std::ostringstream os;
                os << "wrong pseudo exponent for " << exp.name
                   << " at cycle " << cycle_
                   << ": got " << got_exp
                   << ", expected " << exp.exp;
                fail(os.str());
                return;
            }

            if (got_sig != exp.sig) {
                std::ostringstream os;
                os << "wrong pseudo significand for " << exp.name
                   << " at cycle " << cycle_
                   << ": got " << hex_sig(got_sig)
                   << ", expected " << hex_sig(exp.sig);
                fail(os.str());
                return;
            }

            if (dut_.paccidx_o != exp.paccidx) {
                std::ostringstream os;
                os << "wrong paccidx for " << exp.name
                   << " at cycle " << cycle_
                   << ": got " << hex_paccidx(dut_.paccidx_o)
                   << ", expected " << hex_paccidx(exp.paccidx);
                fail(os.str());
                return;
            }

            if (static_cast<bool>(dut_.accum_o) != exp.accum) {
                std::ostringstream os;
                os << "wrong accum for " << exp.name
                   << " at cycle " << cycle_
                   << ": got " << static_cast<int>(dut_.accum_o)
                   << ", expected " << static_cast<int>(exp.accum);
                fail(os.str());
                return;
            }
        } else if (!expected_.empty() && expected_.front().due_cycle == cycle_) {
            std::ostringstream os;
            os << "missing valid_o for " << expected_.front().name
               << " at due cycle " << cycle_
               << ", expected exp=" << expected_.front().exp
               << ", sig=" << hex_sig(expected_.front().sig);
            fail(os.str());
        }
    }

    void idle(int cycles) {
        for (int i = 0; i < cycles; ++i) {
            dut_.valid_i = 0;
            dut_.a_i = 0;
            dut_.b_i = 0;
            dut_.first_i = 0;
            dut_.last_i = 0;
            dut_.paccidx_i = 0;
            dut_.accum_i = 0;
            tick();
        }
    }

    void send(uint8_t a,
              uint8_t b,
              bool first,
              bool last,
              uint32_t paccidx,
              bool accum,
              const std::string& name) {
        if (first) {
            if (in_dot_) {
                fail("new first_i arrived before previous dot completed");
            }
            in_dot_ = true;
            current_dot_.clear();
        } else if (!in_dot_) {
            fail("input without first_i for " + name);
        }

        current_dot_.push_back({a, b});
        ++products_;

        dut_.valid_i = 1;
        dut_.a_i = a;
        dut_.b_i = b;
        dut_.first_i = first ? 1 : 0;
        dut_.last_i = last ? 1 : 0;
        dut_.paccidx_i = paccidx & kPaccIdxMask;
        dut_.accum_i = accum ? 1 : 0;

        if (last) {
            const Pseudo expected_pseudo = reference_dot_pseudo(current_dot_);
            expected_.push_back(Expected{cycle_ + 1 + kLastToOutLatency,
                                         expected_pseudo.exp,
                                         expected_pseudo.sig,
                                         paccidx & kPaccIdxMask,
                                         accum,
                                         name});
            in_dot_ = false;
            current_dot_.clear();
            ++dots_;
        }

        tick();
    }

    void send_dot(const std::string& name,
                  const std::vector<Pair>& pairs,
                  int intra_gap_max,
                  int post_gap) {
        if (pairs.empty()) {
            fail("empty dot test requested: " + name);
        }

        std::uniform_int_distribution<int> gap_dist(0, intra_gap_max);
        std::uniform_int_distribution<uint32_t> paccidx_dist(0, kPaccIdxMask);
        std::bernoulli_distribution accum_dist(0.5);

        const uint32_t final_paccidx = paccidx_dist(rng_);
        const bool final_accum = accum_dist(rng_);

        for (size_t i = 0; i < pairs.size(); ++i) {
            const bool is_last = i + 1 == pairs.size();
            const uint32_t paccidx = is_last ? final_paccidx : paccidx_dist(rng_);
            const bool accum = is_last ? final_accum : accum_dist(rng_);
            send(pairs[i].a, pairs[i].b, i == 0, is_last, paccidx, accum, name);
            if (i + 1 != pairs.size() && intra_gap_max > 0) {
                idle(gap_dist(rng_));
            }
        }

        if (post_gap > 0) {
            idle(post_gap);
        }
    }

    void directed_tests() {
        // E4M3 encodings used here:
        //   0x38 =  1.0, 0x40 =  2.0, 0x30 = 0.5, 0x48 = 4.0
        //   0xb8 = -1.0, 0xc0 = -2.0, 0x01 = min positive subnormal
        send_dot("single_1x2",
                 {{0x38, 0x40}},
                 0,
                 0);

        send_dot("two_term_back_to_back",
                 {{0x38, 0x40}, {0x30, 0x48}},
                 0,
                 0);

        send_dot("negative_product",
                 {{0xb8, 0x40}},
                 0,
                 1);

        send_dot("cancellation_to_zero",
                 {{0x38, 0x40}, {0xb8, 0x40}},
                 1,
                 0);

        send_dot("subnormal_products",
                 {{0x01, 0x38}, {0x01, 0x40}, {0x81, 0x38}},
                 2,
                 0);

        send_dot("max_finite_mix",
                 {{0x7e, 0x7e}, {0xfe, 0x38}, {0x3f, 0x3f}, {0xbf, 0x3f}},
                 0,
                 2);

        send_dot("nan_operand",
                 {{0x38, 0x40}, {0x7f, 0x38}, {0x30, 0x48}},
                 0,
                 0);

        send_dot("single_cycle_nan",
                 {{0xff, 0x38}},
                 0,
                 3);
    }

    void random_tests() {
        std::uniform_int_distribution<int> len_dist(1, 96);
        std::uniform_int_distribution<int> gap_dist(0, 3);
        std::uniform_int_distribution<int> nan_dist(0, 99);

        for (int t = 0; t < 2000; ++t) {
            const int len = len_dist(rng_);
            std::vector<Pair> pairs;
            pairs.reserve(static_cast<size_t>(len));

            for (int i = 0; i < len; ++i) {
                uint8_t a = random_finite_e4m3(rng_);
                uint8_t b = random_finite_e4m3(rng_);

                if (nan_dist(rng_) == 0) {
                    a = (nan_dist(rng_) & 1) ? 0x7f : 0xff;
                }

                pairs.push_back({a, b});
            }

            std::ostringstream name;
            name << "random_" << t << "_len_" << len;
            send_dot(name.str(), pairs, gap_dist(rng_), gap_dist(rng_));
        }
    }

    [[noreturn]] void fail(const std::string& message) {
        ++failures_;
        std::cerr << "FAIL at cycle " << cycle_ << ": " << message << "\n";
        std::exit(1);
    }
};

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x5eed1234u;
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
    const uint32_t seed = parse_seed(argc, argv);
    FdotTest test(seed);
    return test.run();
}
