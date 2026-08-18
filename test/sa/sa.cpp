#include "Vsa.h"
#include "verilated.h"

#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 2
#endif
#ifndef LANE_NUM_TEST
#define LANE_NUM_TEST 2
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

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kLaneNum = LANE_NUM_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kPaccExpWidth = PACC_EXP_WIDTH_TEST;
constexpr int kPaccSigWidth = PACC_SIG_WIDTH_TEST;
constexpr int64_t kPseudoNanExp = (int64_t{1} << (kPaccExpWidth - 1)) - 1;

static_assert(kSaWidth >= 2, "this testbench expects SA_WIDTH_TEST>=2");
static_assert(kSaWidth <= 4, "this testbench supports SA_WIDTH_TEST<=4");
static_assert(kLaneNum >= 2, "this testbench expects at least two lanes");

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

struct Matrix {
    uint8_t a[kSaWidth][kSaWidth] = {};
    uint8_t b[kSaWidth][kSaWidth] = {};
};

struct ExpectedRow {
    int row = 0;
    uint32_t data[kSaWidth] = {};
    std::string name;
};

uint64_t low_mask(int width) {
    return width >= 64 ? ~uint64_t{0} : ((uint64_t{1} << width) - 1u);
}

uint64_t bits_of_signed(int64_t value, int width) {
    return static_cast<uint64_t>(value) & low_mask(width);
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

    long double value = std::ldexp(
        static_cast<long double>(da.sig * db.sig),
        da.exp2 + db.exp2
    );
    if (da.sign ^ db.sign) {
        value = -value;
    }
    return value;
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
    const long double abs_value = neg ? -value : value;
    int frexp_exp = 0;
    std::frexp(abs_value, &frexp_exp);
    const int top_exp = frexp_exp - 1;
    const int sig_top = kPaccSigWidth - 2;
    const long double scaled = std::ldexp(abs_value, sig_top - top_exp);
    const uint64_t mag = static_cast<uint64_t>(scaled);
    const int64_t sig = neg ? -static_cast<int64_t>(mag) : static_cast<int64_t>(mag);
    return Pseudo{top_exp - sig_top, sig};
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

Pseudo reference_cell(const Matrix& m, int row, int col) {
    bool saw_nan = false;
    long double sum = 0.0L;
    for (int k = 0; k < kSaWidth; ++k) {
        sum += fp8_product(m.a[row][k], m.b[k][col], saw_nan);
    }
    return pseudo_from_long_double(sum, saw_nan);
}

uint32_t pack_row(const uint8_t row[kSaWidth]) {
    uint32_t bits = 0;
    for (int i = 0; i < kSaWidth; ++i) {
        bits |= static_cast<uint32_t>(row[i]) << (8 * i);
    }
    return bits;
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

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x51a5a123u;
    const std::string prefix = "--seed=";
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);
        if (arg.rfind(prefix, 0) == 0) {
            seed = static_cast<uint32_t>(std::stoul(arg.substr(prefix.size()), nullptr, 0));
        }
    }
    return seed;
}

