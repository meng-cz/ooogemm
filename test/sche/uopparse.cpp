#include "Vuopparse.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 2
#endif
#ifndef ABUF_SIZE_TEST
#define ABUF_SIZE_TEST 2
#endif
#ifndef BBUF_SIZE_TEST
#define BBUF_SIZE_TEST 2
#endif
#ifndef PACC_NUM_TEST
#define PACC_NUM_TEST 4
#endif

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kABufSize = ABUF_SIZE_TEST;
constexpr int kBBufSize = BBUF_SIZE_TEST;
constexpr int kPaccNum = PACC_NUM_TEST;

enum UopType : uint8_t {
    UOP_LOAD_A = 0,
    UOP_LOAD_B = 1,
    UOP_GEMM = 2,
    UOP_OUTPUT = 3,
};

struct Cmd {
    uint32_t a_base = 0;
    uint32_t b_base = 0;
    uint32_t c_base = 0;
    uint32_t m = 0;
    uint32_t n = 0;
    uint32_t k = 0;
    std::string name;
};

struct Uop {
    uint8_t type = 0;
    uint32_t addr = 0;
    uint32_t abuf = 0;
    uint32_t bbuf = 0;
    uint32_t pacc = 0;
    bool accum = false;
    std::string tag;
};

std::string type_name(uint8_t type) {
    switch (type) {
        case UOP_LOAD_A: return "LOAD_A";
        case UOP_LOAD_B: return "LOAD_B";
        case UOP_GEMM: return "GEMM";
        case UOP_OUTPUT: return "OUTPUT";
        default: return "UNKNOWN";
    }
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

std::string describe(const Uop& uop) {
    std::ostringstream os;
    os << type_name(uop.type)
       << " addr=" << hex32(uop.addr)
       << " abuf=" << uop.abuf
       << " bbuf=" << uop.bbuf
       << " pacc=" << uop.pacc
       << " accum=" << (uop.accum ? 1 : 0);
    if (!uop.tag.empty()) {
        os << " tag=" << uop.tag;
    }
    return os.str();
}

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

int ceil_div(uint32_t value, int div) {
    return static_cast<int>((value + static_cast<uint32_t>(div) - 1u) /
                            static_cast<uint32_t>(div));
}

std::pair<int, int> choose_block() {
    int best_m = 1;
    int best_n = 1;
    int best_area = 1;
    int best_balance = 0;
    for (int bm = 1; bm <= kABufSize; ++bm) {
        for (int bn = 1; bn <= kBBufSize; ++bn) {
            const int area = bm * bn;
            const int balance = std::abs(bm - bn);
            if (area <= kPaccNum &&
                (area > best_area ||
                 (area == best_area && balance < best_balance) ||
                 (area == best_area && balance == best_balance && bm > best_m) ||
                 (area == best_area && balance == best_balance && bm == best_m &&
                  bn > best_n))) {
                best_m = bm;
                best_n = bn;
                best_area = area;
                best_balance = balance;
            }
        }
    }
    return {best_m, best_n};
}

std::vector<Uop> reference_for_cmd(const Cmd& cmd) {
    const std::pair<int, int> block = choose_block();
    const int block_m_max = block.first;
    const int block_n_max = block.second;
    const int tm = ceil_div(cmd.m, kSaWidth);
    const int tn = ceil_div(cmd.n, kSaWidth);
    const int tk = ceil_div(cmd.k, kSaWidth);
    std::vector<Uop> out;

    if (tm == 0 || tn == 0 || tk == 0) {
        return out;
    }

    for (int block_m_base = 0; block_m_base < tm; block_m_base += block_m_max) {
        const int block_m = std::min(block_m_max, tm - block_m_base);
        for (int block_n_base = 0; block_n_base < tn; block_n_base += block_n_max) {
            const int block_n = std::min(block_n_max, tn - block_n_base);

            for (int kt = 0; kt < tk; ++kt) {
                for (int lm = 0; lm < block_m; ++lm) {
                    Uop u;
                    u.type = UOP_LOAD_A;
                    u.addr = cmd.a_base + static_cast<uint32_t>((block_m_base + lm) * tk + kt);
                    u.abuf = static_cast<uint32_t>(lm);
                    u.tag = cmd.name;
                    out.push_back(u);
                }

                for (int ln = 0; ln < block_n; ++ln) {
                    Uop u;
                    u.type = UOP_LOAD_B;
                    u.addr = cmd.b_base + static_cast<uint32_t>(kt * tn + block_n_base + ln);
                    u.bbuf = static_cast<uint32_t>(ln);
                    u.tag = cmd.name;
                    out.push_back(u);
                }

                for (int lm = 0; lm < block_m; ++lm) {
                    for (int ln = 0; ln < block_n; ++ln) {
                        Uop u;
                        u.type = UOP_GEMM;
                        u.abuf = static_cast<uint32_t>(lm);
                        u.bbuf = static_cast<uint32_t>(ln);
                        u.pacc = static_cast<uint32_t>(lm * block_n + ln);
                        u.accum = kt != 0;
                        u.tag = cmd.name;
                        out.push_back(u);
                    }
                }
            }

            for (int lm = 0; lm < block_m; ++lm) {
                for (int ln = 0; ln < block_n; ++ln) {
                    Uop u;
                    u.type = UOP_OUTPUT;
                    u.addr = cmd.c_base + static_cast<uint32_t>((block_m_base + lm) * tn +
                                                                block_n_base + ln);
                    u.pacc = static_cast<uint32_t>(lm * block_n + ln);
                    u.tag = cmd.name;
                    out.push_back(u);
                }
            }
        }
    }

    return out;
}

std::vector<Uop> reference_for_cmds(const std::vector<Cmd>& cmds) {
    std::vector<Uop> out;
    for (const Cmd& cmd : cmds) {
        std::vector<Uop> cur = reference_for_cmd(cmd);
        out.insert(out.end(), cur.begin(), cur.end());
    }
    return out;
}

class Tb {
public:
    Vuopparse dut;
    uint64_t cycle = 0;

    Tb() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.cmd_valid_i = 0;
        dut.uop_ready_i = 0;
        clear_cmd_inputs();
        dut.eval();
    }

    void clear_cmd_inputs() {
        dut.cmd_a_base_i = 0;
        dut.cmd_b_base_i = 0;
        dut.cmd_c_base_i = 0;
        dut.cmd_m_i = 0;
        dut.cmd_n_i = 0;
        dut.cmd_k_i = 0;
    }

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
        dut.rst_n = 0;
        dut.cmd_valid_i = 0;
        dut.uop_ready_i = 0;
        clear_cmd_inputs();
        for (int i = 0; i < 4; ++i) {
            tick();
        }
        dut.rst_n = 1;
        tick();
    }
};

