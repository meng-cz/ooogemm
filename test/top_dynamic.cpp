#include "Vtop_dynamic.h"
#include "verilated.h"

#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <array>
#include <deque>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 2
#endif
#ifndef SUBTILE_M_TEST
#define SUBTILE_M_TEST SA_WIDTH_TEST
#endif
#ifndef SUBTILE_N_TEST
#define SUBTILE_N_TEST SA_WIDTH_TEST
#endif
#ifndef SUBTILE_K_TEST
#define SUBTILE_K_TEST 2
#endif
#ifndef LANE_NUM_TEST
#define LANE_NUM_TEST 2
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
#ifndef PACC_EXP_WIDTH_TEST
#define PACC_EXP_WIDTH_TEST 10
#endif
#ifndef PACC_SIG_WIDTH_TEST
#define PACC_SIG_WIDTH_TEST 40
#endif
#ifndef STORE_ROWS_PER_CYCLE_TEST
#define STORE_ROWS_PER_CYCLE_TEST 1
#endif
#ifndef TOP_STATIC_BIG_TEST
#define TOP_STATIC_BIG_TEST 0
#endif
#ifndef LOAD_DATA_WIDTH_TEST
#define LOAD_DATA_WIDTH_TEST (SUBTILE_K_TEST * 8)
#endif

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kSubtileM = SUBTILE_M_TEST;
constexpr int kSubtileN = SUBTILE_N_TEST;
constexpr int kMaxSubtileRows = (kSubtileM > kSubtileN) ? kSubtileM : kSubtileN;
constexpr int kSubtileK = SUBTILE_K_TEST;
constexpr int kLaneNum = LANE_NUM_TEST;
constexpr int kABufSize = ABUF_SIZE_TEST;
constexpr int kBBufSize = BBUF_SIZE_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;
constexpr int kPaccExpWidth = PACC_EXP_WIDTH_TEST;
constexpr int kPaccSigWidth = PACC_SIG_WIDTH_TEST;
constexpr int kStoreRowsPerCycle = STORE_ROWS_PER_CYCLE_TEST;
constexpr int kStoreGroupsPerTile = kSubtileM / kStoreRowsPerCycle;
constexpr int kStoreDataWords =
    (kSubtileN * kStoreRowsPerCycle * 32 + 31) / 32;
constexpr int64_t kPseudoNanExp = (int64_t{1} << (kPaccExpWidth - 1)) - 1;
constexpr int kLoadRowBits = kSubtileK * 8;
constexpr int kLoadRowWords = (kLoadRowBits + 31) / 32;
constexpr int kLoadDataBits = LOAD_DATA_WIDTH_TEST;
constexpr int kLoadBeatWords = (kLoadDataBits + 31) / 32;
constexpr bool kLoadWide = kLoadDataBits >= kLoadRowBits;
constexpr int kRowsPerLoadBeat = kLoadWide ? (kLoadDataBits / kLoadRowBits) : 1;
constexpr int kLoadBeatsPerRow = kLoadWide ? 1 : (kLoadRowBits / kLoadDataBits);
constexpr int kLoadTileBeats = kLoadWide ?
    ((kMaxSubtileRows + kRowsPerLoadBeat - 1) / kRowsPerLoadBeat) :
    (kMaxSubtileRows * kLoadBeatsPerRow);
constexpr bool kBigTest = TOP_STATIC_BIG_TEST != 0;

constexpr int choose_parser_block_m(int abuf_group_size, int bbuf_group_size, int pacc_num) {
    int best_m = 1;
    int best_n = 1;
    int best_area = 1;
    int best_balance = 0;
    for (int bm = 1; bm <= abuf_group_size; ++bm) {
        for (int bn = 1; bn <= bbuf_group_size; ++bn) {
            const int area = bm * bn;
            const int balance = (bm >= bn) ? (bm - bn) : (bn - bm);
            if ((area <= pacc_num) &&
                ((area > best_area) ||
                 ((area == best_area) && (balance < best_balance)) ||
                 ((area == best_area) && (balance == best_balance) && (bm > best_m)) ||
                 ((area == best_area) && (balance == best_balance) && (bm == best_m) &&
                  (bn > best_n)))) {
                best_m = bm;
                best_n = bn;
                best_area = area;
                best_balance = balance;
            }
        }
    }
    return best_m;
}