class SaTest {
public:
    explicit SaTest(uint32_t seed)
        : seed_(seed),
          rng_(seed),
          pacc_model_(kSaWidth,
                      std::vector<std::vector<Pseudo>>(
                          kSaWidth, std::vector<Pseudo>(kPaccNum))) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
    }

    int run() {
        std::fesetround(FE_TONEAREST);
        reset();

        getacc_and_expect(0, "reset_idx0");
        allocator_priority_test();
        continuous_allocator_order_test();

        Matrix m0{};
        m0.a[0][0] = 0x38;  // 1.0
        m0.a[0][1] = 0x40;  // 2.0
        m0.a[1][0] = 0x30;  // 0.5
        m0.a[1][1] = 0xb8;  // -1.0
        m0.b[0][0] = 0x38;  // 1.0
        m0.b[0][1] = 0x40;  // 2.0
        m0.b[1][0] = 0x48;  // 4.0
        m0.b[1][1] = 0x30;  // 0.5
        issue_gemm(m0, 0x11, 0, false);
        wait_finish(0x11);
        getacc_and_expect(0, "cover_idx0");

        Matrix m1{};
        m1.a[0][0] = 0x40;
        m1.a[0][1] = 0x30;
        m1.a[1][0] = 0x38;
        m1.a[1][1] = 0x38;
        m1.b[0][0] = 0x30;
        m1.b[0][1] = 0xb8;
        m1.b[1][0] = 0x38;
        m1.b[1][1] = 0x40;
        issue_gemm(m1, 0x12, 0, true);
        wait_finish(0x12);
        getacc_and_expect(0, "accum_idx0");

        Matrix m2{};
        m2.a[0][0] = 0x38;
        m2.a[0][1] = 0x38;
        m2.a[1][0] = 0x40;
        m2.a[1][1] = 0x30;
        m2.b[0][0] = 0x40;
        m2.b[0][1] = 0x30;
        m2.b[1][0] = 0x38;
        m2.b[1][1] = 0x38;

        Matrix m3{};
        m3.a[0][0] = 0xb8;
        m3.a[0][1] = 0x40;
        m3.a[1][0] = 0x30;
        m3.a[1][1] = 0x48;
        m3.b[0][0] = 0x38;
        m3.b[0][1] = 0x38;
        m3.b[1][0] = 0x30;
        m3.b[1][1] = 0xb8;

        const int lane2 = allocate(0x21, 1, false);
        write_matrices(lane2, m2);
        const int lane3 = allocate(0x22, 2, false);
        write_matrices(lane3, m3);
        update_model(m2, 1, false);
        update_model(m3, 2, false);
        wait_finish(0x21);
        wait_finish(0x22);
        getacc_and_expect(1, "overlap_idx1");
        getacc_and_expect(2, "overlap_idx2");

        random_pressure();

        idle(20);
        if (!expected_rows_.empty()) {
            fail("test finished with pending getacc rows");
        }
        if (!pending_finish_.empty()) {
            fail("test finished with pending GEMM finish ids");
        }

        std::cout << "sa: passed, SA_WIDTH=" << kSaWidth
                  << ", LANE_NUM=" << kLaneNum
                  << ", seed=" << seed_ << "\n";
        return 0;
    }

