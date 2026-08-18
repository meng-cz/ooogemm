// FP8 E4M3 vector dot product accumulator.
//
// Input protocol:
//   - Every cycle with valid_i=1 is accepted; there is no back-pressure.
//   - first_i marks the first product of one dot product.
//   - last_i marks the final product of one dot product.
//   - paccidx_i and accum_i are sampled with valid_i && last_i and
//     appear with the corresponding valid_o pseudo-float result.
//   - Back-to-back dot products are supported.
//
// Arithmetic:
//   - FP8 is interpreted as E4M3FN: sign, 4-bit exponent with bias 7,
//     3-bit fraction, and only exp=15/fraction=7 is NaN.
//   - Products are formed exactly and aligned into a two's-complement
//     fixed-point accumulator with ACC_FRAC_BITS fractional bits.
//   - Two accumulator lanes are used alternately so one product can be
//     accumulated every cycle.
//   - The merged exact fixed-point sum is converted to the same pseudo
//     floating-point format used by paccreg: value = psum_sig_o * 2^psum_exp_o.

`default_nettype none

package fdot8e4m3_pkg;

    localparam int MUL_LAST_TO_SUM_STAGES = 2;
    localparam int PSEUDO_PACK_STAGES     = 1;
    localparam int LAST_TO_OUT_LATENCY    =
        MUL_LAST_TO_SUM_STAGES + PSEUDO_PACK_STAGES;
    
endpackage

module fdot8e4m3 #(
    parameter int ACC_WIDTH     = 96,
    parameter int ACC_FRAC_BITS = 18,
    parameter int PACC_IDX_WIDTH = 1,
    parameter int PACC_EXP_WIDTH = 10,
    parameter int PACC_SIG_WIDTH = 40
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
    output logic signed [PACC_EXP_WIDTH-1:0] psum_exp_o,
    output logic signed [PACC_SIG_WIDTH-1:0] psum_sig_o,
    output logic [PACC_IDX_WIDTH-1:0] paccidx_o,
    output logic        accum_o
);

    import fdot8e4m3_pkg::*;

    initial begin
        if (ACC_WIDTH <= 40) begin
            $error("ACC_WIDTH must be wider than the largest aligned FP8 product");
        end
        if (ACC_FRAC_BITS < 18) begin
            $error("ACC_FRAC_BITS must be at least 18 for exact E4M3 products");
        end
        if (PACC_IDX_WIDTH <= 0) begin
            $error("PACC_IDX_WIDTH must be positive");
        end
        if (PACC_EXP_WIDTH < 10) begin
            $error("PACC_EXP_WIDTH must be at least 10");
        end
        if ((PACC_SIG_WIDTH < 32) || (PACC_SIG_WIDTH > 48)) begin
            $error("PACC_SIG_WIDTH must be in the 32..48 bit range");
        end
    end

    localparam logic signed [PACC_EXP_WIDTH-1:0] PSEUDO_NAN_EXP =
        $signed({1'b0, {(PACC_EXP_WIDTH-1){1'b1}}});

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

    function automatic int find_msb(input logic [ACC_WIDTH-1:0] value);
        int msb;
        begin
            msb = 0;
            for (int i = 0; i < ACC_WIDTH; i++) begin
                if (value[i]) begin
                    msb = i;
                end
            end
            return msb;
        end
    endfunction

    function automatic logic acc_bit(
        input logic [ACC_WIDTH-1:0] value,
        input int                   index
    );
        begin
            if ((index >= 0) && (index < ACC_WIDTH)) begin
                return value[index];
            end
            return 1'b0;
        end
    endfunction

    function automatic logic signed [PACC_EXP_WIDTH-1:0] pseudo_exp_field(input int msb);
        int exp_value;
        begin
            exp_value = msb - ACC_FRAC_BITS - (PACC_SIG_WIDTH - 2);
            return exp_value[PACC_EXP_WIDTH-1:0];
        end
    endfunction

    function automatic logic signed [PACC_SIG_WIDTH-1:0] normalized_pseudo_sig(
        input logic [ACC_WIDTH-1:0] value,
        input int                   msb,
        input logic                 sign
    );
        logic [PACC_SIG_WIDTH-2:0] mag;
        logic signed [PACC_SIG_WIDTH-1:0] pos_sig;
        int          src_index;
        begin
            mag = '0;
            for (int i = 0; i < PACC_SIG_WIDTH - 1; i++) begin
                src_index = msb - (PACC_SIG_WIDTH - 2) + i;
                mag[i] = acc_bit(value, src_index);
            end
            pos_sig = $signed({1'b0, mag});
            return sign ? -pos_sig : pos_sig;
        end
    endfunction

    logic next_input_lane;

    logic        m1_valid;
    logic        m1_first;
    logic        m1_last;
    logic        m1_lane;
    logic [PACC_IDX_WIDTH-1:0] m1_paccidx;
    logic        m1_accum;
    fp8_dec_t    m1_a;
    fp8_dec_t    m1_b;

    logic        m2_valid;
    logic        m2_first;
    logic        m2_last;
    logic        m2_lane;
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
            next_input_lane <= 1'b0;

            m1_valid <= 1'b0;
            m1_first <= 1'b0;
            m1_last  <= 1'b0;
            m1_lane  <= 1'b0;
            m1_paccidx <= '0;
            m1_accum <= 1'b0;
            m1_a     <= '0;
            m1_b     <= '0;

            m2_valid   <= 1'b0;
            m2_first   <= 1'b0;
            m2_last    <= 1'b0;
            m2_lane    <= 1'b0;
            m2_paccidx <= '0;
            m2_accum   <= 1'b0;
            m2_nan     <= 1'b0;
            m2_product <= '0;
        end else begin
            m1_valid <= valid_i;
            m1_first <= valid_i && first_i;
            m1_last  <= valid_i && last_i;
            m1_lane  <= first_i ? 1'b0 : next_input_lane;
            m1_paccidx <= paccidx_i;
            m1_accum <= accum_i;
            m1_a     <= decode_e4m3(a_i);
            m1_b     <= decode_e4m3(b_i);

            if (valid_i) begin
                next_input_lane <= first_i ? 1'b1 : ~next_input_lane;
            end

            m2_valid <= m1_valid;
            m2_first <= m1_first;
            m2_last  <= m1_last;
            m2_lane  <= m1_lane;
            m2_paccidx <= m1_paccidx;
            m2_accum   <= m1_accum;
            m2_nan   <= m1_a.is_nan || m1_b.is_nan;
            m2_product <= ((m1_a.is_zero || m1_b.is_zero || m1_a.is_nan || m1_b.is_nan) ?
                '0 :
                align_product(m1_a.sign ^ m1_b.sign, m1_prod_sig, m1_prod_exp2));
        end
    end

    logic signed [ACC_WIDTH-1:0] acc_lane [2];
    logic                        acc_nan;

    logic signed [ACC_WIDTH-1:0] acc_selected_base;
    logic signed [ACC_WIDTH-1:0] acc_selected_next;
    logic signed [ACC_WIDTH-1:0] acc_other_value;
    logic signed [ACC_WIDTH-1:0] merged_sum_next;
    logic                        merged_nan_next;

    always_comb begin
        acc_selected_base = m2_first ? '0 : acc_lane[m2_lane];
        acc_selected_next = acc_selected_base + m2_product;
        acc_other_value   = m2_first ? '0 : acc_lane[~m2_lane];
        merged_sum_next   = acc_selected_next + acc_other_value;
        merged_nan_next   = (m2_first ? 1'b0 : acc_nan) | m2_nan;
    end

    logic                        sum_valid;
    logic signed [ACC_WIDTH-1:0] sum_exact;
    logic                        sum_nan;
    logic [PACC_IDX_WIDTH-1:0]   sum_paccidx;
    logic                        sum_accum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_lane[0] <= '0;
            acc_lane[1] <= '0;
            acc_nan     <= 1'b0;

            sum_valid <= 1'b0;
            sum_exact <= '0;
            sum_nan   <= 1'b0;
            sum_paccidx <= '0;
            sum_accum   <= 1'b0;
        end else begin
            sum_valid <= m2_valid && m2_last;

            if (m2_valid) begin
                if (m2_first) begin
                    acc_lane[0] <= '0;
                    acc_lane[1] <= '0;
                end

                acc_lane[m2_lane] <= acc_selected_next;
                acc_nan           <= merged_nan_next;
            end

            if (m2_valid && m2_last) begin
                sum_exact <= merged_sum_next;
                sum_nan   <= merged_nan_next;
                sum_paccidx <= m2_paccidx;
                sum_accum   <= m2_accum;
            end else begin
                sum_exact <= '0;
                sum_nan   <= 1'b0;
                sum_paccidx <= '0;
                sum_accum   <= 1'b0;
            end
        end
    end

    logic [ACC_WIDTH-1:0] sum_abs_comb;
    int                   sum_msb_comb;

    always_comb begin
        if (sum_exact[ACC_WIDTH-1]) begin
            sum_abs_comb = ~sum_exact + {{(ACC_WIDTH-1){1'b0}}, 1'b1};
        end else begin
            sum_abs_comb = sum_exact;
        end
        sum_msb_comb = find_msb(sum_abs_comb);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o    <= 1'b0;
            psum_exp_o <= '0;
            psum_sig_o <= '0;
            paccidx_o  <= '0;
            accum_o    <= 1'b0;
        end else begin
            valid_o   <= sum_valid;
            paccidx_o <= sum_paccidx;
            accum_o   <= sum_accum;

            if (sum_nan) begin
                psum_exp_o <= PSEUDO_NAN_EXP;
                psum_sig_o <= {{(PACC_SIG_WIDTH-1){1'b0}}, 1'b1};
            end else if (sum_exact == '0) begin
                psum_exp_o <= '0;
                psum_sig_o <= '0;
            end else begin
                psum_exp_o <= pseudo_exp_field(sum_msb_comb);
                psum_sig_o <= normalized_pseudo_sig(
                    sum_abs_comb,
                    sum_msb_comb,
                    sum_exact[ACC_WIDTH-1]
                );
            end
        end
    end

endmodule

`default_nettype wire