constexpr int choose_parser_block_n(int abuf_group_size, int bbuf_group_size, int pacc_num) {
    int best_m = 1;
    int best_n = 1;
    int best_area = 1;
    int best_balance = 0;
    for (int bm = 1; bm <= abuf_group_size; ++bm) {
        for (int bn = 1; bn <= bbuf_group_size; ++bn) {
            const int area = bm * bn;
            const int balance = (bm >= bn) ? (bm - bn) : (bn - bm);
            if ((area <= pacc_num) &&
                ((area > best_area) ||
                 ((area == best_area) && (balance < best_balance)) ||
                 ((area == best_area) && (balance == best_balance) && (bm > best_m)) ||
                 ((area == best_area) && (balance == best_balance) && (bm == best_m) &&
                  (bn > best_n)))) {
                best_m = bm;
                best_n = bn;
                best_area = area;
                best_balance = balance;
            }
        }
    }
    return best_n;
}

constexpr int kParserBlockM =
    choose_parser_block_m(kABufSize / 2, kBBufSize / 2, kPaccNum);
constexpr int kParserBlockN =
    choose_parser_block_n(kABufSize / 2, kBBufSize / 2, kPaccNum);
constexpr int kParserBlockArea = kParserBlockM * kParserBlockN;
constexpr int kParserMergeBlockTiles = std::min(
    kParserBlockArea,
    std::min(kPaccNum, std::min(kABufSize / 2, kBBufSize / 2))
);

static_assert(kLaneNum >= 1, "top_dynamic testbench expects at least one lane");
static_assert(kABufSize >= 4 && kBBufSize >= 4, "operand buffers must have ping-pong halves");
static_assert(kPaccNum >= 4, "top_dynamic testbench expects at least four PACC registers");
static_assert(kStoreRowsPerCycle >= 1 &&
              (kSubtileM % kStoreRowsPerCycle) == 0,
              "SUBTILE_M_TEST must be divisible by STORE_ROWS_PER_CYCLE_TEST");
static_assert(kLoadRowWords >= 1, "load row must have at least one word");
static_assert((kSubtileK & (kSubtileK - 1)) == 0,
              "SUBTILE_K_TEST must be a power of two");
static_assert((kLoadDataBits & (kLoadDataBits - 1)) == 0,
              "LOAD_DATA_WIDTH_TEST must be a power of two");
static_assert((kLoadDataBits % 8) == 0, "LOAD_DATA_WIDTH_TEST must be byte-aligned");
static_assert((kLoadDataBits >= kLoadRowBits && (kLoadDataBits % kLoadRowBits) == 0) ||
              (kLoadRowBits >= kLoadDataBits && (kLoadRowBits % kLoadDataBits) == 0),
              "load bus and operand row widths must divide each other");

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

struct Cmd {
    uint32_t a_base = 0;
    uint32_t b_base = 0;
    uint32_t c_base = 0;
    int m = 0;
    int n = 0;
    int k = 0;
    int batch = 1;
    std::vector<uint8_t> a;
    std::vector<uint8_t> b;
    std::string name;
};

struct RowData {
    std::array<uint32_t, kLoadRowWords> words{};
};

struct LoadBeatData {
    std::array<uint32_t, kLoadBeatWords> words{};
};

struct StoreBeatData {
    std::array<uint32_t, kStoreDataWords> words{};

    bool operator==(const StoreBeatData& rhs) const {
        return words == rhs.words;
    }
    bool operator!=(const StoreBeatData& rhs) const {
        return !(*this == rhs);
    }
};

