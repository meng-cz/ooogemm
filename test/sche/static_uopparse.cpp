#include "Vstatic_uopparse.h"
#include "verilated.h"

#include <cstdint>
#include <deque>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

#ifndef SA_WIDTH_TEST
#define SA_WIDTH_TEST 32
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

constexpr int kSaWidth = SA_WIDTH_TEST;
constexpr int kABufGroupSize = ABUF_SIZE_TEST / 2;
constexpr int kBBufGroupSize = BBUF_SIZE_TEST / 2;

enum UopType : uint8_t {
    UOP_LOAD_A = 0,
    UOP_LOAD_B = 1,
    UOP_GEMM = 2,
    UOP_OUTPUT = 3,
    UOP_BUF_SWAP = 4,
    UOP_ACC_FENCE = 5,
};

struct Uop {
    uint8_t type = 0;
    uint32_t addr = 0;
    uint32_t abuf = 0;
    uint32_t bbuf = 0;
    uint32_t pacc = 0;
    bool accum = false;
};

struct Cmd {
    uint32_t a_base = 0;
    uint32_t b_base = 0;
    uint32_t c_base = 0;
    uint32_t m = 0;
    uint32_t n = 0;
    uint32_t k = 0;
};

std::string type_name(uint8_t type) {
    switch (type) {
        case UOP_LOAD_A: return "LOAD_A";
        case UOP_LOAD_B: return "LOAD_B";
        case UOP_GEMM: return "GEMM";
        case UOP_OUTPUT: return "OUTPUT";
        case UOP_BUF_SWAP: return "BUF_SWAP";
        case UOP_ACC_FENCE: return "ACC_FENCE";
        default: return "UNKNOWN";
    }
}

std::string hex32(uint32_t value) {
    std::ostringstream os;
    os << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return os.str();
}

std::string describe(const Uop& u) {
    std::ostringstream os;
    os << type_name(u.type)
       << " addr=" << hex32(u.addr)
       << " abuf=" << u.abuf
       << " bbuf=" << u.bbuf
       << " pacc=" << u.pacc
       << " accum=" << (u.accum ? 1 : 0);
    return os.str();
}

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

Uop la(uint32_t addr, uint32_t local_m, int group) {
    Uop u;
    u.type = UOP_LOAD_A;
    u.addr = addr;
    u.abuf = static_cast<uint32_t>(group * kABufGroupSize) + local_m;
    return u;
}

Uop lb(uint32_t addr, uint32_t local_n, int group) {
    Uop u;
    u.type = UOP_LOAD_B;
    u.addr = addr;
    u.bbuf = static_cast<uint32_t>(group * kBBufGroupSize) + local_n;
    return u;
}

Uop gemm(uint32_t local_m, uint32_t local_n, int group, uint32_t block_n, bool accum) {
    Uop u;
    u.type = UOP_GEMM;
    u.abuf = static_cast<uint32_t>(group * kABufGroupSize) + local_m;
    u.bbuf = static_cast<uint32_t>(group * kBBufGroupSize) + local_n;
    u.pacc = local_m * block_n + local_n;
    u.accum = accum;
    return u;
}

Uop out(uint32_t addr, uint32_t local_m, uint32_t local_n, uint32_t block_n) {
    Uop u;
    u.type = UOP_OUTPUT;
    u.addr = addr;
    u.pacc = local_m * block_n + local_n;
    return u;
}

Uop special(uint8_t type) {
    Uop u;
    u.type = type;
    return u;
}

bool same(const Uop& a, const Uop& b) {
    return a.type == b.type &&
           a.addr == b.addr &&
           a.abuf == b.abuf &&
           a.bbuf == b.bbuf &&
           a.pacc == b.pacc &&
           a.accum == b.accum;
}

class Tb {
public:
    Vstatic_uopparse dut;
    uint64_t cycle = 0;

    Tb() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.cmd_valid_i = 0;
        dut.uop_ready_i = 0;
        clear_cmd();
        dut.eval();
    }

    void reset() {
        dut.rst_n = 0;
        for (int i = 0; i < 4; ++i) {
            tick();
        }
        dut.rst_n = 1;
        tick();
    }

    void clear_cmd() {
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
};

Uop read_uop(const Vstatic_uopparse& dut) {
    Uop u;
    u.type = static_cast<uint8_t>(dut.uop_type_o);
    u.addr = static_cast<uint32_t>(dut.uop_addr_o);
    u.abuf = static_cast<uint32_t>(dut.uop_abufidx_o);
    u.bbuf = static_cast<uint32_t>(dut.uop_bbufidx_o);
    u.pacc = static_cast<uint32_t>(dut.uop_paccidx_o);
    u.accum = dut.uop_accum_o != 0;
    return u;
}

