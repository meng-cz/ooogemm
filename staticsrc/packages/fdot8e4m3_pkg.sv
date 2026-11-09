// Generated shared package; do not edit.
// Source: src/pe/fdot8e4m3.sv
// FP8 E4M3 vector dot product carry-save accumulator.
//
// Input protocol:
//   - Every cycle with valid_i=1 is accepted; there is no back-pressure.
//   - first_i marks the first product of one dot product.
//   - last_i marks the final product of one dot product.
//   - paccidx_i and accum_i are sampled with valid_i && last_i and appear with
//     the corresponding valid_o carry-save fixed-point result.
//   - Back-to-back dot products are supported.
//
// Arithmetic:
//   - FP8 is interpreted as E4M3FN: sign, 4-bit exponent with bias 7,
//     3-bit fraction, and only exp=15/fraction=7 is NaN.
//   - Products are formed exactly and aligned into a two's-complement
//     fixed-point format with ACC_FRAC_BITS fractional bits.
//   - Dot products are accumulated as a carry-save pair.  The output represents
//     value = (psum_sum_o + psum_carry_o) * 2^-ACC_FRAC_BITS; psum_carry_o is
//     already shifted into its arithmetic weight.

`default_nettype none


`default_nettype none

package fdot8e4m3_pkg;

    localparam int MUL_LAST_TO_SUM_STAGES = 2;
    localparam int LAST_TO_OUT_LATENCY    = MUL_LAST_TO_SUM_STAGES;

endpackage

`default_nettype wire