private:
    Vsa dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;
    std::vector<std::vector<std::vector<Pseudo>>> pacc_model_;
    std::deque<ExpectedRow> expected_rows_;
    std::multiset<uint32_t> pending_finish_;

    void clear_inputs() {
        dut_.ain_valid = 0;
        dut_.ain_laneidx = 0;
        dut_.bin_valid = 0;
        dut_.bin_laneidx = 0;
        for (int i = 0; i < kSaWidth; ++i) {
            dut_.ain_data[i] = 0;
            dut_.bin_data[i] = 0;
        }
        dut_.gemm_valid = 0;
        dut_.gemm_instid = 0;
        dut_.gemm_paccidx = 0;
        dut_.gemm_accum = 0;
        dut_.getacc_valid = 0;
        dut_.getacc_idx = 0;
    }

    void drive_idle_cycle() {
        clear_inputs();
        tick();
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 5; ++i) {
            tick();
        }
        dut_.rst_n = 1;
        idle(3);
    }

    void tick() {
        dut_.clk = 0;
        dut_.eval();

        dut_.clk = 1;
        dut_.eval();
        ++cycle_;
        check_finish();
        check_getacc();

        dut_.clk = 0;
        dut_.eval();
    }

    void idle(int cycles) {
        for (int i = 0; i < cycles; ++i) {
            drive_idle_cycle();
        }
    }

    int allocate(uint32_t instid, int paccidx, bool accum) {
        for (int attempt = 0; attempt < 200; ++attempt) {
            clear_inputs();
            dut_.gemm_valid = 1;
            dut_.gemm_instid = instid;
            dut_.gemm_paccidx = static_cast<uint32_t>(paccidx);
            dut_.gemm_accum = accum ? 1 : 0;
            dut_.eval();
            const bool ready = dut_.gemm_ready != 0;
            const int lane = static_cast<int>(dut_.gemm_alloc_lane);
            tick();
            if (ready) {
                pending_finish_.insert(instid);
                return lane;
            }
        }
        fail("timed out waiting for gemm_ready");
    }

    void write_matrices(int lane, const Matrix& m) {
        clear_inputs();
        dut_.ain_valid = 1;
        dut_.ain_laneidx = static_cast<uint32_t>(lane);
        dut_.bin_valid = 1;
        dut_.bin_laneidx = static_cast<uint32_t>(lane);

        for (int row = 0; row < kSaWidth; ++row) {
            dut_.ain_data[row] = pack_row(m.a[row]);
        }
        for (int col = 0; col < kSaWidth; ++col) {
            uint8_t transposed_col[kSaWidth] = {};
            for (int k = 0; k < kSaWidth; ++k) {
                transposed_col[k] = m.b[k][col];
            }
            dut_.bin_data[col] = pack_row(transposed_col);
        }
        tick();
    }

    void write_a_matrix(int lane, const Matrix& m) {
        clear_inputs();
        dut_.ain_valid = 1;
        dut_.ain_laneidx = static_cast<uint32_t>(lane);
        for (int row = 0; row < kSaWidth; ++row) {
            dut_.ain_data[row] = pack_row(m.a[row]);
        }
        tick();
    }

    void write_b_matrix(int lane, const Matrix& m) {
        clear_inputs();
        dut_.bin_valid = 1;
        dut_.bin_laneidx = static_cast<uint32_t>(lane);
        for (int col = 0; col < kSaWidth; ++col) {
            uint8_t transposed_col[kSaWidth] = {};
            for (int k = 0; k < kSaWidth; ++k) {
                transposed_col[k] = m.b[k][col];
            }
            dut_.bin_data[col] = pack_row(transposed_col);
        }
        tick();
    }

    int allocate_while_writing_matrices(int write_lane,
                                        const Matrix& m,
                                        uint32_t instid,
                                        int paccidx,
                                        bool accum) {
        clear_inputs();
        dut_.ain_valid = 1;
        dut_.ain_laneidx = static_cast<uint32_t>(write_lane);
        dut_.bin_valid = 1;
        dut_.bin_laneidx = static_cast<uint32_t>(write_lane);
        dut_.gemm_valid = 1;
        dut_.gemm_instid = instid;
        dut_.gemm_paccidx = static_cast<uint32_t>(paccidx);
        dut_.gemm_accum = accum ? 1 : 0;

        for (int row = 0; row < kSaWidth; ++row) {
            dut_.ain_data[row] = pack_row(m.a[row]);
        }
        for (int col = 0; col < kSaWidth; ++col) {
            uint8_t transposed_col[kSaWidth] = {};
            for (int k = 0; k < kSaWidth; ++k) {
                transposed_col[k] = m.b[k][col];
            }
            dut_.bin_data[col] = pack_row(transposed_col);
        }

        dut_.eval();
        if (!dut_.gemm_ready) {
            fail("gemm_ready deasserted during allocate_while_writing_matrices");
        }
        const int lane = static_cast<int>(dut_.gemm_alloc_lane);
        tick();
        pending_finish_.insert(instid);
        return lane;
    }

    void issue_gemm(const Matrix& m, uint32_t instid, int paccidx, bool accum) {
        const int lane = allocate(instid, paccidx, accum);
        write_matrices(lane, m);
        update_model(m, paccidx, accum);
    }

    Matrix deterministic_matrix(uint8_t base) {
        Matrix m{};
        for (int row = 0; row < kSaWidth; ++row) {
            for (int col = 0; col < kSaWidth; ++col) {
                m.a[row][col] = static_cast<uint8_t>(base + ((row + col) & 0x3));
                m.b[row][col] = static_cast<uint8_t>(0x30 + (((row * 2) + col) & 0x7));
            }
        }
        return m;
    }

    void allocator_priority_test() {
        const Matrix m0 = deterministic_matrix(0x38);
        const Matrix m1 = deterministic_matrix(0x40);
        const Matrix m2 = deterministic_matrix(0x44);

        const int lane0 = allocate(0x31, 3, false);
        if (lane0 != 0) {
            std::ostringstream os;
            os << "expected first allocator choice to be lane 0, got lane " << lane0;
            fail(os.str());
        }

        const int lane1 = allocate_while_writing_matrices(lane0, m0, 0x32, 4, false);
        if (lane1 != 1) {
            std::ostringstream os;
            os << "expected the command after lane 0 allocation to use lane 1 "
               << "while lane 0 was allocated but not active, got lane " << lane1;
            fail(os.str());
        }
        update_model(m0, 3, false);

        if (kLaneNum >= 3) {
            const int lane2 = allocate_while_writing_matrices(lane1, m1, 0x33, 5, false);
            if (lane2 != 2) {
                std::ostringstream os;
                os << "expected the third pipelined command to use lane 2 while "
                   << "lane 0 was entering active and lane 1 was allocated, got lane "
                   << lane2;
                fail(os.str());
            }
            update_model(m1, 4, false);
            write_matrices(lane2, m2);
            update_model(m2, 5, false);
            wait_finish(0x33);
            getacc_and_expect(5, "alloc_priority_idx5");
        } else {
            write_matrices(lane1, m1);
            update_model(m1, 4, false);
        }

        wait_finish(0x31);
        wait_finish(0x32);
        getacc_and_expect(3, "alloc_priority_idx3");
        getacc_and_expect(4, "alloc_priority_idx4");
    }

    void continuous_allocator_order_test() {
        if (kSaWidth != 4 || kLaneNum != 4) {
            return;
        }

        Matrix matrices[9];
        int lanes[8] = {};
        for (int i = 0; i < 9; ++i) {
            matrices[i] = deterministic_matrix(static_cast<uint8_t>(0x30 + i));
        }

        lanes[0] = allocate(0x400, 0, false);
        if (lanes[0] != 0) {
            fail("continuous allocator expected instruction 0 on lane 0");
        }

        for (int i = 1; i < 8; ++i) {
            lanes[i] = allocate_while_writing_matrices(
                lanes[i - 1],
                matrices[i - 1],
                0x400u + static_cast<uint32_t>(i),
                i % kPaccNum,
                false
            );
            update_model(matrices[i - 1], (i - 1) % kPaccNum, false);

            const int expected_lane = i % 4;
            if (lanes[i] != expected_lane) {
                std::ostringstream os;
                os << "continuous allocator instruction " << i
                   << " got lane " << lanes[i]
                   << ", expected lane " << expected_lane;
                fail(os.str());
            }
        }

        const int lane8 = allocate_while_writing_matrices(
            lanes[7],
            matrices[7],
            0x408,
            0,
            false
        );
        update_model(matrices[7], 7 % kPaccNum, false);
        if (lane8 != 0) {
            std::ostringstream os;
            os << "continuous allocator expected instruction 8 to reuse lane 0 "
               << "after lane 0's first active flip completed, got lane " << lane8;
            fail(os.str());
        }

        write_matrices(lane8, matrices[8]);
        update_model(matrices[8], 0, false);

        for (int i = 0; i < 8; ++i) {
            wait_finish(0x400u + static_cast<uint32_t>(i));
        }
        wait_finish(0x408);
        for (int idx = 0; idx < kPaccNum; ++idx) {
            getacc_and_expect(idx, "continuous_alloc_idx" + std::to_string(idx));
        }
    }

    void update_model(const Matrix& m, int paccidx, bool accum) {
        for (int row = 0; row < kSaWidth; ++row) {
            for (int col = 0; col < kSaWidth; ++col) {
                const Pseudo cell = reference_cell(m, row, col);
                pacc_model_[row][col][paccidx] =
                    add_pseudo(pacc_model_[row][col][paccidx], cell, accum);
            }
        }
    }

    Matrix random_matrix() {
        Matrix m{};
        std::uniform_int_distribution<int> zero_dist(0, 9);
        std::uniform_int_distribution<int> nan_dist(0, 79);
        for (int row = 0; row < kSaWidth; ++row) {
            for (int col = 0; col < kSaWidth; ++col) {
                m.a[row][col] = (zero_dist(rng_) == 0) ? 0 : random_finite_e4m3(rng_);
                m.b[row][col] = (zero_dist(rng_) == 0) ? 0 : random_finite_e4m3(rng_);
                if (nan_dist(rng_) == 0) {
                    m.a[row][col] = 0x7f;
                }
            }
        }
        return m;
    }

    void flush_all_finishes() {
        for (int i = 0; i < 1000; ++i) {
            if (pending_finish_.empty()) {
                return;
            }
            drive_idle_cycle();
        }
        fail("timed out waiting for all GEMM finishes");
    }

    void random_pressure() {
        std::uniform_int_distribution<int> pacc_dist(0, kPaccNum - 1);
        std::uniform_int_distribution<int> gap_dist(0, 3);
        std::uniform_int_distribution<int> order_dist(0, 2);
        std::bernoulli_distribution accum_dist(0.55);

        const int target_gemms = (kSaWidth >= 4 || kLaneNum >= 4) ? 48 : 24;
        const int check_period = (kSaWidth >= 4 || kLaneNum >= 4) ? 12 : 8;

        for (int i = 0; i < target_gemms; ++i) {
            const Matrix m = random_matrix();
            const int paccidx = pacc_dist(rng_);
            const bool accum = accum_dist(rng_);
            const uint32_t instid = 0x100u + static_cast<uint32_t>(i);
            const int lane = allocate(instid, paccidx, accum);

            for (int gap = 0; gap < gap_dist(rng_); ++gap) {
                drive_idle_cycle();
            }

            const int order = order_dist(rng_);
            if (order == 0) {
                write_matrices(lane, m);
            } else if (order == 1) {
                write_a_matrix(lane, m);
                for (int gap = 0; gap < gap_dist(rng_); ++gap) {
                    drive_idle_cycle();
                }
                write_b_matrix(lane, m);
            } else {
                write_b_matrix(lane, m);
                for (int gap = 0; gap < gap_dist(rng_); ++gap) {
                    drive_idle_cycle();
                }
                write_a_matrix(lane, m);
            }

            update_model(m, paccidx, accum);

            if ((i % check_period) == (check_period - 1)) {
                flush_all_finishes();
                getacc_and_expect(paccidx, "random_mid_idx" + std::to_string(paccidx));
            }
        }

        flush_all_finishes();
        for (int idx = 0; idx < kPaccNum; ++idx) {
            getacc_and_expect(idx, "random_final_idx" + std::to_string(idx));
        }
    }

    void wait_finish(uint32_t instid) {
        for (int i = 0; i < 400; ++i) {
            if (pending_finish_.find(instid) == pending_finish_.end()) {
                return;
            }
            idle(1);
        }
        std::ostringstream os;
        os << "timed out waiting for finish id 0x" << std::hex << instid;
        fail(os.str());
    }

    void getacc_and_expect(int paccidx, const std::string& name) {
        for (int row = 0; row < kSaWidth; ++row) {
            ExpectedRow exp;
            exp.row = row;
            exp.name = name;
            for (int col = 0; col < kSaWidth; ++col) {
                exp.data[col] = pseudo_to_fp32_bits(pacc_model_[row][col][paccidx]);
            }
            expected_rows_.push_back(exp);
        }

        for (int attempt = 0; attempt < 100; ++attempt) {
            clear_inputs();
            dut_.getacc_valid = 1;
            dut_.getacc_idx = static_cast<uint32_t>(paccidx);
            dut_.eval();
            const bool ready = dut_.getacc_ready != 0;
            tick();
            if (ready) {
                clear_inputs();
                return;
            }
        }
        fail("timed out waiting for getacc_ready");
    }

    void check_finish() {
        if (!dut_.gemm_finish) {
            return;
        }
        const uint32_t id = static_cast<uint32_t>(dut_.gemm_finish_instid);
        const auto it = pending_finish_.find(id);
        if (it == pending_finish_.end()) {
            std::ostringstream os;
            os << "unexpected gemm_finish id 0x" << std::hex << id;
            fail(os.str());
        }
        pending_finish_.erase(it);
    }

    void check_getacc() {
        if (!dut_.getacc_data_valid) {
            return;
        }
        if (expected_rows_.empty()) {
            fail("unexpected getacc_data_valid");
        }
        const ExpectedRow exp = expected_rows_.front();
        expected_rows_.pop_front();

        for (int col = 0; col < kSaWidth; ++col) {
            const uint32_t got = getacc_word(col);
            if (got != exp.data[col]) {
                std::ostringstream os;
                os << "wrong getacc row " << exp.row << ", col " << col
                   << " for " << exp.name
                   << ": got " << hex32(got)
                   << ", expected " << hex32(exp.data[col]);
                fail(os.str());
            }
        }
    }

    uint32_t getacc_word(int col) const {
#if SA_WIDTH_TEST <= 2
        const uint64_t packed = static_cast<uint64_t>(dut_.getacc_data);
        return static_cast<uint32_t>((packed >> (32 * col)) & 0xffff'ffffull);
#else
        return static_cast<uint32_t>(dut_.getacc_data[col]);
#endif
    }

    [[noreturn]] void fail(const std::string& message) {
        std::cerr << "FAIL at cycle " << cycle_ << ": " << message << "\n";
        std::exit(1);
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    SaTest test(parse_seed(argc, argv));
    return test.run();
}