void run_case(const std::string& name,
              uint32_t a_base,
              uint32_t b_base,
              uint32_t c_base,
              uint32_t m,
              uint32_t n,
              uint32_t k,
              const std::vector<Uop>& expected) {
    Tb tb;
    tb.reset();

    size_t index = 0;
    bool have_hold = false;
    Uop hold;

    for (int cyc = 0; cyc < 5000; ++cyc) {
        tb.dut.cmd_valid_i = (index == 0 && tb.dut.cmd_ready_o) ? 1 : 0;
        tb.dut.cmd_a_base_i = a_base;
        tb.dut.cmd_b_base_i = b_base;
        tb.dut.cmd_c_base_i = c_base;
        tb.dut.cmd_m_i = m;
        tb.dut.cmd_n_i = n;
        tb.dut.cmd_k_i = k;
        tb.dut.uop_ready_i = ((tb.cycle % 7) != 2) ? 1 : 0;
        tb.dut.eval();

        const bool valid = tb.dut.uop_valid_o != 0;
        const bool fire = valid && tb.dut.uop_ready_i;
        if (valid) {
            const Uop got = read_uop(tb.dut);
            if (have_hold && !same(got, hold)) {
                fail(name + ": output changed while stalled");
            }
            if (fire) {
                if (index >= expected.size()) {
                    fail(name + ": extra uop " + describe(got));
                }
                if (!same(got, expected[index])) {
                    std::ostringstream os;
                    os << name << ": mismatch at uop " << index
                       << "\n  got: " << describe(got)
                       << "\n  exp: " << describe(expected[index]);
                    fail(os.str());
                }
                ++index;
                have_hold = false;
            } else {
                hold = got;
                have_hold = true;
            }
        }

        tb.tick();
        if (index == expected.size() && tb.dut.uop_valid_o == 0 && tb.dut.cmd_ready_o != 0) {
            std::cout << name << ": passed, uops=" << expected.size() << "\n";
            return;
        }
    }

    std::ostringstream os;
    os << name << ": timeout at uop " << index << "/" << expected.size();
    fail(os.str());
}

void run_command_stream(const std::string& name,
                        const std::vector<Cmd>& cmds,
                        const std::vector<Uop>& expected) {
    Tb tb;
    tb.reset();

    size_t cmd_index = 0;
    size_t uop_index = 0;
    bool have_hold = false;
    Uop hold;

    for (int cyc = 0; cyc < 10000; ++cyc) {
        const bool drive_cmd = (cmd_index < cmds.size()) && (tb.dut.cmd_ready_o != 0);
        const Cmd cmd = drive_cmd ? cmds[cmd_index] : Cmd{};
        tb.dut.cmd_valid_i = drive_cmd ? 1 : 0;
        tb.dut.cmd_a_base_i = cmd.a_base;
        tb.dut.cmd_b_base_i = cmd.b_base;
        tb.dut.cmd_c_base_i = cmd.c_base;
        tb.dut.cmd_m_i = cmd.m;
        tb.dut.cmd_n_i = cmd.n;
        tb.dut.cmd_k_i = cmd.k;
        tb.dut.uop_ready_i = ((tb.cycle % 5) != 1) ? 1 : 0;
        tb.dut.eval();

        const bool cmd_fire = tb.dut.cmd_valid_i && tb.dut.cmd_ready_o;
        const bool valid = tb.dut.uop_valid_o != 0;
        const bool fire = valid && tb.dut.uop_ready_i;
        if (valid) {
            const Uop got = read_uop(tb.dut);
            if (have_hold && !same(got, hold)) {
                fail(name + ": output changed while stalled");
            }
            if (fire) {
                if (uop_index >= expected.size()) {
                    fail(name + ": extra uop " + describe(got));
                }
                if (!same(got, expected[uop_index])) {
                    std::ostringstream os;
                    os << name << ": mismatch at uop " << uop_index
                       << "\n  got: " << describe(got)
                       << "\n  exp: " << describe(expected[uop_index]);
                    fail(os.str());
                }
                ++uop_index;
                have_hold = false;
            } else {
                hold = got;
                have_hold = true;
            }
        }

        tb.tick();
        if (cmd_fire) {
            ++cmd_index;
        }

        if (cmd_index == cmds.size() &&
            uop_index == expected.size() &&
            tb.dut.uop_valid_o == 0 &&
            tb.dut.cmd_ready_o != 0) {
            std::cout << name << ": passed, commands=" << cmds.size()
                      << " uops=" << expected.size() << "\n";
            return;
        }
    }

    std::ostringstream os;
    os << name << ": timeout at command " << cmd_index << "/" << cmds.size()
       << ", uop " << uop_index << "/" << expected.size();
    fail(os.str());
}