void drive_cmd(Vuopparse& dut, const Cmd& cmd) {
    dut.cmd_a_base_i = cmd.a_base;
    dut.cmd_b_base_i = cmd.b_base;
    dut.cmd_c_base_i = cmd.c_base;
    dut.cmd_m_i = cmd.m;
    dut.cmd_n_i = cmd.n;
    dut.cmd_k_i = cmd.k;
}

Uop read_uop(const Vuopparse& dut) {
    Uop u;
    u.type = static_cast<uint8_t>(dut.uop_type_o);
    u.addr = static_cast<uint32_t>(dut.uop_addr_o);
    u.abuf = static_cast<uint32_t>(dut.uop_abufidx_o);
    u.bbuf = static_cast<uint32_t>(dut.uop_bbufidx_o);
    u.pacc = static_cast<uint32_t>(dut.uop_paccidx_o);
    u.accum = dut.uop_accum_o != 0;
    return u;
}

bool same_uop(const Uop& a, const Uop& b) {
    return a.type == b.type &&
           a.addr == b.addr &&
           a.abuf == b.abuf &&
           a.bbuf == b.bbuf &&
           a.pacc == b.pacc &&
           a.accum == b.accum;
}

void compare_uop(const Uop& got, const Uop& exp, size_t index, uint64_t cycle) {
    if (!same_uop(got, exp)) {
        std::ostringstream os;
        os << "uop mismatch at index " << index << " cycle " << cycle
           << "\n  got: " << describe(got)
           << "\n  exp: " << describe(exp);
        fail(os.str());
    }
}

using ReadyFn = bool (*)(uint64_t cycle);

bool ready_always(uint64_t) {
    return true;
}

bool ready_periodic_stall(uint64_t cycle) {
    return (cycle % 7) != 2 && (cycle % 11) != 5;
}

bool ready_bursty(uint64_t cycle) {
    const uint64_t phase = cycle % 13;
    return phase < 5 || phase == 9 || phase == 12;
}

