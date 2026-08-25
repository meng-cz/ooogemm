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
//   - The input protocol permits one submission per cycle, but forbids two
//     consecutive submissions to the same paccidx.  A writeback-to-read bypass
//     handles the legal N/N+2 same-paccidx case.
//   - getacc requests produce getacc_o/getacc_data_o after GETACC_PIPE_STAGES.

`default_nettype none

package paccreg_pkg;

    localparam int ACCUM_PIPE_STAGES  = 6;
    localparam int GETACC_PIPE_STAGES = 4;

endpackage

module paccreg #(
    parameter int PACC_NUM       = 16,
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int PACC_EXP_WIDTH = 10,
    parameter int PACC_SIG_WIDTH = 40,
    parameter int FDOT_ACC_WIDTH = 96,
    parameter int FDOT_ACC_FRAC_BITS = 18,
    parameter int FDOT_CSA_WIDTH = FDOT_ACC_WIDTH + 2
) (
    input  logic clk,
    input  logic rst_n,

    input  logic valid_i,
    input  logic signed [FDOT_CSA_WIDTH-1:0] psum_sum_i,
    input  logic signed [FDOT_CSA_WIDTH-1:0] psum_carry_i,
    input  logic psum_nan_i,
    input  logic [PACC_IDX_WIDTH-1:0] paccidx_i,
    input  logic accum_i,

    input  logic getacc_i,
    input  logic [PACC_IDX_WIDTH-1:0] getacc_idx_i,

    output logic getacc_o,
    output logic [31:0] getacc_data_o
);

    import paccreg_pkg::*;

    localparam int FDOT_FIXED_WIDTH = FDOT_CSA_WIDTH + 1;

    initial begin
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
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
        if (FDOT_CSA_WIDTH < FDOT_ACC_WIDTH + 2) begin
            $error("FDOT_CSA_WIDTH must be at least FDOT_ACC_WIDTH + 2");
        end
        if (FDOT_ACC_FRAC_BITS < 18) begin
            $error("FDOT_ACC_FRAC_BITS must be at least 18");
        end
    end

    localparam logic signed [PACC_EXP_WIDTH-1:0] PSEUDO_NAN_EXP =
        $signed({1'b0, {(PACC_EXP_WIDTH-1){1'b1}}});

    typedef struct packed {
        logic signed [PACC_EXP_WIDTH-1:0] exp;
        logic signed [PACC_SIG_WIDTH-1:0] sig;
    } pseudo_t;

    function automatic logic pseudo_is_nan(
        input logic signed [PACC_EXP_WIDTH-1:0] exp,
        input logic signed [PACC_SIG_WIDTH-1:0] sig
    );
        begin
            return (exp == PSEUDO_NAN_EXP) && (sig != '0);
        end
    endfunction

    function automatic pseudo_t pseudo_nan();
        pseudo_t value;
        begin
            value.exp = PSEUDO_NAN_EXP;
            value.sig = {{(PACC_SIG_WIDTH-1){1'b0}}, 1'b1};
            return value;
        end
    endfunction

    function automatic pseudo_t pseudo_zero();
        pseudo_t value;
        begin
            value.exp = '0;
            value.sig = '0;
            return value;
        end
    endfunction

    function automatic logic [PACC_SIG_WIDTH-1:0] sig_abs(
        input logic signed [PACC_SIG_WIDTH-1:0] sig
    );
        begin
            if (sig[PACC_SIG_WIDTH-1]) begin
                return ~sig + {{(PACC_SIG_WIDTH-1){1'b0}}, 1'b1};
            end
            return sig;
        end
    endfunction

    function automatic logic [FDOT_FIXED_WIDTH-1:0] fixed_abs(
        input logic signed [FDOT_FIXED_WIDTH-1:0] value
    );
        begin
            if (value[FDOT_FIXED_WIDTH-1]) begin
                return ~value + {{(FDOT_FIXED_WIDTH-1){1'b0}}, 1'b1};
            end
            return value;
        end
    endfunction

    function automatic logic signed [PACC_EXP_WIDTH-1:0] pseudo_exp_from_int(input int value);
        begin
            return value[PACC_EXP_WIDTH-1:0];
        end
    endfunction

    function automatic logic signed [12:0] fp32_exp_from_int(input int value);
        begin
            return value[12:0];
        end
    endfunction

    function automatic int find_fixed_msb(input logic [FDOT_FIXED_WIDTH-1:0] value);
        int msb;
        begin
            msb = 0;
            for (int i = 0; i < FDOT_FIXED_WIDTH; i++) begin
                if (value[i]) begin
                    msb = i;
                end
            end
            return msb;
        end
    endfunction

    function automatic int find_sig_msb(input logic [PACC_SIG_WIDTH-1:0] value);
        int msb;
        begin
            msb = 0;
            for (int i = 0; i < PACC_SIG_WIDTH; i++) begin
                if (value[i]) begin
                    msb = i;
                end
            end
            return msb;
        end
    endfunction

    function automatic logic fixed_bit(
        input logic [FDOT_FIXED_WIDTH-1:0] value,
        input int                          index
    );
        begin
            if ((index >= 0) && (index < FDOT_FIXED_WIDTH)) begin
                return value[index];
            end
            return 1'b0;
        end
    endfunction

    function automatic logic sig_bit(
        input logic [PACC_SIG_WIDTH-1:0] value,
        input int                        index
    );
        begin
            if ((index >= 0) && (index < PACC_SIG_WIDTH)) begin
                return value[index];
            end
            return 1'b0;
        end
    endfunction

    function automatic logic signed [PACC_SIG_WIDTH-1:0] normalized_fixed_sig(
        input logic [FDOT_FIXED_WIDTH-1:0] value,
        input int                          msb,
        input logic                        sign
    );
        logic [PACC_SIG_WIDTH-2:0] mag;
        logic signed [PACC_SIG_WIDTH-1:0] pos_sig;
        int src_index;
        begin
            mag = '0;
            for (int i = 0; i < PACC_SIG_WIDTH - 1; i++) begin
                src_index = msb - (PACC_SIG_WIDTH - 2) + i;
                mag[i] = fixed_bit(value, src_index);
            end
            pos_sig = $signed({1'b0, mag});
            return sign ? -pos_sig : pos_sig;
        end
    endfunction

    function automatic logic [23:0] normalized_sig24(
        input logic [PACC_SIG_WIDTH-1:0] value,
        input int                        msb
    );
        logic [23:0] sig;
        int          src_index;
        begin
            sig = 24'd0;
            for (int i = 0; i < 24; i++) begin
                src_index = msb - 23 + i;
                sig[i] = sig_bit(value, src_index);
            end
            return sig;
        end
    endfunction

    function automatic logic sticky_below(
        input logic [PACC_SIG_WIDTH-1:0] value,
        input int                        high_index
    );
        logic sticky;
        begin
            sticky = 1'b0;
            for (int i = 0; i < PACC_SIG_WIDTH; i++) begin
                if (i <= high_index) begin
                    sticky |= value[i];
                end
            end
            return sticky;
        end
    endfunction

    function automatic logic signed [PACC_SIG_WIDTH:0] align_abs_to_exp(
        input logic [PACC_SIG_WIDTH-1:0] abs_value,
        input logic                      is_negative,
        input int                        right_shift
    );
        logic [PACC_SIG_WIDTH-1:0] shifted_abs;
        logic signed [PACC_SIG_WIDTH:0] positive;
        begin
            if (right_shift >= PACC_SIG_WIDTH) begin
                shifted_abs = '0;
            end else if (right_shift <= 0) begin
                shifted_abs = abs_value;
            end else begin
                shifted_abs = abs_value >> right_shift;
            end

            positive = $signed({1'b0, shifted_abs});
            return is_negative ? -positive : positive;
        end
    endfunction

    function automatic logic signed [PACC_SIG_WIDTH:0] arithmetic_shift_right_one(
        input logic signed [PACC_SIG_WIDTH:0] value
    );
        begin
            return value >>> 1;
        end
    endfunction

    pseudo_t acc_reg [PACC_NUM];

    logic prev_valid_q;
    logic [PACC_IDX_WIDTH-1:0] prev_paccidx_q;

    logic s1_valid;
    logic signed [FDOT_CSA_WIDTH-1:0] s1_sum;
    logic signed [FDOT_CSA_WIDTH-1:0] s1_carry;
    logic s1_nan;
    logic [PACC_IDX_WIDTH-1:0] s1_idx;
    logic s1_accum;

    logic s2_valid;
    logic signed [FDOT_FIXED_WIDTH-1:0] s2_fixed;
    logic s2_nan;
    logic [PACC_IDX_WIDTH-1:0] s2_idx;
    logic s2_accum;

    logic s3_valid;
    logic signed [PACC_EXP_WIDTH-1:0] s3_exp;
    logic signed [PACC_SIG_WIDTH-1:0] s3_sig;
    logic s3_nan;
    logic [PACC_IDX_WIDTH-1:0] s3_idx;
    logic s3_accum;

    logic s4_valid;
    logic [PACC_IDX_WIDTH-1:0] s4_idx;
    logic s4_direct;
    logic signed [PACC_EXP_WIDTH-1:0] s4_exp;
    logic signed [PACC_SIG_WIDTH-1:0] s4_sig;
    logic [PACC_SIG_WIDTH-1:0] s4_cur_abs;
    logic [PACC_SIG_WIDTH-1:0] s4_in_abs;
    logic s4_cur_neg;
    logic s4_in_neg;
    logic [PACC_EXP_WIDTH:0] s4_cur_shift;
    logic [PACC_EXP_WIDTH:0] s4_in_shift;

    logic s5_valid;
    logic [PACC_IDX_WIDTH-1:0] s5_idx;
    logic s5_direct;
    logic signed [PACC_EXP_WIDTH-1:0] s5_exp;
    logic signed [PACC_SIG_WIDTH-1:0] s5_sig;
    logic signed [PACC_SIG_WIDTH:0] s5_cur_aligned;
    logic signed [PACC_SIG_WIDTH:0] s5_in_aligned;

    logic [FDOT_FIXED_WIDTH-1:0] s2_abs_comb;
    int                         s2_msb_comb;
    logic signed [PACC_EXP_WIDTH-1:0] s2_norm_exp_comb;
    logic signed [PACC_SIG_WIDTH-1:0] s2_norm_sig_comb;

    always_comb begin
        s2_abs_comb = fixed_abs(s2_fixed);
        s2_msb_comb = find_fixed_msb(s2_abs_comb);
        s2_norm_exp_comb = pseudo_exp_from_int(
            s2_msb_comb - FDOT_ACC_FRAC_BITS - (PACC_SIG_WIDTH - 2)
        );
        s2_norm_sig_comb = normalized_fixed_sig(
            s2_abs_comb,
            s2_msb_comb,
            s2_fixed[FDOT_FIXED_WIDTH-1]
        );
    end

    pseudo_t accum_wb_value;
    logic accum_wb_valid;
    logic [PACC_IDX_WIDTH-1:0] accum_wb_idx;

    always_comb begin
        logic signed [PACC_SIG_WIDTH:0] sum;
        logic signed [PACC_SIG_WIDTH:0] shifted_sum;

        sum = s5_cur_aligned + s5_in_aligned;
        shifted_sum = arithmetic_shift_right_one(sum);

        if (s5_direct) begin
            accum_wb_value.exp = s5_exp;
            accum_wb_value.sig = s5_sig;
        end else if (sum == '0) begin
            accum_wb_value = pseudo_zero();
        end else if (sum[PACC_SIG_WIDTH] != sum[PACC_SIG_WIDTH-1]) begin
            accum_wb_value.exp = pseudo_exp_from_int(int'(s5_exp) + 1);
            accum_wb_value.sig = shifted_sum[PACC_SIG_WIDTH-1:0];
        end else begin
            accum_wb_value.exp = s5_exp;
            accum_wb_value.sig = sum[PACC_SIG_WIDTH-1:0];
        end

        accum_wb_valid = s5_valid;
        accum_wb_idx = s5_idx;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PACC_NUM; i++) begin
                acc_reg[i] <= pseudo_zero();
            end

            prev_valid_q <= 1'b0;
            prev_paccidx_q <= '0;

            s1_valid <= 1'b0;
            s1_sum   <= '0;
            s1_carry <= '0;
            s1_nan   <= 1'b0;
            s1_idx   <= '0;
            s1_accum <= 1'b0;

            s2_valid <= 1'b0;
            s2_fixed <= '0;
            s2_nan   <= 1'b0;
            s2_idx   <= '0;
            s2_accum <= 1'b0;

            s3_valid <= 1'b0;
            s3_exp   <= '0;
            s3_sig   <= '0;
            s3_nan   <= 1'b0;
            s3_idx   <= '0;
            s3_accum <= 1'b0;

            s4_valid <= 1'b0;
            s4_idx <= '0;
            s4_direct <= 1'b1;
            s4_exp <= '0;
            s4_sig <= '0;
            s4_cur_abs <= '0;
            s4_in_abs <= '0;
            s4_cur_neg <= 1'b0;
            s4_in_neg <= 1'b0;
            s4_cur_shift <= '0;
            s4_in_shift <= '0;

            s5_valid <= 1'b0;
            s5_idx <= '0;
            s5_direct <= 1'b1;
            s5_exp <= '0;
            s5_sig <= '0;
            s5_cur_aligned <= '0;
            s5_in_aligned <= '0;
        end else begin
            if (valid_i && prev_valid_q && (paccidx_i == prev_paccidx_q)) begin
                $error("paccreg input protocol violation: consecutive submissions to same paccidx");
            end

            prev_valid_q <= valid_i;
            if (valid_i) begin
                prev_paccidx_q <= paccidx_i;
            end

            s1_valid <= valid_i;
            s1_sum   <= psum_sum_i;
            s1_carry <= psum_carry_i;
            s1_nan   <= psum_nan_i;
            s1_idx   <= paccidx_i;
            s1_accum <= accum_i;

            s2_valid <= s1_valid;
            s2_fixed <= $signed({s1_sum[FDOT_CSA_WIDTH-1], s1_sum}) +
                        $signed({s1_carry[FDOT_CSA_WIDTH-1], s1_carry});
            s2_nan   <= s1_nan;
            s2_idx   <= s1_idx;
            s2_accum <= s1_accum;

            s3_valid <= s2_valid;
            s3_idx   <= s2_idx;
            s3_accum <= s2_accum;
            if (s2_nan) begin
                s3_exp <= PSEUDO_NAN_EXP;
                s3_sig <= {{(PACC_SIG_WIDTH-1){1'b0}}, 1'b1};
                s3_nan <= 1'b1;
            end else if (s2_fixed == '0) begin
                s3_exp <= '0;
                s3_sig <= '0;
                s3_nan <= 1'b0;
            end else begin
                s3_exp <= s2_norm_exp_comb;
                s3_sig <= s2_norm_sig_comb;
                s3_nan <= 1'b0;
            end

            s4_valid <= s3_valid;
            s4_idx <= s3_idx;
            s4_direct <= 1'b1;
            s4_exp <= '0;
            s4_sig <= '0;
            s4_cur_abs <= '0;
            s4_in_abs <= '0;
            s4_cur_neg <= 1'b0;
            s4_in_neg <= 1'b0;
            s4_cur_shift <= '0;
            s4_in_shift <= '0;

            if (s3_valid && (int'(s3_idx) < PACC_NUM)) begin
                logic signed [PACC_EXP_WIDTH-1:0] cur_exp;
                logic signed [PACC_SIG_WIDTH-1:0] cur_sig;
                int target_exp;
                int cur_shift;
                int in_shift;

                cur_exp = acc_reg[s3_idx].exp;
                cur_sig = acc_reg[s3_idx].sig;
                if (accum_wb_valid && (accum_wb_idx == s3_idx)) begin
                    cur_exp = accum_wb_value.exp;
                    cur_sig = accum_wb_value.sig;
                end

                if (s3_nan || (s3_accum && pseudo_is_nan(cur_exp, cur_sig))) begin
                    s4_exp <= PSEUDO_NAN_EXP;
                    s4_sig <= {{(PACC_SIG_WIDTH-1){1'b0}}, 1'b1};
                end else if (!s3_accum || (cur_sig == '0)) begin
                    s4_exp <= s3_exp;
                    s4_sig <= s3_sig;
                end else if (s3_sig == '0) begin
                    s4_exp <= cur_exp;
                    s4_sig <= cur_sig;
                end else begin
                    target_exp = (cur_exp >= s3_exp) ? int'(cur_exp) : int'(s3_exp);
                    cur_shift = target_exp - int'(cur_exp);
                    in_shift = target_exp - int'(s3_exp);

                    s4_direct <= 1'b0;
                    s4_exp <= pseudo_exp_from_int(target_exp);
                    s4_cur_abs <= sig_abs(cur_sig);
                    s4_in_abs <= sig_abs(s3_sig);
                    s4_cur_neg <= cur_sig[PACC_SIG_WIDTH-1];
                    s4_in_neg <= s3_sig[PACC_SIG_WIDTH-1];
                    s4_cur_shift <= cur_shift[PACC_EXP_WIDTH:0];
                    s4_in_shift <= in_shift[PACC_EXP_WIDTH:0];
                end
            end

            s5_valid <= s4_valid;
            s5_idx <= s4_idx;
            s5_direct <= s4_direct;
            s5_exp <= s4_exp;
            s5_sig <= s4_sig;
            if (s4_direct) begin
                s5_cur_aligned <= '0;
                s5_in_aligned <= '0;
            end else begin
                s5_cur_aligned <= align_abs_to_exp(s4_cur_abs, s4_cur_neg, int'(s4_cur_shift));
                s5_in_aligned <= align_abs_to_exp(s4_in_abs, s4_in_neg, int'(s4_in_shift));
            end

            if (accum_wb_valid && (int'(accum_wb_idx) < PACC_NUM)) begin
                acc_reg[accum_wb_idx].exp <= accum_wb_value.exp;
                acc_reg[accum_wb_idx].sig <= accum_wb_value.sig;
            end
        end
    end

    logic g1_valid;
    logic signed [PACC_EXP_WIDTH-1:0] g1_exp;
    logic signed [PACC_SIG_WIDTH-1:0] g1_sig;

    logic [PACC_SIG_WIDTH-1:0] g1_abs_comb;
    int                        g1_msb_comb;

    always_comb begin
        g1_abs_comb = sig_abs(g1_sig);
        g1_msb_comb = find_sig_msb(g1_abs_comb);
    end

    logic g2_valid;
    logic g2_nan;
    logic g2_sign;
    logic g2_zero;
    logic signed [12:0] g2_exp_field;
    logic [23:0] g2_sig24;
    logic g2_guard;
    logic g2_round;
    logic g2_sticky;

    logic g3_valid;
    logic g3_nan;
    logic g3_sign;
    logic g3_zero;
    logic signed [12:0] g3_exp_field;
    logic [23:0] g3_sig24;
    logic g3_guard;
    logic g3_round;
    logic g3_sticky;

    logic round_increment;
    logic [24:0] rounded_sig25;
    logic [31:0] g4_data_comb;

    logic g4_valid;
    logic [31:0] g4_data;

    always_comb begin
        round_increment = g3_guard && (g3_round || g3_sticky || g3_sig24[0]);
        rounded_sig25   = {1'b0, g3_sig24} + {{24{1'b0}}, round_increment};

        if (g3_nan) begin
            g4_data_comb = 32'h7fc0_0000;
        end else if (g3_zero) begin
            g4_data_comb = 32'd0;
        end else if (g3_exp_field >= 13'sd255) begin
            g4_data_comb = {g3_sign, 8'hff, 23'd0};
        end else if (g3_exp_field <= 13'sd0) begin
            g4_data_comb = {g3_sign, 31'd0};
        end else if (rounded_sig25[24]) begin
            if ((g3_exp_field + 13'sd1) >= 13'sd255) begin
                g4_data_comb = {g3_sign, 8'hff, 23'd0};
            end else begin
                g4_data_comb = {g3_sign, (g3_exp_field[7:0] + 8'd1), rounded_sig25[23:1]};
            end
        end else begin
            g4_data_comb = {g3_sign, g3_exp_field[7:0], rounded_sig25[22:0]};
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g1_valid <= 1'b0;
            g1_exp   <= '0;
            g1_sig   <= '0;

            g2_valid     <= 1'b0;
            g2_nan       <= 1'b0;
            g2_sign      <= 1'b0;
            g2_zero      <= 1'b1;
            g2_exp_field <= '0;
            g2_sig24     <= '0;
            g2_guard     <= 1'b0;
            g2_round     <= 1'b0;
            g2_sticky    <= 1'b0;

            g3_valid     <= 1'b0;
            g3_nan       <= 1'b0;
            g3_sign      <= 1'b0;
            g3_zero      <= 1'b1;
            g3_exp_field <= '0;
            g3_sig24     <= '0;
            g3_guard     <= 1'b0;
            g3_round     <= 1'b0;
            g3_sticky    <= 1'b0;

            g4_valid <= 1'b0;
            g4_data  <= 32'd0;

            getacc_o      <= 1'b0;
            getacc_data_o <= 32'd0;
        end else begin
            g1_valid <= getacc_i;
            if (getacc_i && (int'(getacc_idx_i) < PACC_NUM)) begin
                g1_exp <= acc_reg[getacc_idx_i].exp;
                g1_sig <= acc_reg[getacc_idx_i].sig;
                if (accum_wb_valid && (accum_wb_idx == getacc_idx_i)) begin
                    g1_exp <= accum_wb_value.exp;
                    g1_sig <= accum_wb_value.sig;
                end
            end else begin
                g1_exp <= '0;
                g1_sig <= '0;
            end

            g2_valid     <= g1_valid;
            g2_nan       <= pseudo_is_nan(g1_exp, g1_sig);
            g2_sign      <= g1_sig[PACC_SIG_WIDTH-1] && (g1_sig != '0);
            g2_zero      <= (g1_sig == '0);
            g2_exp_field <= fp32_exp_from_int(int'(g1_exp) + g1_msb_comb + 127);
            g2_sig24     <= normalized_sig24(g1_abs_comb, g1_msb_comb);
            g2_guard     <= sig_bit(g1_abs_comb, g1_msb_comb - 24);
            g2_round     <= sig_bit(g1_abs_comb, g1_msb_comb - 25);
            g2_sticky    <= sticky_below(g1_abs_comb, g1_msb_comb - 26);

            g3_valid     <= g2_valid;
            g3_nan       <= g2_nan;
            g3_sign      <= g2_sign;
            g3_zero      <= g2_zero;
            g3_exp_field <= g2_exp_field;
            g3_sig24     <= g2_sig24;
            g3_guard     <= g2_guard;
            g3_round     <= g2_round;
            g3_sticky    <= g2_sticky;

            g4_valid <= g3_valid;
            g4_data <= g4_data_comb;

            getacc_o <= g4_valid;
            getacc_data_o <= g4_data;
        end
    end

endmodule

`default_nettype wire
