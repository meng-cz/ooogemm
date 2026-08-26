#include "Vdynamic_sche.h"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {

constexpr uint8_t kLoadA = 0;
constexpr uint8_t kLoadB = 1;
constexpr uint8_t kGemm = 2;
constexpr uint8_t kOutput = 3;

[[noreturn]] void fail(const char* message) {
    throw std::runtime_error(message);
}

class Tb {
public:
    Vdynamic_sche dut;

    Tb() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.uop_valid_i = 0;
        dut.load_ready_i = 0;
        dut.gemm_ready_i = 0;
        dut.output_ready_i = 0;
        dut.load_a_done_valid_i = 0;
        dut.load_b_done_valid_i = 0;
        dut.gemm_done_valid_i = 0;
        dut.output_done_valid_i = 0;
        tick();
        tick();
        dut.rst_n = 1;
        tick();
    }

    void tick() {
        dut.clk = 0;
        dut.eval();
        dut.clk = 1;
        dut.eval();
        dut.clk = 0;
        dut.eval();
    }

    void send(uint8_t type, uint32_t addr, uint8_t a, uint8_t b,
              uint8_t pacc, bool accum = false) {
        dut.uop_type_i = type;
        dut.uop_addr_i = addr;
        dut.uop_abufidx_i = a;
        dut.uop_bbufidx_i = b;
        dut.uop_paccidx_i = pacc;
        dut.uop_valid_rows_i = 4;
        dut.uop_accum_i = accum;
        dut.uop_valid_i = 1;
        dut.eval();
        if (!dut.uop_ready_o) {
            fail("scheduler unexpectedly backpressured input");
        }
        tick();
        dut.uop_valid_i = 0;
    }

    void issue_load(uint8_t expected_type, uint32_t expected_addr) {
        dut.eval();
        if (!dut.load_valid_o || dut.load_type_o != expected_type ||
            dut.load_addr_o != expected_addr) {
            fail("incorrect ordered LOAD issue");
        }
        dut.load_ready_i = 1;
        tick();
        dut.load_ready_i = 0;
    }

    uint8_t issue_gemm() {
        dut.eval();
        if (!dut.gemm_valid_o) {
            fail("expected ready GEMM");
        }
        const uint8_t pacc = dut.gemm_paccidx_o;
        dut.gemm_ready_i = 1;
        tick();
        dut.gemm_ready_i = 0;
        return pacc;
    }

    void complete_a(uint8_t phys) {
        dut.load_a_done_phys_i = phys;
        dut.load_a_done_valid_i = 1;
        tick();
        dut.load_a_done_valid_i = 0;
    }

    void complete_b(uint8_t phys) {
        dut.load_b_done_phys_i = phys;
        dut.load_b_done_valid_i = 1;
        tick();
        dut.load_b_done_valid_i = 0;
    }

    void complete_gemm(uint8_t pacc) {
        dut.gemm_done_paccidx_i = pacc;
        dut.gemm_done_valid_i = 1;
        tick();
        dut.gemm_done_valid_i = 0;
    }

    void issue_output(uint8_t pacc, uint32_t addr) {
        dut.eval();
        if (!dut.output_valid_o || dut.output_paccidx_o != pacc ||
            dut.output_addr_o != addr) {
            fail("OUTPUT issued before its PACC was ready or had wrong payload");
        }
        dut.output_ready_i = 1;
        tick();
        dut.output_ready_i = 0;
    }

    void complete_output(uint8_t pacc) {
        dut.output_done_paccidx_i = pacc;
        dut.output_done_valid_i = 1;
        tick();
        dut.output_done_valid_i = 0;
    }
};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Tb tb;

        // LOAD FIFO is globally ordered; its completion broadcasts readiness.
        tb.send(kLoadA, 0x10, 0, 0, 0);
        tb.send(kLoadB, 0x20, 0, 0, 0);
        tb.issue_load(kLoadA, 0x10);
        tb.issue_load(kLoadB, 0x20);
        tb.complete_a(0);
        tb.complete_b(0);

        // GEMMs in different PACC slots may issue out of order.  OUTPUT waits
        // for the completion count rather than merely the GEMM dispatch.
        tb.send(kGemm, 0, 0, 0, 0, false);
        tb.send(kGemm, 0, 0, 0, 2, false);
        tb.send(kOutput, 0x100, 0, 0, 0);
        tb.send(kOutput, 0x200, 0, 0, 2);
        const uint8_t first = tb.issue_gemm();
        const uint8_t second = tb.issue_gemm();
        if (first == second || ((first != 0) && (first != 2)) ||
            ((second != 0) && (second != 2))) {
            fail("round-robin GEMM slots did not issue both independent heads");
        }
        tb.complete_gemm(0);
        tb.issue_output(0, 0x100);
        tb.complete_output(0);
        tb.complete_gemm(2);
        tb.issue_output(2, 0x200);
        tb.complete_output(2);

        // accum=1 is an in-place operation, but slot FIFO ordering is enough:
        // the second head may issue before the first completes because the
        // systolic array preserves completion order for ordered dispatch.
        tb.send(kGemm, 0, 0, 0, 0, false);
        tb.send(kGemm, 0, 0, 0, 0, true);
        if (tb.issue_gemm() != 0) {
            fail("wrong PACC selected for serialized GEMM");
        }
        tb.dut.eval();
        if (tb.dut.gemm_valid_o) {
            fail("slot refilled and issued in the same cycle");
        }
        // The slot pipeline register was just consumed.  Its next FIFO head
        // moves into that register on this cycle and can issue next cycle.
        tb.tick();
        tb.dut.eval();
        if (!tb.dut.gemm_valid_o || !tb.dut.gemm_accum_o) {
            fail("ordered in-place accumulating GEMM did not follow its predecessor");
        }
        if (tb.issue_gemm() != 0) {
            fail("wrong PACC selected for accumulating GEMM");
        }
        tb.complete_gemm(0);
        tb.complete_gemm(0);

        std::cout << "dynamic_sche tests passed\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "dynamic_sche test failed: " << e.what() << "\n";
        return 1;
    }
}