void run_sequence(const std::string& name,
                  const std::vector<Cmd>& cmds,
                  ReadyFn ready_fn) {
    Tb tb;
    tb.reset();

    const std::vector<Uop> expected = reference_for_cmds(cmds);
    size_t cmd_idx = 0;
    size_t exp_idx = 0;
    bool have_hold = false;
    Uop hold;

    const uint64_t max_cycles = 20000 + expected.size() * 20 + cmds.size() * 20;
    while (tb.cycle < max_cycles) {
        tb.dut.cmd_valid_i = (cmd_idx < cmds.size()) ? 1 : 0;
        if (cmd_idx < cmds.size()) {
            drive_cmd(tb.dut, cmds[cmd_idx]);
        } else {
            tb.clear_cmd_inputs();
        }
        tb.dut.uop_ready_i = ready_fn(tb.cycle) ? 1 : 0;
        tb.dut.eval();

        const bool cmd_fire = tb.dut.cmd_valid_i && tb.dut.cmd_ready_o;
        const bool uop_valid = tb.dut.uop_valid_o != 0;
        const bool uop_fire = uop_valid && tb.dut.uop_ready_i;

        if (uop_valid) {
            const Uop got = read_uop(tb.dut);
            if (have_hold && !same_uop(got, hold)) {
                std::ostringstream os;
                os << name << ": output changed while stalled at cycle " << tb.cycle
                   << "\n  previous: " << describe(hold)
                   << "\n  current : " << describe(got);
                fail(os.str());
            }

            if (uop_fire) {
                if (exp_idx >= expected.size()) {
                    std::ostringstream os;
                    os << name << ": DUT produced extra uop at cycle " << tb.cycle
                       << "\n  got: " << describe(got);
                    fail(os.str());
                }
                compare_uop(got, expected[exp_idx], exp_idx, tb.cycle);
                ++exp_idx;
                have_hold = false;
            } else {
                hold = got;
                have_hold = true;
            }
        } else if (have_hold) {
            std::ostringstream os;
            os << name << ": valid dropped while stalled at cycle " << tb.cycle;
            fail(os.str());
        }

        tb.tick();
        if (cmd_fire) {
            ++cmd_idx;
        }

        tb.dut.eval();
        if (cmd_idx == cmds.size() &&
            exp_idx == expected.size() &&
            tb.dut.uop_valid_o == 0 &&
            tb.dut.cmd_ready_o != 0) {
            std::cout << name << ": passed, uops=" << expected.size()
                      << " cycles=" << tb.cycle << "\n";
            return;
        }
    }

    std::ostringstream os;
    os << name << ": timeout after " << max_cycles
       << " cycles, accepted_cmds=" << cmd_idx << "/" << cmds.size()
       << " uops=" << exp_idx << "/" << expected.size();
    fail(os.str());
}

uint32_t parse_seed(int argc, char** argv) {
    uint32_t seed = 0x5eed1234u;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        const std::string prefix = "--seed=";
        if (arg.rfind(prefix, 0) == 0) {
            seed = static_cast<uint32_t>(std::stoul(arg.substr(prefix.size()), nullptr, 0));
        }
    }
    return seed;
}

std::vector<Cmd> random_cmds(uint32_t seed) {
    std::mt19937 rng(seed);
    const std::pair<int, int> block = choose_block();
    const int max_m_tiles = std::max(4, block.first + 4);
    const int max_n_tiles = std::max(4, block.second + 8);
    const int max_k_tiles = 12;
    std::uniform_int_distribution<int> m_tile_dist(0, max_m_tiles);
    std::uniform_int_distribution<int> n_tile_dist(0, max_n_tiles);
    std::uniform_int_distribution<int> k_tile_dist(0, max_k_tiles);
    std::uniform_int_distribution<int> edge_dist(0, kSaWidth - 1);
    std::uniform_int_distribution<uint32_t> base_dist(0, 4000);

    std::vector<Cmd> cmds;
    for (int i = 0; i < 48; ++i) {
        const int m_tiles = m_tile_dist(rng);
        const int n_tiles = n_tile_dist(rng);
        const int k_tiles = k_tile_dist(rng);
        Cmd cmd;
        cmd.a_base = 0x10000u + base_dist(rng) + static_cast<uint32_t>(i * 1000);
        cmd.b_base = 0x20000u + base_dist(rng) + static_cast<uint32_t>(i * 1000);
        cmd.c_base = 0x30000u + base_dist(rng) + static_cast<uint32_t>(i * 1000);
        cmd.m = m_tiles == 0 ? 0u :
            static_cast<uint32_t>((m_tiles - 1) * kSaWidth + 1 + edge_dist(rng));
        cmd.n = n_tiles == 0 ? 0u :
            static_cast<uint32_t>((n_tiles - 1) * kSaWidth + 1 + edge_dist(rng));
        cmd.k = k_tiles == 0 ? 0u :
            static_cast<uint32_t>((k_tiles - 1) * kSaWidth + 1 + edge_dist(rng));
        cmd.name = "rand" + std::to_string(i);
        cmds.push_back(cmd);
    }
    return cmds;
}