std::vector<Uop> two_by_two_two_k(uint32_t a, uint32_t b, uint32_t c) {
    std::vector<Uop> e;
    e.push_back(la(a + 0, 0, 0));
    e.push_back(la(a + 2, 1, 0));
    e.push_back(lb(b + 0, 0, 0));
    e.push_back(lb(b + 1, 1, 0));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(la(a + 1, 0, 1));
    e.push_back(la(a + 3, 1, 1));
    e.push_back(lb(b + 2, 0, 1));
    e.push_back(lb(b + 3, 1, 1));
    e.push_back(special(UOP_ACC_FENCE));
    for (int m = 0; m < 2; ++m) {
        for (int n = 0; n < 2; ++n) {
            e.push_back(gemm(m, n, 0, 2, false));
        }
    }
    e.push_back(special(UOP_BUF_SWAP));
    for (int m = 0; m < 2; ++m) {
        for (int n = 0; n < 2; ++n) {
            e.push_back(gemm(m, n, 1, 2, true));
        }
    }
    e.push_back(out(c + 0, 0, 0, 2));
    e.push_back(out(c + 1, 0, 1, 2));
    e.push_back(out(c + 2, 1, 0, 2));
    e.push_back(out(c + 3, 1, 1, 2));
    return e;
}

std::vector<Uop> two_blocks(uint32_t a, uint32_t b, uint32_t c) {
    std::vector<Uop> e;
    e.push_back(la(a + 0, 0, 0));
    e.push_back(la(a + 2, 1, 0));
    e.push_back(lb(b + 0, 0, 0));
    e.push_back(lb(b + 1, 1, 0));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(la(a + 1, 0, 1));
    e.push_back(la(a + 3, 1, 1));
    e.push_back(lb(b + 3, 0, 1));
    e.push_back(lb(b + 4, 1, 1));
    e.push_back(special(UOP_ACC_FENCE));
    for (int m = 0; m < 2; ++m) {
        for (int n = 0; n < 2; ++n) {
            e.push_back(gemm(m, n, 0, 2, false));
        }
    }
    e.push_back(special(UOP_BUF_SWAP));
    for (int m = 0; m < 2; ++m) {
        for (int n = 0; n < 2; ++n) {
            e.push_back(gemm(m, n, 1, 2, true));
        }
    }
    e.push_back(out(c + 0, 0, 0, 2));
    e.push_back(out(c + 1, 0, 1, 2));
    e.push_back(out(c + 3, 1, 0, 2));
    e.push_back(out(c + 4, 1, 1, 2));

    e.push_back(la(a + 0, 0, 0));
    e.push_back(la(a + 2, 1, 0));
    e.push_back(lb(b + 2, 0, 0));
    e.push_back(special(UOP_ACC_FENCE));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(la(a + 1, 0, 1));
    e.push_back(la(a + 3, 1, 1));
    e.push_back(lb(b + 5, 0, 1));
    e.push_back(gemm(0, 0, 0, 1, false));
    e.push_back(gemm(1, 0, 0, 1, false));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(gemm(0, 0, 1, 1, true));
    e.push_back(gemm(1, 0, 1, 1, true));
    e.push_back(out(c + 2, 0, 0, 1));
    e.push_back(out(c + 5, 1, 0, 1));
    return e;
}

std::vector<Uop> two_single_tile_commands(uint32_t a0, uint32_t b0, uint32_t c0,
                                          uint32_t a1, uint32_t b1, uint32_t c1) {
    std::vector<Uop> e;
    e.push_back(la(a0 + 0, 0, 0));
    e.push_back(lb(b0 + 0, 0, 0));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(special(UOP_ACC_FENCE));
    e.push_back(gemm(0, 0, 0, 1, false));
    e.push_back(out(c0 + 0, 0, 0, 1));

    e.push_back(la(a1 + 0, 0, 1));
    e.push_back(lb(b1 + 0, 0, 1));
    e.push_back(special(UOP_BUF_SWAP));
    e.push_back(special(UOP_ACC_FENCE));
    e.push_back(gemm(0, 0, 1, 1, false));
    e.push_back(out(c1 + 0, 0, 0, 1));
    return e;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        run_case("two_by_two_two_k", 0x1000, 0x2000, 0x3000,
                 2 * kSaWidth, 2 * kSaWidth, 2 * kSaWidth,
                 two_by_two_two_k(0x1000, 0x2000, 0x3000));
        run_case("two_blocks", 0x4000, 0x5000, 0x6000,
                 2 * kSaWidth, 3 * kSaWidth, 2 * kSaWidth,
                 two_blocks(0x4000, 0x5000, 0x6000));
        run_command_stream(
            "two_command_group_flip",
            {
                Cmd{0x7000, 0x8000, 0x9000, kSaWidth, kSaWidth, kSaWidth},
                Cmd{0x7100, 0x8100, 0x9100, kSaWidth, kSaWidth, kSaWidth},
            },
            two_single_tile_commands(0x7000, 0x8000, 0x9000,
                                     0x7100, 0x8100, 0x9100)
        );
        std::cout << "static_uopparse tests passed\n";
    } catch (const std::exception& e) {
        std::cerr << "static_uopparse test failed: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