struct Rsp {
    uint64_t due = 0;
    uint32_t id = 0;
    LoadBeatData data;
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

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

uint8_t get_elem(const std::vector<uint8_t>& matrix, int rows, int cols, int row, int col) {
    if (row < 0 || row >= rows || col < 0 || col >= cols) {
        return 0;
    }
    return matrix[static_cast<size_t>(row * cols + col)];
}

RowData pack_row(const uint8_t row[kSubtileK]) {
    RowData data;
    for (int i = 0; i < kSubtileK; ++i) {
        const int word = i / 4;
        const int byte = i % 4;
        data.words[static_cast<size_t>(word)] |=
            static_cast<uint32_t>(row[i]) << (8 * byte);
    }
    return data;
}

uint32_t get_row_bit(const RowData& data, int bit) {
    return (data.words[static_cast<size_t>(bit / 32)] >> (bit % 32)) & 1u;
}

void set_load_beat_bit(LoadBeatData& data, int bit, uint32_t value) {
    if (value != 0) {
        data.words[static_cast<size_t>(bit / 32)] |= uint32_t{1} << (bit % 32);
    }
}

void copy_row_bits_to_beat(const RowData& src,
                           int src_bit,
                           LoadBeatData& dst,
                           int dst_bit,
                           int width) {
    for (int bit = 0; bit < width; ++bit) {
        set_load_beat_bit(dst, dst_bit + bit, get_row_bit(src, src_bit + bit));
    }
}

int ceil_tiles(int dim) {
    return (dim + kSubtileM - 1) / kSubtileM;
}

int ceil_n_tiles(int dim) {
    return (dim + kSubtileN - 1) / kSubtileN;
}

int ceil_k_tiles(int dim) {
    return (dim + kSubtileK - 1) / kSubtileK;
}

Pseudo reference_tile_cell(const Cmd& cmd, int tile_m, int tile_n, int tile_k,
                           int local_m, int local_n) {
    bool saw_nan = false;
    long double sum = 0.0L;
    for (int kk = 0; kk < kSubtileK; ++kk) {
        const int global_m = tile_m * kSubtileM + local_m;
        const int global_n = tile_n * kSubtileN + local_n;
        const int global_k = tile_k * kSubtileK + kk;
        const uint8_t a = get_elem(cmd.a, cmd.m, cmd.k, global_m, global_k);
        const uint8_t b = get_elem(cmd.b, cmd.k, cmd.n, global_k, global_n);
        sum += fp8_product(a, b, saw_nan);
    }
    return pseudo_from_long_double(sum, saw_nan);
}

class TopStaticTest {
public:
    explicit TopStaticTest(uint32_t seed) : seed_(seed), rng_(seed) {
        dut_.clk = 0;
        dut_.rst_n = 0;
        clear_inputs();
        dut_.eval();
    }

    int run() {
        std::fesetround(FE_TONEAREST);
        reset();
        build_commands();
        run_until_done();
        std::cout << "top_dynamic: passed, commands=" << commands_.size()
                  << " writes=" << seen_writes_.size()
                  << " seed=" << hex32(seed_) << "\n";
        return 0;
    }

private:
    Vtop_dynamic dut_;
    uint64_t cycle_ = 0;
    uint32_t seed_;
    std::mt19937 rng_;
    std::vector<Cmd> commands_;
    std::unordered_map<uint32_t, LoadBeatData> load_beats_;
    std::unordered_map<uint32_t, StoreBeatData> expected_writes_;
    std::unordered_set<uint32_t> seen_writes_;
    std::deque<Rsp> pending_rsp_;
    size_t cmd_index_ = 0;
    uint64_t expected_load_req_count_ = 0;
    uint64_t load_req_count_ = 0;
    uint64_t load_rsp_count_ = 0;
    uint64_t store_valid_count_ = 0;
    uint64_t store_fire_count_ = 0;
    uint64_t cmd_ready_count_ = 0;

    bool wr_hold_active_ = false;
    uint32_t wr_hold_addr_ = 0;
    StoreBeatData wr_hold_data_;

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

    StoreBeatData read_store_data() const {
        StoreBeatData data;
#if (SUBTILE_N_TEST * STORE_ROWS_PER_CYCLE_TEST * 32) <= 32
        data.words[0] = dut_.store_mem_wr_data_o;
#elif (SUBTILE_N_TEST * STORE_ROWS_PER_CYCLE_TEST * 32) <= 64
        data.words[0] = static_cast<uint32_t>(dut_.store_mem_wr_data_o);
        data.words[1] = static_cast<uint32_t>(dut_.store_mem_wr_data_o >> 32);
#else
        for (int i = 0; i < kStoreDataWords; ++i) {
            data.words[static_cast<size_t>(i)] = dut_.store_mem_wr_data_o[i];
        }
#endif
        return data;
    }

