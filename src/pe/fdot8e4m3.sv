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

package fdot8e4m3_pkg;

    localparam int MUL_LAST_TO_SUM_STAGES = 2;
    localparam int LAST_TO_OUT_LATENCY    = MUL_LAST_TO_SUM_STAGES;

endpackage

module fdot8e4m3 #(
    parameter int ACC_WIDTH      = 96,
    parameter int ACC_FRAC_BITS  = 18,
    parameter int FDOT_CSA_WIDTH = ACC_WIDTH + 2,
    parameter int PACC_IDX_WIDTH = 1
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        valid_i,
    input  logic [7:0]  a_i,
    input  logic [7:0]  b_i,
    input  logic        first_i,
    input  logic        last_i,
    input  logic [PACC_IDX_WIDTH-1:0] paccidx_i,
    input  logic        accum_i,

    output logic        valid_o,
    output logic signed [FDOT_CSA_WIDTH-1:0] psum_sum_o,
    output logic signed [FDOT_CSA_WIDTH-1:0] psum_carry_o,
    output logic        psum_nan_o,
    output logic [PACC_IDX_WIDTH-1:0] paccidx_o,
    output logic        accum_o
);

    initial begin
        if (ACC_WIDTH <= 40) begin
            $error("ACC_WIDTH must be wider than the largest aligned FP8 product");
        end
        if (ACC_FRAC_BITS < 18) begin
            $error("ACC_FRAC_BITS must be at least 18 for exact E4M3 products");
        end
        if (FDOT_CSA_WIDTH < ACC_WIDTH + 2) begin
            $error("FDOT_CSA_WIDTH must be at least ACC_WIDTH + 2");
        end
        if (PACC_IDX_WIDTH <= 0) begin
            $error("PACC_IDX_WIDTH must be positive");
        end
    end

    typedef struct packed {
        logic              sign;
        logic              is_zero;
        logic              is_nan;
        logic [4:0]        sig;
        logic signed [6:0] exp2;
    } fp8_dec_t;

    function automatic fp8_dec_t decode_e4m3(input logic [7:0] x);
        logic [3:0] exp_field;
        logic [2:0] frac_field;
        fp8_dec_t   dec;
        begin
            exp_field  = x[6:3];
            frac_field = x[2:0];

            dec.sign    = x[7];
            dec.is_zero = 1'b0;
            dec.is_nan  = 1'b0;
            dec.sig     = 5'd0;
            dec.exp2    = 7'sd0;

            if (exp_field == 4'd0) begin
                dec.is_zero = (frac_field == 3'd0);
                dec.sig     = {2'b00, frac_field};
                dec.exp2    = -7'sd9;
            end else begin
                dec.is_nan = (exp_field == 4'hf) && (frac_field == 3'h7);
                dec.sig    = {1'b0, 1'b1, frac_field};
                dec.exp2   = $signed({3'b000, exp_field}) - 7'sd10;
            end

            return dec;
        end
    endfunction

    function automatic logic signed [ACC_WIDTH-1:0] align_product(
        input logic              prod_sign,
        input logic [9:0]        prod_sig,
        input logic signed [7:0] prod_exp2
    );
        int shift_amt;
        logic signed [ACC_WIDTH-1:0] magnitude;
        begin
            shift_amt = int'(prod_exp2) + ACC_FRAC_BITS;
            magnitude = '0;

            if (prod_sig != 10'd0) begin
                if ((shift_amt >= 0) && (shift_amt < ACC_WIDTH)) begin
                    magnitude = $signed({{(ACC_WIDTH-10){1'b0}}, prod_sig}) <<< shift_amt;
                end else if (shift_amt >= ACC_WIDTH) begin
                    magnitude = {1'b0, {(ACC_WIDTH-1){1'b1}}};
                end
            end

            return prod_sign ? -magnitude : magnitude;
        end
    endfunction

    function automatic logic signed [FDOT_CSA_WIDTH-1:0] csa_sum3(
        input logic signed [FDOT_CSA_WIDTH-1:0] x,
        input logic signed [FDOT_CSA_WIDTH-1:0] y,
        input logic signed [FDOT_CSA_WIDTH-1:0] z
    );
        begin
            return x ^ y ^ z;
        end
    endfunction

    function automatic logic signed [FDOT_CSA_WIDTH-1:0] csa_carry3(
        input logic signed [FDOT_CSA_WIDTH-1:0] x,
        input logic signed [FDOT_CSA_WIDTH-1:0] y,
        input logic signed [FDOT_CSA_WIDTH-1:0] z
    );
        logic [FDOT_CSA_WIDTH-1:0] carry_bits;
        begin
            carry_bits = (x & y) | (x & z) | (y & z);
            return $signed({carry_bits[FDOT_CSA_WIDTH-2:0], 1'b0});
        end
    endfunction

    logic        m1_valid;
    logic        m1_first;
    logic        m1_last;
    logic [PACC_IDX_WIDTH-1:0] m1_paccidx;
    logic        m1_accum;
    fp8_dec_t    m1_a;
    fp8_dec_t    m1_b;

    logic        m2_valid;
    logic        m2_first;
    logic        m2_last;
    logic [PACC_IDX_WIDTH-1:0] m2_paccidx;
    logic        m2_accum;
    logic        m2_nan;
    logic signed [ACC_WIDTH-1:0] m2_product;

    logic [9:0]        m1_prod_sig;
    logic signed [7:0] m1_prod_exp2;

    always_comb begin
        m1_prod_sig  = m1_a.sig * m1_b.sig;
        m1_prod_exp2 = m1_a.exp2 + m1_b.exp2;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m1_valid   <= 1'b0;
            m1_first   <= 1'b0;
            m1_last    <= 1'b0;
            m1_paccidx <= '0;
            m1_accum   <= 1'b0;
            m1_a       <= '0;
            m1_b       <= '0;

            m2_valid   <= 1'b0;
            m2_first   <= 1'b0;
            m2_last    <= 1'b0;
            m2_paccidx <= '0;
            m2_accum   <= 1'b0;
            m2_nan     <= 1'b0;
            m2_product <= '0;
        end else begin
            m1_valid   <= valid_i;
            m1_first   <= valid_i && first_i;
            m1_last    <= valid_i && last_i;
            m1_paccidx <= paccidx_i;
            m1_accum   <= accum_i;
            m1_a       <= decode_e4m3(a_i);
            m1_b       <= decode_e4m3(b_i);

            m2_valid   <= m1_valid;
            m2_first   <= m1_first;
            m2_last    <= m1_last;
            m2_paccidx <= m1_paccidx;
            m2_accum   <= m1_accum;
            m2_nan     <= m1_a.is_nan || m1_b.is_nan;
            m2_product <= ((m1_a.is_zero || m1_b.is_zero || m1_a.is_nan || m1_b.is_nan) ?
                '0 :
                align_product(m1_a.sign ^ m1_b.sign, m1_prod_sig, m1_prod_exp2));
        end
    end

    logic signed [FDOT_CSA_WIDTH-1:0] csa_sum_q;
    logic signed [FDOT_CSA_WIDTH-1:0] csa_carry_q;
    logic                             csa_nan_q;

    logic signed [FDOT_CSA_WIDTH-1:0] csa_x;
    logic signed [FDOT_CSA_WIDTH-1:0] csa_y;
    logic signed [FDOT_CSA_WIDTH-1:0] csa_z;
    logic signed [FDOT_CSA_WIDTH-1:0] csa_sum_next;
    logic signed [FDOT_CSA_WIDTH-1:0] csa_carry_next;
    logic                             csa_nan_next;

    always_comb begin
        csa_x = m2_first ? '0 : csa_sum_q;
        csa_y = m2_first ? '0 : csa_carry_q;
        csa_z = {{(FDOT_CSA_WIDTH-ACC_WIDTH){m2_product[ACC_WIDTH-1]}}, m2_product};
        csa_sum_next   = csa_sum3(csa_x, csa_y, csa_z);
        csa_carry_next = csa_carry3(csa_x, csa_y, csa_z);
        csa_nan_next   = (m2_first ? 1'b0 : csa_nan_q) | m2_nan;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csa_sum_q   <= '0;
            csa_carry_q <= '0;
            csa_nan_q   <= 1'b0;

            valid_o      <= 1'b0;
            psum_sum_o   <= '0;
            psum_carry_o <= '0;
            psum_nan_o   <= 1'b0;
            paccidx_o    <= '0;
            accum_o      <= 1'b0;
        end else begin
            valid_o <= m2_valid && m2_last;

            if (m2_valid) begin
                csa_sum_q   <= csa_sum_next;
                csa_carry_q <= csa_carry_next;
                csa_nan_q   <= csa_nan_next;
            end

            if (m2_valid && m2_last) begin
                psum_sum_o   <= csa_sum_next;
                psum_carry_o <= csa_carry_next;
                psum_nan_o   <= csa_nan_next;
                paccidx_o    <= m2_paccidx;
                accum_o      <= m2_accum;
            end else begin
                psum_sum_o   <= '0;
                psum_carry_o <= '0;
                psum_nan_o   <= 1'b0;
                paccidx_o    <= '0;
                accum_o      <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
