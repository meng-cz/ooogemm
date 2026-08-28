// Top-level integration for new_static_uopparse.
// The parser has independent LOAD/GEMM/OUTPUT streams; this top connects
// each stream directly to its execution unit.  GEMM uses a fully pipelined
// parser-capture / SA-allocation-and-buffer-read / operand-submit path.
`default_nettype none

module top_new_static #(
    parameter int SA_WIDTH = 32,
    parameter int SUBTILE_K = 32,
    parameter int LANE_NUM = 4,
    parameter int ABUF_SIZE = 64,
    parameter int BBUF_SIZE = 64,
    parameter int PACC_NUM = 16,
    parameter int ADDR_WIDTH = 32,
    parameter int DIM_WIDTH = 16,
    parameter int STORE_ROWS_PER_CYCLE = 1,
    parameter int LOAD_DATA_WIDTH = 1024,
    parameter int LANE_IDX_WIDTH = (LANE_NUM <= 1) ? 1 : $clog2(LANE_NUM),
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ROW8_WIDTH = SUBTILE_K * 8,
    parameter int LOAD_BUS_ID_WIDTH =
        ((SA_WIDTH * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)) <= 1) ? 1 :
        $clog2(SA_WIDTH * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)),
    parameter int ROW32_WIDTH = SA_WIDTH * 32,
    parameter int LOAD_ROWS_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH + 1),
    parameter int STORE_MEM_DATA_WIDTH =
        ROW32_WIDTH * STORE_ROWS_PER_CYCLE,
    parameter int GEMM_INSTID_WIDTH = 16,
    parameter int COUNT_WIDTH = 16,
    parameter int BLOCKSEL_UNROLL_NUM = 1,
    parameter int BLOCK_M_WIDTH = ((ABUF_SIZE / 2) <= 1) ? 1 : $clog2((ABUF_SIZE / 2) + 1),
    parameter int BLOCK_N_WIDTH = ((BBUF_SIZE / 2) <= 1) ? 1 : $clog2((BBUF_SIZE / 2) + 1)
) (
    input logic clk,
    input logic rst_n,
    input logic cmd_valid_i,
    output logic cmd_ready_o,
    input logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input logic [DIM_WIDTH-1:0] cmd_m_i,
    input logic [DIM_WIDTH-1:0] cmd_n_i,
    input logic [DIM_WIDTH-1:0] cmd_k_i,
    input logic [DIM_WIDTH-1:0] cmd_batch_i,
    output logic load_mem_req_valid_o,
    input logic load_mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] load_mem_req_addr_o,
    output logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_req_id_o,
    input logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_rsp_id_i,
    input logic [LOAD_DATA_WIDTH-1:0] load_mem_rsp_data_i,
    output logic store_mem_wr_valid_o,
    input logic store_mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
    output logic [STORE_MEM_DATA_WIDTH-1:0] store_mem_wr_data_o,
    output logic cmd_done_valid_o
);
    import uopparse_pkg::*;

    initial begin
        if (STORE_ROWS_PER_CYCLE <= 0 ||
            STORE_ROWS_PER_CYCLE > SA_WIDTH) begin
            $error("STORE_ROWS_PER_CYCLE must be in [1, SA_WIDTH]");
        end
        if ((SA_WIDTH % STORE_ROWS_PER_CYCLE) != 0) begin
            $error("SA_WIDTH must be divisible by STORE_ROWS_PER_CYCLE");
        end
        if (LOAD_DATA_WIDTH <= 0 ||
            (LOAD_DATA_WIDTH & (LOAD_DATA_WIDTH - 1)) != 0) begin
            $error("LOAD_DATA_WIDTH must be a positive power of two");
        end
    end

    logic blocksel_cmd_ready, blocksel_gemm_valid, blocksel_gemm_ready;
    logic [BLOCK_M_WIDTH-1:0] blocksel_block_m;
    logic [BLOCK_N_WIDTH-1:0] blocksel_block_n;
    logic [ADDR_WIDTH-1:0] blocksel_a_base, blocksel_b_base, blocksel_c_base;
    logic [DIM_WIDTH-1:0] blocksel_m, blocksel_n, blocksel_k, blocksel_batch;
    logic parser_cmd_ready;

    blocksel #(
        .SA_WIDTH(SA_WIDTH),
        .LOGIC_ABUF_SIZE(ABUF_SIZE / 2),
        .LOGIC_BBUF_SIZE(BBUF_SIZE / 2),
        .LOGIC_ACC_NUM(PACC_NUM / 2),
        .ADDR_WIDTH(ADDR_WIDTH), .DIM_WIDTH(DIM_WIDTH),
        .UNROLL_NUM(BLOCKSEL_UNROLL_NUM),
        .BLOCK_M_WIDTH(BLOCK_M_WIDTH), .BLOCK_N_WIDTH(BLOCK_N_WIDTH)
    ) block_selector (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i), .cmd_ready_o(blocksel_cmd_ready),
        .cmd_a_base_i(cmd_a_base_i), .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i), .cmd_m_i(cmd_m_i), .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i), .cmd_batch_i(cmd_batch_i),
        .gemm_valid_o(blocksel_gemm_valid), .gemm_ready_i(blocksel_gemm_ready),
        .gemm_a_base_o(blocksel_a_base), .gemm_b_base_o(blocksel_b_base),
        .gemm_c_base_o(blocksel_c_base), .gemm_m_o(blocksel_m),
        .gemm_n_o(blocksel_n), .gemm_k_o(blocksel_k),
        .gemm_batch_o(blocksel_batch), .block_m_o(blocksel_block_m),
        .block_n_o(blocksel_block_n)
    );

    assign cmd_ready_o = blocksel_cmd_ready;

    logic load_valid, load_ready, load_is_b, load_group;
    logic [ADDR_WIDTH-1:0] load_addr;
    logic [ABUF_IDX_WIDTH-1:0] load_abufidx;
    logic [BBUF_IDX_WIDTH-1:0] load_bbufidx;
    logic [LOAD_ROWS_WIDTH-1:0] load_valid_rows;
    logic load_done;

    logic gemm_valid, gemm_ready, gemm_group;
    logic [ABUF_IDX_WIDTH-1:0] gemm_abufidx;
    logic [BBUF_IDX_WIDTH-1:0] gemm_bbufidx;
    logic [PACC_IDX_WIDTH-1:0] gemm_paccidx;
    logic gemm_accum;
    logic gemm_done;

    logic output_valid, output_ready, output_group;
    logic [ADDR_WIDTH-1:0] output_addr;
    logic [PACC_IDX_WIDTH-1:0] output_paccidx;
    logic output_done;

    new_static_uopparse #(
        .SA_WIDTH(SA_WIDTH), .SUBTILE_K(SUBTILE_K), .ABUF_SIZE(ABUF_SIZE),
        .BBUF_SIZE(BBUF_SIZE), .PACC_NUM(PACC_NUM), .ADDR_WIDTH(ADDR_WIDTH),
        .DIM_WIDTH(DIM_WIDTH), .ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),
        .BBUF_IDX_WIDTH(BBUF_IDX_WIDTH), .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH), .BLOCK_M_WIDTH(BLOCK_M_WIDTH),
        .BLOCK_N_WIDTH(BLOCK_N_WIDTH), .COUNT_WIDTH(COUNT_WIDTH)
    ) parser (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid_i(blocksel_gemm_valid), .cmd_ready_o(parser_cmd_ready),
        .cmd_a_base_i(blocksel_a_base), .cmd_b_base_i(blocksel_b_base),
        .cmd_c_base_i(blocksel_c_base), .cmd_m_i(blocksel_m), .cmd_n_i(blocksel_n),
        .cmd_k_i(blocksel_k), .cmd_batch_i(blocksel_batch),
        .block_m_i(blocksel_block_m), .block_n_i(blocksel_block_n),
        .load_valid_o(load_valid), .load_ready_i(load_ready),
        .load_is_b_o(load_is_b), .load_group_o(load_group),
        .load_addr_o(load_addr), .load_abufidx_o(load_abufidx),
        .load_bbufidx_o(load_bbufidx), .load_valid_rows_o(load_valid_rows),
        .gemm_valid_o(gemm_valid), .gemm_ready_i(gemm_ready),
        .gemm_group_o(gemm_group), .gemm_abufidx_o(gemm_abufidx),
        .gemm_bbufidx_o(gemm_bbufidx), .gemm_paccidx_o(gemm_paccidx),
        .gemm_accum_o(gemm_accum),
        .output_valid_o(output_valid), .output_ready_i(output_ready),
        .output_group_o(output_group), .output_addr_o(output_addr),
        .output_paccidx_o(output_paccidx),
        .load_done_valid_i(load_done), .gemm_done_valid_i(gemm_done),
        .output_done_valid_i(output_done), .cmd_done_valid_o(cmd_done_valid_o)
    );
    assign blocksel_gemm_ready = parser_cmd_ready;

    logic abuf_wr_valid, bbuf_wr_valid;
    logic [ABUF_IDX_WIDTH-1:0] abuf_wr_idx;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_wr_idx;
    logic [SA_WIDTH-1:0] abuf_wr_bank_en, bbuf_wr_bank_en;
    logic [ROW8_WIDTH-1:0] abuf_wr_data [SA_WIDTH];
    logic [ROW8_WIDTH-1:0] bbuf_wr_data [SA_WIDTH];
    logic abuf_ready_valid, bbuf_ready_valid;
    logic [ABUF_IDX_WIDTH-1:0] abuf_ready_idx;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_ready_idx;

    assign load_done = abuf_ready_valid | bbuf_ready_valid;

    loadunit #(
        .SA_WIDTH(SA_WIDTH), .SUBTILE_K(SUBTILE_K), .ABUF_SIZE(ABUF_SIZE),
        .BBUF_SIZE(BBUF_SIZE), .ADDR_WIDTH(ADDR_WIDTH),
        .ABUF_IDX_WIDTH(ABUF_IDX_WIDTH), .BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),
        .BUS_ID_WIDTH(LOAD_BUS_ID_WIDTH), .ROWS_LEFT_WIDTH(LOAD_ROWS_WIDTH),
        .ROW_DATA_WIDTH(ROW8_WIDTH), .LOAD_DATA_WIDTH(LOAD_DATA_WIDTH)
    ) load_unit (
        .clk(clk), .rst_n(rst_n), .uop_valid_i(load_valid),
        .uop_ready_o(load_ready), .uop_is_b_i(load_is_b), .uop_addr_i(load_addr),
        .uop_abufidx_i(load_abufidx), .uop_bbufidx_i(load_bbufidx),
        .uop_valid_rows_i(load_valid_rows),
        .mem_req_valid_o(load_mem_req_valid_o), .mem_req_ready_i(load_mem_req_ready_i),
        .mem_req_addr_o(load_mem_req_addr_o), .mem_req_id_o(load_mem_req_id_o),
        .mem_rsp_valid_i(load_mem_rsp_valid_i), .mem_rsp_ready_o(load_mem_rsp_ready_o),
        .mem_rsp_id_i(load_mem_rsp_id_i), .mem_rsp_data_i(load_mem_rsp_data_i),
        .abuf_wr_valid_o(abuf_wr_valid), .abuf_wr_idx_o(abuf_wr_idx),
        .abuf_wr_bank_en_o(abuf_wr_bank_en), .abuf_wr_data_o(abuf_wr_data),
        .bbuf_wr_valid_o(bbuf_wr_valid), .bbuf_wr_idx_o(bbuf_wr_idx),
        .bbuf_wr_bank_en_o(bbuf_wr_bank_en), .bbuf_wr_data_o(bbuf_wr_data),
        .abuf_ready_valid_o(abuf_ready_valid), .abuf_ready_idx_o(abuf_ready_idx),
        .bbuf_ready_valid_o(bbuf_ready_valid), .bbuf_ready_idx_o(bbuf_ready_idx)
    );

    logic abuf_rd_valid, bbuf_rd_valid;
    logic [ABUF_IDX_WIDTH-1:0] abuf_rd_idx;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_rd_idx;
    logic abuf_rd_data_valid, bbuf_rd_data_valid;
    logic [ROW8_WIDTH-1:0] abuf_rd_data [SA_WIDTH];
    logic [ROW8_WIDTH-1:0] bbuf_rd_data [SA_WIDTH];

    oprandbuf #(.BUF_SIZE(ABUF_SIZE), .SA_WIDTH(SA_WIDTH), .SUBTILE_K(SUBTILE_K),
        .BUF_IDX_WIDTH(ABUF_IDX_WIDTH), .BANK_DATA_WIDTH(ROW8_WIDTH)) abuf (
        .clk(clk), .rst_n(rst_n), .wr_valid_i(abuf_wr_valid), .wr_idx_i(abuf_wr_idx),
        .wr_bank_en_i(abuf_wr_bank_en), .wr_data_i(abuf_wr_data),
        .rd_valid_i(abuf_rd_valid), .rd_idx_i(abuf_rd_idx),
        .rd_valid_o(abuf_rd_data_valid),
        .rd_data_o(abuf_rd_data));
    oprandbuf #(.BUF_SIZE(BBUF_SIZE), .SA_WIDTH(SA_WIDTH), .SUBTILE_K(SUBTILE_K),
        .BUF_IDX_WIDTH(BBUF_IDX_WIDTH), .BANK_DATA_WIDTH(ROW8_WIDTH)) bbuf (
        .clk(clk), .rst_n(rst_n), .wr_valid_i(bbuf_wr_valid), .wr_idx_i(bbuf_wr_idx),
        .wr_bank_en_i(bbuf_wr_bank_en), .wr_data_i(bbuf_wr_data),
        .rd_valid_i(bbuf_rd_valid), .rd_idx_i(bbuf_rd_idx),
        .rd_valid_o(bbuf_rd_data_valid),
        .rd_data_o(bbuf_rd_data));

    // GEMM issue pipeline:
    //   S1 captures one parser uop and isolates parser ready from SA ready.
    //   S2 handshakes with SA, allocates a lane, and starts synchronous A/B reads.
    //   S3 submits the returned A/B matrices to the allocated SA lane.
    logic gemm_s1_valid_q;
    logic [ABUF_IDX_WIDTH-1:0] gemm_s1_abuf_q;
    logic [BBUF_IDX_WIDTH-1:0] gemm_s1_bbuf_q;
    logic [PACC_IDX_WIDTH-1:0] gemm_s1_pacc_q;
    logic gemm_s1_accum_q;
    logic gemm_s3_valid_q;
    logic [LANE_IDX_WIDTH-1:0] gemm_s3_lane_q;
    logic [GEMM_INSTID_WIDTH-1:0] gemm_next_instid_q;
    logic sa_gemm_valid, sa_gemm_ready;
    logic [LANE_IDX_WIDTH-1:0] sa_alloc_lane;
    logic [GEMM_INSTID_WIDTH-1:0] sa_finish_id;
    logic sa_finish_valid;
    logic sa_ain_valid, sa_bin_valid;
    logic [ROW8_WIDTH-1:0] sa_ain_data [SA_WIDTH];
    logic [ROW8_WIDTH-1:0] sa_bin_data [SA_WIDTH];
    logic sa_getacc_ready, sa_getacc_data_valid;
    logic [STORE_MEM_DATA_WIDTH-1:0] sa_getacc_data;

    wire sa_gemm_fire = sa_gemm_valid && sa_gemm_ready;
    assign gemm_ready = !gemm_s1_valid_q || sa_gemm_ready;
    assign sa_gemm_valid = gemm_s1_valid_q;
    assign sa_ain_valid = gemm_s3_valid_q && abuf_rd_data_valid;
    assign sa_bin_valid = gemm_s3_valid_q && bbuf_rd_data_valid;
    assign abuf_rd_valid = sa_gemm_fire;
    assign bbuf_rd_valid = sa_gemm_fire;
    assign abuf_rd_idx = gemm_s1_abuf_q;
    assign bbuf_rd_idx = gemm_s1_bbuf_q;
    assign gemm_done = sa_finish_valid;

    always_comb begin
        for (int i = 0; i < SA_WIDTH; i++) begin
            sa_ain_data[i] = abuf_rd_data[i];
            sa_bin_data[i] = bbuf_rd_data[i];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gemm_s1_valid_q <= 1'b0;
            gemm_s1_abuf_q <= '0;
            gemm_s1_bbuf_q <= '0;
            gemm_s1_pacc_q <= '0;
            gemm_s1_accum_q <= 1'b0;
            gemm_s3_valid_q <= 1'b0;
            gemm_s3_lane_q <= '0;
            gemm_next_instid_q <= '0;
        end else begin
            gemm_s3_valid_q <= sa_gemm_fire;
            if (sa_gemm_fire) begin
                gemm_s3_lane_q <= sa_alloc_lane;
                gemm_next_instid_q <= gemm_next_instid_q + 1'b1;
            end

            if (gemm_ready) begin
                gemm_s1_valid_q <= gemm_valid;
                if (gemm_valid) begin
                    gemm_s1_abuf_q <= gemm_abufidx;
                    gemm_s1_bbuf_q <= gemm_bbufidx;
                    gemm_s1_pacc_q <= gemm_paccidx;
                    gemm_s1_accum_q <= gemm_accum;
                end
            end
        end
    end

    logic store_getacc_valid;
    logic [PACC_IDX_WIDTH-1:0] store_getacc_idx;
    storeunit #(.SA_WIDTH(SA_WIDTH), .PACC_NUM(PACC_NUM), .ADDR_WIDTH(ADDR_WIDTH),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH), .ROW_DATA_WIDTH(ROW32_WIDTH),
        .ROWS_PER_CYCLE(STORE_ROWS_PER_CYCLE),
        .MEM_DATA_WIDTH(STORE_MEM_DATA_WIDTH)) store_unit (
        .clk(clk), .rst_n(rst_n), .uop_valid_i(output_valid), .uop_ready_o(output_ready),
        .uop_addr_i(output_addr), .uop_paccidx_i(output_paccidx),
        .sa_getacc_valid_o(store_getacc_valid), .sa_getacc_ready_i(sa_getacc_ready),
        .sa_getacc_idx_o(store_getacc_idx), .sa_getacc_data_valid_i(sa_getacc_data_valid),
        .sa_getacc_data_i(sa_getacc_data), .mem_wr_valid_o(store_mem_wr_valid_o),
        .mem_wr_ready_i(store_mem_wr_ready_i), .mem_wr_addr_o(store_mem_wr_addr_o),
        .mem_wr_data_o(store_mem_wr_data_o), .done_valid_o(output_done));

    sa #(.SA_WIDTH(SA_WIDTH), .LANE_NUM(LANE_NUM), .SUBTILE_K(SUBTILE_K),
        .PACC_NUM(PACC_NUM), .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH),
        .GETACC_ROWS_PER_CYCLE(STORE_ROWS_PER_CYCLE)) sa_impl (
        .clk(clk), .rst_n(rst_n),
        .ain_valid(sa_ain_valid), .ain_data(sa_ain_data), .ain_laneidx(gemm_s3_lane_q),
        .bin_valid(sa_bin_valid), .bin_data(sa_bin_data), .bin_laneidx(gemm_s3_lane_q),
        .gemm_valid(sa_gemm_valid), .gemm_ready(sa_gemm_ready),
        .gemm_alloc_lane(sa_alloc_lane), .gemm_instid(gemm_next_instid_q),
        .gemm_paccidx(gemm_s1_pacc_q), .gemm_accum(gemm_s1_accum_q),
        .gemm_finish(sa_finish_valid), .gemm_finish_instid(sa_finish_id),
        .getacc_valid(store_getacc_valid), .getacc_ready(sa_getacc_ready),
        .getacc_idx(store_getacc_idx), .getacc_data_valid(sa_getacc_data_valid),
        .getacc_data(sa_getacc_data));

endmodule

`default_nettype wire