    void reset() {
        dut_.rst_n = 0;
        for (int i = 0; i < 6; ++i) {
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

    void build_commands() {
        if (kBigTest) {
            build_big_commands();
        } else {
            build_small_commands();
        }

        for (const Cmd& cmd : commands_) {
            add_load_rows(cmd);
            expected_load_req_count_ += expected_load_requests(cmd);
            add_expected_writes(cmd);
        }
    }

    void build_small_commands() {
        commands_.push_back(make_cmd(
            "cmd0_4x4x4",
            0x0100, 0x0200, 0x0300,
            4, 4, 4,
            {
                0x38, 0x40, 0x30, 0xb8,
                0x30, 0x38, 0x40, 0x28,
                0x40, 0xb8, 0x38, 0x30,
                0x28, 0x40, 0x30, 0x38,
            },
            {
                0x38, 0x30, 0x40, 0x28,
                0x40, 0x38, 0xb8, 0x30,
                0x30, 0x40, 0x38, 0xb8,
                0xb8, 0x28, 0x30, 0x40,
            }
        ));

        commands_.push_back(make_cmd(
            "cmd1_2x2x2",
            0x0400, 0x0500, 0x0600,
            2, 2, 2,
            {
                0x38, 0x40,
                0xb8, 0x30,
            },
            {
                0x40, 0x38,
                0x30, 0xb8,
            }
        ));
    }

    uint8_t pattern_value(int row, int col, uint32_t salt) const {
        static constexpr uint8_t kValues[] = {
            0x00,  // +0
            0x38,  // +1
            0xb8,  // -1
            0x30,  // +0.5
            0xb0,  // -0.5
            0x40,  // +2
            0xc0,  // -2
            0x28,  // +0.25
            0xa8,  // -0.25
        };
        uint32_t x = salt;
        x ^= static_cast<uint32_t>(row + 0x9e37) * 0x85ebca6bu;
        x ^= static_cast<uint32_t>(col + 0x7f4a) * 0xc2b2ae35u;
        x ^= x >> 16;
        return kValues[x % (sizeof(kValues) / sizeof(kValues[0]))];
    }

    Cmd make_pattern_cmd(const std::string& name,
                         uint32_t a_base, uint32_t b_base, uint32_t c_base,
                         int m, int n, int k,
                         uint32_t salt) {
        std::vector<uint8_t> a(static_cast<size_t>(m * k));
        std::vector<uint8_t> b(static_cast<size_t>(k * n));
        for (int row = 0; row < m; ++row) {
            for (int col = 0; col < k; ++col) {
                a[static_cast<size_t>(row * k + col)] =
                    pattern_value(row, col, salt ^ 0xa341316cu);
            }
        }
        for (int row = 0; row < k; ++row) {
            for (int col = 0; col < n; ++col) {
                b[static_cast<size_t>(row * n + col)] =
                    pattern_value(row, col, salt ^ 0xc8013ea4u);
            }
        }
        return make_cmd(name, a_base, b_base, c_base, m, n, k,
                        std::move(a), std::move(b));
    }

    uint32_t command_base(size_t idx, uint32_t region) const {
        return 0x1000u + static_cast<uint32_t>(idx) * 0x1000u + region;
    }

    void push_pattern_cmd(const std::string& name, int m, int n, int k, uint32_t salt) {
        if (kBigTest && (m > 0) && (n > 0) && (k > 0)) {
            const int tm = ceil_tiles(m);
            const int tn = ceil_n_tiles(n);
            const int mb = (tm + kParserBlockM - 1) / kParserBlockM;
            const int nb = (tn + kParserBlockN - 1) / kParserBlockN;
            if ((name.find("multi_block") != std::string::npos) && (mb * nb < 4)) {
                fail(name + ": expected enough M/N output blocks");
            }
        }

        const size_t idx = commands_.size();
        commands_.push_back(make_pattern_cmd(
            name,
            command_base(idx, 0x000u),
            command_base(idx, 0x400u),
            command_base(idx, 0x800u),
            m, n, k,
            salt
        ));
    }

    void build_big_commands() {
        push_pattern_cmd("det_zero_m", 0, 17, 9, 0x1001u);
        push_pattern_cmd("det_tiny_1x1x1", 1, 1, 1, 0x1002u);
        push_pattern_cmd("det_subtile_31x17x5", 31, 17, 5, 0x1003u);
        push_pattern_cmd("det_exact_32x32x32", 32, 32, kSubtileK, 0x1004u);
        push_pattern_cmd("det_cross_33x33x33", 33, 33, kSubtileK + 1, 0x1005u);
        push_pattern_cmd("det_rect_65x7x64", 65, 7, 2 * kSubtileK, 0x1006u);
        const int multi_square_dim =
            std::max(161, kSubtileM * kParserBlockM + 1);
        const int multi_rect_m =
            std::max(257, kSubtileM * (kParserBlockM + 1) + 1);
        const int multi_rect_n =
            std::max(193, kSubtileN * kParserBlockN + 1);
        push_pattern_cmd("det_multi_block_square", multi_square_dim, multi_square_dim,
                         3 * kSubtileK + 1, 0x1007u);
        push_pattern_cmd("det_multi_block_rect", multi_rect_m, multi_rect_n,
                         4 * kSubtileK + 1, 0x1008u);

        const int dim_choices[] = {
            1, 2, 7, 15, 31, 32, 33, 47, 63, 64, 65,
            96, 127, 128, 129, 160, 161, 193, 257
        };
        std::uniform_int_distribution<int> dim_dist(
            0, static_cast<int>((sizeof(dim_choices) / sizeof(dim_choices[0])) - 1)
        );
        for (int i = 0; i < 8; ++i) {
            const int m = dim_choices[dim_dist(rng_)];
            const int n = dim_choices[dim_dist(rng_)];
            const int k = dim_choices[dim_dist(rng_)];
            std::ostringstream name;
            name << "rand_" << i << "_" << m << "x" << n << "x" << k;
            push_pattern_cmd(name.str(), m, n, k, seed_ ^ (0x2000u + static_cast<uint32_t>(i)));
        }
    }

    Cmd make_cmd(const std::string& name,
                 uint32_t a_base, uint32_t b_base, uint32_t c_base,
                 int m, int n, int k,
                 std::vector<uint8_t> a,
                 std::vector<uint8_t> b) {
        if (static_cast<int>(a.size()) != m * k) {
            fail(name + ": A matrix size mismatch");
        }
        if (static_cast<int>(b.size()) != k * n) {
            fail(name + ": B matrix size mismatch");
        }
        Cmd cmd;
        cmd.a_base = a_base;
        cmd.b_base = b_base;
        cmd.c_base = c_base;
        cmd.m = m;
        cmd.n = n;
        cmd.k = k;
        cmd.a = std::move(a);
        cmd.b = std::move(b);
        cmd.name = name;
        return cmd;
    }

    void add_load_rows(const Cmd& cmd) {
        const int tm = ceil_tiles(cmd.m);
        const int tn = ceil_n_tiles(cmd.n);
        const int tk = ceil_k_tiles(cmd.k);

        for (int tile_m = 0; tile_m < tm; ++tile_m) {
            for (int tile_k = 0; tile_k < tk; ++tile_k) {
                const uint32_t tile_addr =
                    cmd.a_base + static_cast<uint32_t>(tile_m * tk + tile_k);
                std::array<RowData, kMaxSubtileRows> rows{};
                for (int row = 0; row < kSubtileM; ++row) {
                    uint8_t packed_row[kSubtileK] = {};
                    for (int kk = 0; kk < kSubtileK; ++kk) {
                        packed_row[kk] = get_elem(
                            cmd.a, cmd.m, cmd.k,
                            tile_m * kSubtileM + row,
                            tile_k * kSubtileK + kk
                        );
                    }
                    rows[static_cast<size_t>(row)] = pack_row(packed_row);
                }
                add_tile_load_beats(tile_addr, rows,
                                    valid_tile_rows(cmd.m, tile_m, kSubtileM));
            }
        }

        for (int tile_k = 0; tile_k < tk; ++tile_k) {
            for (int tile_n = 0; tile_n < tn; ++tile_n) {
                const uint32_t tile_addr =
                    cmd.b_base + static_cast<uint32_t>(tile_k * tn + tile_n);
                std::array<RowData, kMaxSubtileRows> rows{};
                for (int col = 0; col < kSubtileN; ++col) {
                    uint8_t packed_col[kSubtileK] = {};
                    for (int kk = 0; kk < kSubtileK; ++kk) {
                        packed_col[kk] = get_elem(
                            cmd.b, cmd.k, cmd.n,
                            tile_k * kSubtileK + kk,
                            tile_n * kSubtileN + col
                        );
                    }
                    // The test builds the external-memory image for B as the
                    // software-provided transposed view. Hardware loads this
                    // row directly into BBuf bank col without another reorder.
                    rows[static_cast<size_t>(col)] = pack_row(packed_col);
                }
                add_tile_load_beats(tile_addr, rows,
                                    valid_tile_rows(cmd.n, tile_n, kSubtileN));
            }
        }
    }

    void add_tile_load_beats(uint32_t tile_addr,
                             const std::array<RowData, kMaxSubtileRows>& rows,
                             int valid_rows) {
        const int req_count = load_req_count_for_rows(valid_rows);
        for (int req = 0; req < req_count; ++req) {
            LoadBeatData beat;
            if (kLoadWide) {
                const int row_start = req * kRowsPerLoadBeat;
                const int rows_this_beat =
                    std::min(kRowsPerLoadBeat, valid_rows - row_start);
                for (int off = 0; off < rows_this_beat; ++off) {
                    copy_row_bits_to_beat(
                        rows[static_cast<size_t>(row_start + off)],
                        0,
                        beat,
                        off * kLoadRowBits,
                        kLoadRowBits
                    );
                }
            } else {
                const int row = req / kLoadBeatsPerRow;
                const int beat_idx = req % kLoadBeatsPerRow;
                copy_row_bits_to_beat(
                    rows[static_cast<size_t>(row)],
                    beat_idx * kLoadDataBits,
                    beat,
                    0,
                    kLoadDataBits
                );
            }
            load_beats_[tile_addr * static_cast<uint32_t>(kLoadTileBeats) +
                        static_cast<uint32_t>(req)] = beat;
        }
    }

    int valid_tile_rows(int dim, int tile_idx, int tile_size) const {
        const int start = tile_idx * tile_size;
        if (dim <= start) {
            return 0;
        }
        return std::min(tile_size, dim - start);
    }

    uint64_t expected_load_requests(const Cmd& cmd) const {
        const int tm = ceil_tiles(cmd.m);
        const int tn = ceil_n_tiles(cmd.n);
        const int tk = ceil_k_tiles(cmd.k);
        const int batch = cmd.batch == 0 ? 0 : cmd.batch;
        uint64_t count = 0;

        if (batch == 0 || tm == 0 || tn == 0 || tk == 0) {
            return 0;
        }

        const int output_tiles_per_batch = tm * tn;
        if (output_tiles_per_batch < kParserBlockArea) {
            const int total_output_tiles = batch * output_tiles_per_batch;
            for (int base = 0; base < total_output_tiles; base += kParserMergeBlockTiles) {
                const int block_tiles =
                    std::min(kParserMergeBlockTiles, total_output_tiles - base);
                for (int kt = 0; kt < tk; ++kt) {
                    (void)kt;
                    for (int local = 0; local < block_tiles; ++local) {
                        const int flat = base + local;
                        const int in_batch = flat % output_tiles_per_batch;
                        const int tile_m = in_batch / tn;
                        const int tile_n = in_batch % tn;
                        count += static_cast<uint64_t>(
                            load_req_count_for_rows(valid_tile_rows(cmd.m, tile_m, kSubtileM))
                        );
                        count += static_cast<uint64_t>(
                            load_req_count_for_rows(valid_tile_rows(cmd.n, tile_n, kSubtileN))
                        );
                    }
                }
            }
            return count;
        }

        for (int b = 0; b < batch; ++b) {
            (void)b;
            for (int block_m_base = 0; block_m_base < tm; block_m_base += kParserBlockM) {
                const int block_m = std::min(kParserBlockM, tm - block_m_base);
                for (int block_n_base = 0; block_n_base < tn; block_n_base += kParserBlockN) {
                    const int block_n = std::min(kParserBlockN, tn - block_n_base);
                    for (int kt = 0; kt < tk; ++kt) {
                        (void)kt;
                        for (int local_m = 0; local_m < block_m; ++local_m) {
                            count += static_cast<uint64_t>(
                                load_req_count_for_rows(
                                    valid_tile_rows(cmd.m, block_m_base + local_m, kSubtileM)
                                )
                            );
                        }
                        for (int local_n = 0; local_n < block_n; ++local_n) {
                            count += static_cast<uint64_t>(
                                load_req_count_for_rows(
                                    valid_tile_rows(cmd.n, block_n_base + local_n, kSubtileN)
                                )
                            );
                        }
                    }
                }
            }
        }
        return count;
    }

    int load_req_count_for_rows(int valid_rows) const {
        if (kLoadWide) {
            return (valid_rows + kRowsPerLoadBeat - 1) / kRowsPerLoadBeat;
        }
        return valid_rows * kLoadBeatsPerRow;
    }

    void add_expected_writes(const Cmd& cmd) {
        const int tm = ceil_tiles(cmd.m);
        const int tn = ceil_n_tiles(cmd.n);
        const int tk = ceil_k_tiles(cmd.k);

        for (int tile_m = 0; tile_m < tm; ++tile_m) {
            for (int tile_n = 0; tile_n < tn; ++tile_n) {
                Pseudo pacc[kSubtileM][kSubtileN] = {};
                for (int tile_k = 0; tile_k < tk; ++tile_k) {
                    for (int row = 0; row < kSubtileM; ++row) {
                        for (int col = 0; col < kSubtileN; ++col) {
                            const Pseudo partial =
                                reference_tile_cell(cmd, tile_m, tile_n, tile_k, row, col);
                            pacc[row][col] = add_pseudo(pacc[row][col], partial, tile_k != 0);
                        }
                    }
                }

                const uint32_t tile_addr =
                    cmd.c_base + static_cast<uint32_t>(tile_m * tn + tile_n);
                for (int group = 0; group < kStoreGroupsPerTile; ++group) {
                    StoreBeatData beat;
                    for (int slot = 0; slot < kStoreRowsPerCycle; ++slot) {
                        const int row = group * kStoreRowsPerCycle + slot;
                        for (int col = 0; col < kSubtileN; ++col) {
                            beat.words[static_cast<size_t>(slot * kSubtileN + col)] =
                                pseudo_to_fp32_bits(pacc[row][col]);
                        }
                    }
                    const uint32_t wr_addr =
                        tile_addr * static_cast<uint32_t>(kStoreGroupsPerTile) +
                        static_cast<uint32_t>(group);
                    expected_writes_[wr_addr] = beat;
                }
            }
        }
    }

    void run_until_done() {
        const int max_cycles = kBigTest ? 2000000 : 30000;
        for (int i = 0; i < max_cycles; ++i) {
            drive_cycle();
            if (cmd_index_ == commands_.size() &&
                pending_rsp_.empty() &&
                seen_writes_.size() == expected_writes_.size()) {
                if (load_req_count_ != expected_load_req_count_) {
                    std::ostringstream os;
                    os << "load request count mismatch: got=" << load_req_count_
                       << " expected=" << expected_load_req_count_;
                    fail(os.str());
                }
                for (int drain = 0; drain < 10; ++drain) {
                    drive_cycle();
                    if (dut_.store_mem_wr_valid_o) {
                        fail("unexpected store write after all expected writes completed");
                    }
                }
                return;
            }
        }

        std::ostringstream os;
        os << "timeout: accepted_cmds=" << cmd_index_ << "/" << commands_.size()
           << " seen_writes=" << seen_writes_.size() << "/" << expected_writes_.size()
           << " pending_rsp=" << pending_rsp_.size()
           << " load_req=" << load_req_count_
           << " load_rsp=" << load_rsp_count_
           << " store_valid=" << store_valid_count_
           << " store_fire=" << store_fire_count_
           << " cmd_ready_cycles=" << cmd_ready_count_;
        fail(os.str());
    }

    void drive_cycle() {
        std::bernoulli_distribution req_ready_dist(0.80);
        std::bernoulli_distribution wr_ready_dist(0.65);
        std::uniform_int_distribution<int> rsp_delay_dist(3, 8);

        clear_inputs();

        if (cmd_index_ < commands_.size()) {
            const Cmd& cmd = commands_[cmd_index_];
            dut_.cmd_valid_i = 1;
            dut_.cmd_a_base_i = cmd.a_base;
            dut_.cmd_b_base_i = cmd.b_base;
            dut_.cmd_c_base_i = cmd.c_base;
            dut_.cmd_m_i = static_cast<uint32_t>(cmd.m);
            dut_.cmd_n_i = static_cast<uint32_t>(cmd.n);
            dut_.cmd_k_i = static_cast<uint32_t>(cmd.k);
            dut_.cmd_batch_i = static_cast<uint32_t>(cmd.batch);
        }

        dut_.load_mem_req_ready_i = req_ready_dist(rng_) ? 1 : 0;
        dut_.store_mem_wr_ready_i = wr_ready_dist(rng_) ? 1 : 0;

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
        if (dut_.cmd_ready_o) {
            ++cmd_ready_count_;
        }
        if (dut_.store_mem_wr_valid_o) {
            ++store_valid_count_;
        }

        if (dut_.store_mem_wr_valid_o) {
            check_store_write(wr_fire);
        } else if (wr_hold_active_) {
            fail("store write valid dropped while stalled");
        }

        if (rsp_fire && rsp_index < 0) {
            fail("response fired without a selected pending response");
        }

        dut_.clk = 1;
        dut_.eval();

        if (cmd_fire) {
            ++cmd_index_;
        }
        if (req_fire) {
            ++load_req_count_;
            const uint32_t addr = req_addr_fire;
            auto it = load_beats_.find(addr);
            if (it == load_beats_.end()) {
                std::ostringstream os;
                os << "load request for unknown beat address " << hex32(addr)
                   << " at cycle " << cycle_;
                fail(os.str());
            }
            Rsp new_rsp;
            new_rsp.due = cycle_ + static_cast<uint64_t>(rsp_delay_dist(rng_));
            new_rsp.id = req_id_fire;
            new_rsp.data = it->second;
            pending_rsp_.push_back(new_rsp);
        }
        if (rsp_fire) {
            ++load_rsp_count_;
            pending_rsp_.erase(pending_rsp_.begin() + rsp_index);
        }
        if (wr_fire) {
            ++store_fire_count_;
            seen_writes_.insert(wr_addr_fire);
            wr_hold_active_ = false;
        }

        dut_.clk = 0;
        dut_.eval();
        ++cycle_;
    }

    void check_store_write(bool fire) {
        const uint32_t addr = static_cast<uint32_t>(dut_.store_mem_wr_addr_o);
        const StoreBeatData data = read_store_data();

        auto it = expected_writes_.find(addr);
        if (it == expected_writes_.end()) {
            std::ostringstream os;
            os << "unexpected store write addr=" << hex32(addr)
               << " data[0]=" << hex32(data.words[0])
               << " at cycle " << cycle_;
            fail(os.str());
        }
        if (it->second != data) {
            std::ostringstream os;
            os << "store data mismatch at addr=" << hex32(addr)
               << " got[0]=" << hex32(data.words[0])
               << " expected[0]=" << hex32(it->second.words[0])
               << " at cycle " << cycle_;
            fail(os.str());
        }
        if (seen_writes_.count(addr) != 0 && fire) {
            std::ostringstream os;
            os << "duplicate store write addr=" << hex32(addr)
               << " at cycle " << cycle_;
            fail(os.str());
        }

        if (!fire) {
            if (!wr_hold_active_) {
                wr_hold_active_ = true;
                wr_hold_addr_ = addr;
                wr_hold_data_ = data;
            } else if (wr_hold_addr_ != addr || wr_hold_data_ != data) {
                fail("store write addr/data changed while stalled");
            }
        }
    }
};

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x7057a71cu;
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
    try {
        const uint32_t seed = parse_seed(argc, argv);
        TopStaticTest test(seed);
        return test.run();
    } catch (const std::exception& e) {
        std::cerr << "top_dynamic test failed: " << e.what() << "\n";
        return 1;
    }
}