std::vector<Cmd> target_extreme_cmds() {
    const std::pair<int, int> block = choose_block();
    const int block_m = block.first;
    const int block_n = block.second;
    const uint32_t s = static_cast<uint32_t>(kSaWidth);

    std::vector<Cmd> cmds;
    cmds.push_back(Cmd{0x00100000u, 0x00200000u, 0x00300000u,
                       1u, 1u, 1u, "one_element"});
    cmds.push_back(Cmd{0x00110000u, 0x00210000u, 0x00310000u,
                       s - 1u, s, s + 1u, "tile_edges"});
    cmds.push_back(Cmd{0x00120000u, 0x00220000u, 0x00320000u,
                       static_cast<uint32_t>(block_m) * s,
                       static_cast<uint32_t>(block_n) * s,
                       2u * s + 3u, "exact_block"});
    cmds.push_back(Cmd{0x00130000u, 0x00230000u, 0x00330000u,
                       static_cast<uint32_t>(block_m + 1) * s + 5u,
                       static_cast<uint32_t>(block_n + 1) * s + 7u,
                       3u * s + 11u, "cross_block_small"});
    cmds.push_back(Cmd{0x00140000u, 0x00240000u, 0x00340000u,
                       static_cast<uint32_t>(block_m + 3) * s + 13u,
                       static_cast<uint32_t>(block_n + 7) * s + 17u,
                       9u * s + 19u, "cross_block_large_k"});
    return cmds;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        const uint32_t seed = parse_seed(argc, argv);
        const std::pair<int, int> block = choose_block();
        const int block_m = block.first;
        const int block_n = block.second;
        std::cout << "uopparse test config: SA_WIDTH=" << kSaWidth
                  << " ABUF_SIZE=" << kABufSize
                  << " BBUF_SIZE=" << kBBufSize
                  << " PACC_NUM=" << kPaccNum
                  << " block=" << block_m << "x" << block_n
                  << " seed=" << hex32(seed) << "\n";

        if (kSaWidth == 32 && kABufSize == 64 && kBBufSize == 64 &&
            kPaccNum == 16 && (block_m != 4 || block_n != 4)) {
            std::ostringstream os;
            os << "target config should choose balanced 4x4 block, got "
               << block_m << "x" << block_n;
            fail(os.str());
        }

        run_sequence(
            "single_tile",
            {Cmd{0x10, 0x80, 0x100, static_cast<uint32_t>(kSaWidth),
                 static_cast<uint32_t>(kSaWidth), static_cast<uint32_t>(kSaWidth),
                 "single"}},
            ready_always
        );

        run_sequence(
            "multiblock_backpressure",
            {Cmd{0x1000, 0x2000, 0x3000,
                 static_cast<uint32_t>(2 * kSaWidth + 1),
                 static_cast<uint32_t>(2 * kSaWidth + 2),
                 static_cast<uint32_t>(2 * kSaWidth + 1),
                 "multi"}},
            ready_periodic_stall
        );

        run_sequence(
            "busy_cmd_stream",
            {
                Cmd{0x10, 0x20, 0x30, 0, static_cast<uint32_t>(kSaWidth), 4, "zero_m"},
                Cmd{0x400, 0x800, 0xc00,
                    static_cast<uint32_t>(3 * kSaWidth),
                    static_cast<uint32_t>(2 * kSaWidth + 1),
                    static_cast<uint32_t>(2 * kSaWidth),
                    "first_busy"},
                Cmd{0x1400, 0x1800, 0x1c00,
                    static_cast<uint32_t>(kSaWidth + 1),
                    static_cast<uint32_t>(kSaWidth + 1),
                    static_cast<uint32_t>(3 * kSaWidth + 1),
                    "second_busy"},
            },
            ready_bursty
        );

        run_sequence("target_extremes", target_extreme_cmds(), ready_bursty);
        run_sequence("random_stress", random_cmds(seed), ready_periodic_stall);

        std::cout << "uopparse tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << "uopparse test failed: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
