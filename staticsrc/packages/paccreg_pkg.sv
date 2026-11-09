// Generated shared package; do not edit.
// Source: src/pe/paccreg.sv
// Pseudo-FP32 partial-accumulator register file.
//
// Accumulation input format:
//   - fdot provides a carry-save fixed-point dot result.
//   - dot_value = (psum_sum_i + psum_carry_i) * 2^-FDOT_ACC_FRAC_BITS.
//   - psum_carry_i is already shifted into its arithmetic weight.
//
// PACC register format:
//   - Finite values are represented as value = sig * 2^exp.
//   - sig is a signed two's-complement extended significand.
//   - The maximum positive exponent with sig!=0 is reserved as NaN.
//
// Pipeline:
//   - Accumulation input writes the register file after ACCUM_PIPE_STAGES.
//   - The input protocol permits one submission per cycle, but requires at
//     least four submission cycles between two uses of the same paccidx.
//     This leaves three cycles between the ACC read and the next writeback, so
//     the accumulation read path does not need a datapath bypass.
//   - ACC storage contents are not initialized by reset.  Software/uopparse
//     must begin each PACC accumulation sequence with accum=0; accum=1 assumes
//     that the corresponding PACC already contains a valid prior result.
//   - getacc requests produce getacc_o/getacc_data_o after GETACC_PIPE_STAGES.

`default_nettype none


`default_nettype none

package paccreg_pkg;

    localparam int ACCUM_PIPE_STAGES  = 7;
    // GETACC includes the synchronous ACC SRAM read cycle.
    localparam int GETACC_PIPE_STAGES = 5;

endpackage

`default_nettype wire
