// Static GEMM top-level integration.
//
// The top wires together the static uop parser, a strict in-order uop
// scheduler, A/B operand buffers, load/store units, and the systolic array.
//
// Scheduler timing:
//   - static_uopparse emits at most one uop per cycle into a small FIFO.
//   - The scheduler only examines the FIFO head, preserving program order.
//   - LOAD, GEMM, and OUTPUT uops are retired as soon as their target unit
//     accepts them. Their long-latency execution then proceeds asynchronously.
//   - BUF_SWAP is a synchronization uop. It retires only when all previously
//     issued LOAD uops have reported tile-ready completion.
//   - ACC_FENCE is a synchronization uop. It retires only when all previously
//     issued OUTPUT uops have completed their memory writeback.
//   - GEMM retirement is tracked per PACC. OUTPUT dispatch only waits for the
//     target PACC's write count to drain, so unrelated PACC execution can
//     remain in flight.
//
// GEMM dispatch timing:
//   1. The scheduler handshakes with SA.gemm_valid/ready. The SA returns the
//      allocated physical lane in gemm_alloc_lane.
//   2. The allocated lane and A/B buffer indices are registered. In the next
//      cycle the A/B operand buffers are read; one cycle later the two complete
//      matrices are written into the allocated SA lane through ain/bin.

`default_nettype none

module top_static #(
    parameter int SA_WIDTH        = 32,
    parameter int SUBTILE_K       = 32,
    parameter int LANE_NUM        = 4,
    parameter int ABUF_SIZE       = 64,
    parameter int BBUF_SIZE       = 64,
    parameter int PACC_NUM        = 16,
    parameter int ADDR_WIDTH      = 32,
    parameter int DIM_WIDTH       = 16,
    parameter int UOP_FIFO_DEPTH  = 16,
    parameter int STORE_ROW_WRITE_BEATS = 1,

    parameter int LANE_IDX_WIDTH  = (LANE_NUM <= 1) ? 1 : $clog2(LANE_NUM),
    parameter int ABUF_IDX_WIDTH  = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH  = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int PACC_IDX_WIDTH  = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ROW8_WIDTH      = SUBTILE_K * 8,
    parameter int LOAD_DATA_WIDTH = 256,
    parameter int LOAD_BUS_ID_WIDTH =
        ((SA_WIDTH * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)) <= 1) ? 1 :
        $clog2(SA_WIDTH * ((ROW8_WIDTH >= LOAD_DATA_WIDTH) ?
          (ROW8_WIDTH / LOAD_DATA_WIDTH) : 1)),
    parameter int ROW32_WIDTH     = SA_WIDTH * 32,
    parameter int LOAD_ROWS_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH + 1),
    parameter int STORE_MEM_DATA_WIDTH = ROW32_WIDTH / STORE_ROW_WRITE_BEATS,
    parameter int GEMM_INSTID_WIDTH = 16,
    parameter int GEMM_TRACK_DEPTH = 256,
    parameter int OUTPUT_TRACK_DEPTH = PACC_NUM,
    parameter int UOP_FIFO_IDX_WIDTH = (UOP_FIFO_DEPTH <= 1) ? 1 : $clog2(UOP_FIFO_DEPTH),
    parameter int UOP_FIFO_CNT_WIDTH = (UOP_FIFO_DEPTH <= 1) ? 1 : $clog2(UOP_FIFO_DEPTH + 1),
    parameter int GEMM_TRACK_IDX_WIDTH = (GEMM_TRACK_DEPTH <= 1) ? 1 : $clog2(GEMM_TRACK_DEPTH),
    parameter int OUTPUT_TRACK_IDX_WIDTH = (OUTPUT_TRACK_DEPTH <= 1) ? 1 : $clog2(OUTPUT_TRACK_DEPTH),
    parameter int OUTPUT_TRACK_CNT_WIDTH = (OUTPUT_TRACK_DEPTH <= 1) ? 1 : $clog2(OUTPUT_TRACK_DEPTH + 1),
    parameter int OUTSTANDING_CNT_WIDTH = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic cmd_valid_i,
    output logic cmd_ready_o,
    input  logic [ADDR_WIDTH-1:0] cmd_a_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_b_base_i,
    input  logic [ADDR_WIDTH-1:0] cmd_c_base_i,
    input  logic [DIM_WIDTH-1:0] cmd_m_i,
    input  logic [DIM_WIDTH-1:0] cmd_n_i,
    input  logic [DIM_WIDTH-1:0] cmd_k_i,
    input  logic [DIM_WIDTH-1:0] cmd_batch_i,

    output logic load_mem_req_valid_o,
    input  logic load_mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] load_mem_req_addr_o,
    output logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_req_id_o,

    input  logic load_mem_rsp_valid_i,
    output logic load_mem_rsp_ready_o,
    input  logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_rsp_id_i,
    input  logic [LOAD_DATA_WIDTH-1:0] load_mem_rsp_data_i,

    output logic store_mem_wr_valid_o,
    input  logic store_mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
    output logic [STORE_MEM_DATA_WIDTH-1:0] store_mem_wr_data_o
);

    import uopparse_pkg::*;

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (SUBTILE_K <= 0) begin
            $error("SUBTILE_K must be positive");
        end
        if ((SUBTILE_K & (SUBTILE_K - 1)) != 0) begin
            $error("SUBTILE_K must be a power of two");
        end
        if (ROW8_WIDTH != SUBTILE_K * 8) begin
            $error("ROW8_WIDTH must equal SUBTILE_K * 8");
        end
        if (LOAD_DATA_WIDTH <= 0) begin
            $error("LOAD_DATA_WIDTH must be positive");
        end
        if ((LOAD_DATA_WIDTH & (LOAD_DATA_WIDTH - 1)) != 0) begin
            $error("LOAD_DATA_WIDTH must be a power of two");
        end
        if ((LOAD_DATA_WIDTH % 8) != 0) begin
            $error("LOAD_DATA_WIDTH must be byte-aligned");
        end
        if (!((LOAD_DATA_WIDTH >= ROW8_WIDTH &&
               (LOAD_DATA_WIDTH % ROW8_WIDTH) == 0) ||
              (ROW8_WIDTH >= LOAD_DATA_WIDTH &&
               (ROW8_WIDTH % LOAD_DATA_WIDTH) == 0))) begin
            $error("LOAD_DATA_WIDTH and ROW8_WIDTH must divide each other");
        end
        if (LANE_NUM <= 0) begin
            $error("LANE_NUM must be positive");
        end
        if (ABUF_SIZE <= 0) begin
            $error("ABUF_SIZE must be positive");
        end
        if (BBUF_SIZE <= 0) begin
            $error("BBUF_SIZE must be positive");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
        if (UOP_FIFO_DEPTH <= 0) begin
            $error("UOP_FIFO_DEPTH must be positive");
        end
        if (STORE_ROW_WRITE_BEATS <= 0) begin
            $error("STORE_ROW_WRITE_BEATS must be positive");
        end
        if (GEMM_TRACK_DEPTH <= 0) begin
            $error("GEMM_TRACK_DEPTH must be positive");
        end
        if (OUTPUT_TRACK_DEPTH <= 0) begin
            $error("OUTPUT_TRACK_DEPTH must be positive");
        end
        if ((STORE_ROW_WRITE_BEATS & (STORE_ROW_WRITE_BEATS - 1)) != 0) begin
            $error("STORE_ROW_WRITE_BEATS must be one or a power of two");
        end
        if ((ROW32_WIDTH % STORE_ROW_WRITE_BEATS) != 0) begin
            $error("ROW32_WIDTH must be divisible by STORE_ROW_WRITE_BEATS");
        end
    end

    typedef struct packed {
        uop_type_e typ;
        logic [ADDR_WIDTH-1:0] addr;
        logic [ABUF_IDX_WIDTH-1:0] abufidx;
        logic [BBUF_IDX_WIDTH-1:0] bbufidx;
        logic [PACC_IDX_WIDTH-1:0] paccidx;
        logic [LOAD_ROWS_WIDTH-1:0] valid_rows;
        logic accum;
    } uop_entry_t;

    typedef enum logic [1:0] {
        GEMM_PIPE_IDLE,
        GEMM_PIPE_READ,
        GEMM_PIPE_WRITE
    } gemm_pipe_state_t;

    function automatic logic [UOP_FIFO_IDX_WIDTH-1:0] fifo_ptr_inc(
        input logic [UOP_FIFO_IDX_WIDTH-1:0] ptr
    );
        begin
            if (int'(ptr) == (UOP_FIFO_DEPTH - 1)) begin
                return '0;
            end
            return ptr + UOP_FIFO_IDX_WIDTH'(1);
        end
    endfunction

    uop_type_e parser_uop_type;
    logic parser_cmd_ready;
    logic parser_uop_valid;
    logic parser_uop_ready;
    logic [ADDR_WIDTH-1:0] parser_uop_addr;
    logic [ABUF_IDX_WIDTH-1:0] parser_uop_abufidx;
    logic [BBUF_IDX_WIDTH-1:0] parser_uop_bbufidx;
    logic [PACC_IDX_WIDTH-1:0] parser_uop_paccidx;
    logic [LOAD_ROWS_WIDTH-1:0] parser_uop_valid_rows;
    logic parser_uop_accum;

    logic [OUTSTANDING_CNT_WIDTH-1:0] load_outstanding_q;
    logic [OUTSTANDING_CNT_WIDTH-1:0] output_outstanding_q;

    assign cmd_ready_o = parser_cmd_ready;

    static_uopparse #(
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_K(SUBTILE_K),
        .ABUF_SIZE(ABUF_SIZE),
        .BBUF_SIZE(BBUF_SIZE),
        .PACC_NUM(PACC_NUM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DIM_WIDTH(DIM_WIDTH),
        .ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),
        .BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)
    ) u_static_uopparse (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(parser_cmd_ready),
        .cmd_a_base_i(cmd_a_base_i),
        .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i),
        .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i),
        .cmd_batch_i(cmd_batch_i),
        .uop_valid_o(parser_uop_valid),
        .uop_ready_i(parser_uop_ready),
        .uop_type_o(parser_uop_type),
        .uop_addr_o(parser_uop_addr),
        .uop_abufidx_o(parser_uop_abufidx),
        .uop_bbufidx_o(parser_uop_bbufidx),
        .uop_paccidx_o(parser_uop_paccidx),
        .uop_valid_rows_o(parser_uop_valid_rows),
        .uop_accum_o(parser_uop_accum)
    );

    uop_entry_t uop_fifo [UOP_FIFO_DEPTH];
    logic [UOP_FIFO_IDX_WIDTH-1:0] fifo_wr_ptr_q;
    logic [UOP_FIFO_IDX_WIDTH-1:0] fifo_rd_ptr_q;
    logic [UOP_FIFO_CNT_WIDTH-1:0] fifo_count_q;

    wire fifo_empty = fifo_count_q == '0;
    wire fifo_full = fifo_count_q == UOP_FIFO_CNT_WIDTH'(UOP_FIFO_DEPTH);
    wire fifo_head_valid = !fifo_empty;
    uop_entry_t fifo_head;

    assign fifo_head = uop_fifo[int'(fifo_rd_ptr_q)];
    assign parser_uop_ready = !fifo_full;
    wire fifo_push = parser_uop_valid && parser_uop_ready;

    logic fifo_pop;
    wire fifo_pop_fire = fifo_head_valid && fifo_pop;

    logic load_uop_valid;
    logic load_uop_ready;
    logic load_uop_is_b;
    logic [ADDR_WIDTH-1:0] load_uop_addr;
    logic [ABUF_IDX_WIDTH-1:0] load_uop_abufidx;
    logic [BBUF_IDX_WIDTH-1:0] load_uop_bbufidx;
    logic [LOAD_ROWS_WIDTH-1:0] load_uop_valid_rows;

    logic abuf_wr_valid;
    logic [ABUF_IDX_WIDTH-1:0] abuf_wr_idx;
    logic [SA_WIDTH-1:0] abuf_wr_bank_en;
    logic [ROW8_WIDTH-1:0] abuf_wr_data [SA_WIDTH];
    logic bbuf_wr_valid;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_wr_idx;
    logic [SA_WIDTH-1:0] bbuf_wr_bank_en;
    logic [ROW8_WIDTH-1:0] bbuf_wr_data [SA_WIDTH];
    logic abuf_ready_valid;
    logic [ABUF_IDX_WIDTH-1:0] abuf_ready_idx;
    logic bbuf_ready_valid;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_ready_idx;

    loadunit #(
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_K(SUBTILE_K),
        .ABUF_SIZE(ABUF_SIZE),
        .BBUF_SIZE(BBUF_SIZE),
        .ADDR_WIDTH(ADDR_WIDTH),
        .ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),
        .BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),
        .BUS_ID_WIDTH(LOAD_BUS_ID_WIDTH),
        .ROWS_LEFT_WIDTH(LOAD_ROWS_WIDTH),
        .ROW_DATA_WIDTH(ROW8_WIDTH),
        .LOAD_DATA_WIDTH(LOAD_DATA_WIDTH)
    ) u_loadunit (
        .clk(clk),
        .rst_n(rst_n),
        .uop_valid_i(load_uop_valid),
        .uop_ready_o(load_uop_ready),
        .uop_is_b_i(load_uop_is_b),
        .uop_addr_i(load_uop_addr),
        .uop_abufidx_i(load_uop_abufidx),
        .uop_bbufidx_i(load_uop_bbufidx),
        .uop_valid_rows_i(load_uop_valid_rows),
        .mem_req_valid_o(load_mem_req_valid_o),
        .mem_req_ready_i(load_mem_req_ready_i),
        .mem_req_addr_o(load_mem_req_addr_o),
        .mem_req_id_o(load_mem_req_id_o),
        .mem_rsp_valid_i(load_mem_rsp_valid_i),
        .mem_rsp_ready_o(load_mem_rsp_ready_o),
        .mem_rsp_id_i(load_mem_rsp_id_i),
        .mem_rsp_data_i(load_mem_rsp_data_i),
        .abuf_wr_valid_o(abuf_wr_valid),
        .abuf_wr_idx_o(abuf_wr_idx),
        .abuf_wr_bank_en_o(abuf_wr_bank_en),
        .abuf_wr_data_o(abuf_wr_data),
        .bbuf_wr_valid_o(bbuf_wr_valid),
        .bbuf_wr_idx_o(bbuf_wr_idx),
        .bbuf_wr_bank_en_o(bbuf_wr_bank_en),
        .bbuf_wr_data_o(bbuf_wr_data),
        .abuf_ready_valid_o(abuf_ready_valid),
        .abuf_ready_idx_o(abuf_ready_idx),
        .bbuf_ready_valid_o(bbuf_ready_valid),
        .bbuf_ready_idx_o(bbuf_ready_idx)
    );

    logic abuf_rd_valid;
    logic abuf_rd_valid_unused;
    logic [ABUF_IDX_WIDTH-1:0] abuf_rd_idx;
    logic [ROW8_WIDTH-1:0] abuf_rd_data [SA_WIDTH];
    logic bbuf_rd_valid;
    logic bbuf_rd_valid_unused;
    logic [BBUF_IDX_WIDTH-1:0] bbuf_rd_idx;
    logic [ROW8_WIDTH-1:0] bbuf_rd_data [SA_WIDTH];

    oprandbuf #(
        .BUF_SIZE(ABUF_SIZE),
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_K(SUBTILE_K),
        .BUF_IDX_WIDTH(ABUF_IDX_WIDTH),
        .BANK_DATA_WIDTH(ROW8_WIDTH)
    ) u_abuf (
        .clk(clk),
        .rst_n(rst_n),
        .wr_valid_i(abuf_wr_valid),
        .wr_idx_i(abuf_wr_idx),
        .wr_bank_en_i(abuf_wr_bank_en),
        .wr_data_i(abuf_wr_data),
        .rd_valid_i(abuf_rd_valid),
        .rd_idx_i(abuf_rd_idx),
        .rd_valid_o(abuf_rd_valid_unused),
        .rd_data_o(abuf_rd_data)
    );

    oprandbuf #(
        .BUF_SIZE(BBUF_SIZE),
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_K(SUBTILE_K),
        .BUF_IDX_WIDTH(BBUF_IDX_WIDTH),
        .BANK_DATA_WIDTH(ROW8_WIDTH)
    ) u_bbuf (
        .clk(clk),
        .rst_n(rst_n),
        .wr_valid_i(bbuf_wr_valid),
        .wr_idx_i(bbuf_wr_idx),
        .wr_bank_en_i(bbuf_wr_bank_en),
        .wr_data_i(bbuf_wr_data),
        .rd_valid_i(bbuf_rd_valid),
        .rd_idx_i(bbuf_rd_idx),
        .rd_valid_o(bbuf_rd_valid_unused),
        .rd_data_o(bbuf_rd_data)
    );

    logic store_uop_valid;
    logic store_uop_ready;
    logic [ADDR_WIDTH-1:0] store_uop_addr;
    logic [PACC_IDX_WIDTH-1:0] store_uop_paccidx;
    logic store_done_valid;

    logic sa_getacc_valid;
    logic sa_getacc_ready;
    logic [PACC_IDX_WIDTH-1:0] sa_getacc_idx;
    logic sa_getacc_data_valid;
    logic [ROW32_WIDTH-1:0] sa_getacc_data;

    storeunit #(
        .SA_WIDTH(SA_WIDTH),
        .PACC_NUM(PACC_NUM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .ROW_DATA_WIDTH(ROW32_WIDTH),
        .ROW_WRITE_BEATS(STORE_ROW_WRITE_BEATS),
        .MEM_DATA_WIDTH(STORE_MEM_DATA_WIDTH)
    ) u_storeunit (
        .clk(clk),
        .rst_n(rst_n),
        .uop_valid_i(store_uop_valid),
        .uop_ready_o(store_uop_ready),
        .uop_addr_i(store_uop_addr),
        .uop_paccidx_i(store_uop_paccidx),
        .sa_getacc_valid_o(sa_getacc_valid),
        .sa_getacc_ready_i(sa_getacc_ready),
        .sa_getacc_idx_o(sa_getacc_idx),
        .sa_getacc_data_valid_i(sa_getacc_data_valid),
        .sa_getacc_data_i(sa_getacc_data),
        .mem_wr_valid_o(store_mem_wr_valid_o),
        .mem_wr_ready_i(store_mem_wr_ready_i),
        .mem_wr_addr_o(store_mem_wr_addr_o),
        .mem_wr_data_o(store_mem_wr_data_o),
        .done_valid_o(store_done_valid)
    );

    logic sa_ain_valid;
    logic [ROW8_WIDTH-1:0] sa_ain_data [SA_WIDTH];
    logic [LANE_IDX_WIDTH-1:0] sa_ain_laneidx;
    logic sa_bin_valid;
    logic [ROW8_WIDTH-1:0] sa_bin_data [SA_WIDTH];
    logic [LANE_IDX_WIDTH-1:0] sa_bin_laneidx;

    logic sa_gemm_valid;
    logic sa_gemm_ready;
    logic [LANE_IDX_WIDTH-1:0] sa_gemm_alloc_lane;
    logic [GEMM_INSTID_WIDTH-1:0] sa_gemm_instid;
    logic [PACC_IDX_WIDTH-1:0] sa_gemm_paccidx;
    logic sa_gemm_accum;
    logic sa_gemm_finish;
    logic [GEMM_INSTID_WIDTH-1:0] sa_gemm_finish_instid;

    sa #(
        .SA_WIDTH(SA_WIDTH),
        .SUBTILE_K(SUBTILE_K),
        .LANE_NUM(LANE_NUM),
        .LANE_IDX_WIDTH(LANE_IDX_WIDTH),
        .PACC_NUM(PACC_NUM),
        .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
        .GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH)
    ) u_sa (
        .clk(clk),
        .rst_n(rst_n),
        .ain_valid(sa_ain_valid),
        .ain_data(sa_ain_data),
        .ain_laneidx(sa_ain_laneidx),
        .bin_valid(sa_bin_valid),
        .bin_data(sa_bin_data),
        .bin_laneidx(sa_bin_laneidx),
        .gemm_valid(sa_gemm_valid),
        .gemm_ready(sa_gemm_ready),
        .gemm_alloc_lane(sa_gemm_alloc_lane),
        .gemm_instid(sa_gemm_instid),
        .gemm_paccidx(sa_gemm_paccidx),
        .gemm_accum(sa_gemm_accum),
        .gemm_finish(sa_gemm_finish),
        .gemm_finish_instid(sa_gemm_finish_instid),
        .getacc_valid(sa_getacc_valid),
        .getacc_ready(sa_getacc_ready),
        .getacc_idx(sa_getacc_idx),
        .getacc_data_valid(sa_getacc_data_valid),
        .getacc_data(sa_getacc_data)
    );

    gemm_pipe_state_t gemm_pipe_state_q;
    logic [LANE_IDX_WIDTH-1:0] gemm_lane_q;
    logic [ABUF_IDX_WIDTH-1:0] gemm_abufidx_q;
    logic [BBUF_IDX_WIDTH-1:0] gemm_bbufidx_q;
    logic [GEMM_INSTID_WIDTH-1:0] gemm_instid_q;

    logic [OUTSTANDING_CNT_WIDTH-1:0] pacc_write_count_q [PACC_NUM];
    logic [OUTSTANDING_CNT_WIDTH-1:0] pacc_read_count_q [PACC_NUM];

    logic gemm_track_valid_q [GEMM_TRACK_DEPTH];
    logic [GEMM_INSTID_WIDTH-1:0] gemm_track_instid_q [GEMM_TRACK_DEPTH];
    logic [PACC_IDX_WIDTH-1:0] gemm_track_paccidx_q [GEMM_TRACK_DEPTH];
    logic gemm_track_free_found;
    logic [GEMM_TRACK_IDX_WIDTH-1:0] gemm_track_free_idx;
    logic gemm_finish_found;
    logic [GEMM_TRACK_IDX_WIDTH-1:0] gemm_finish_idx;
    logic [PACC_IDX_WIDTH-1:0] gemm_finish_paccidx;

    logic [PACC_IDX_WIDTH-1:0] output_track_paccidx_q [OUTPUT_TRACK_DEPTH];
    logic [OUTPUT_TRACK_IDX_WIDTH-1:0] output_track_wr_ptr_q;
    logic [OUTPUT_TRACK_IDX_WIDTH-1:0] output_track_rd_ptr_q;
    logic [OUTPUT_TRACK_CNT_WIDTH-1:0] output_track_count_q;
    logic output_track_can_push;
    logic [PACC_IDX_WIDTH-1:0] output_finish_paccidx;

    wire load_dispatch_fire = load_uop_valid && load_uop_ready;
    wire output_dispatch_fire = store_uop_valid && store_uop_ready;
    wire gemm_dispatch_fire = sa_gemm_valid && sa_gemm_ready;

    wire [1:0] load_done_count =
        {1'b0, abuf_ready_valid} + {1'b0, bbuf_ready_valid};
    wire [1:0] output_done_count = {1'b0, store_done_valid};

    function automatic logic [OUTPUT_TRACK_IDX_WIDTH-1:0] output_track_ptr_inc(
        input logic [OUTPUT_TRACK_IDX_WIDTH-1:0] ptr
    );
        begin
            if (int'(ptr) == (OUTPUT_TRACK_DEPTH - 1)) begin
                return '0;
            end
            return ptr + OUTPUT_TRACK_IDX_WIDTH'(1);
        end
    endfunction

    always_comb begin
        gemm_track_free_found = 1'b0;
        gemm_track_free_idx = '0;
        for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
            if (!gemm_track_valid_q[i] && !gemm_track_free_found) begin
                gemm_track_free_found = 1'b1;
                gemm_track_free_idx = GEMM_TRACK_IDX_WIDTH'(i);
            end
        end
    end

    always_comb begin
        gemm_finish_found = 1'b0;
        gemm_finish_idx = '0;
        gemm_finish_paccidx = '0;
        for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
            if (sa_gemm_finish &&
                gemm_track_valid_q[i] &&
                (gemm_track_instid_q[i] == sa_gemm_finish_instid) &&
                !gemm_finish_found) begin
                gemm_finish_found = 1'b1;
                gemm_finish_idx = GEMM_TRACK_IDX_WIDTH'(i);
                gemm_finish_paccidx = gemm_track_paccidx_q[i];
            end
        end
    end

    assign output_track_can_push =
        output_track_count_q != OUTPUT_TRACK_CNT_WIDTH'(OUTPUT_TRACK_DEPTH);
    assign output_finish_paccidx =
        output_track_paccidx_q[int'(output_track_rd_ptr_q)];

    assign abuf_rd_valid = gemm_pipe_state_q == GEMM_PIPE_READ;
    assign abuf_rd_idx = gemm_abufidx_q;
    assign bbuf_rd_valid = gemm_pipe_state_q == GEMM_PIPE_READ;
    assign bbuf_rd_idx = gemm_bbufidx_q;

    assign sa_ain_valid = gemm_pipe_state_q == GEMM_PIPE_WRITE;
    assign sa_ain_laneidx = gemm_lane_q;
    assign sa_bin_valid = gemm_pipe_state_q == GEMM_PIPE_WRITE;
    assign sa_bin_laneidx = gemm_lane_q;

    always_comb begin
        for (int i = 0; i < SA_WIDTH; i++) begin
            sa_ain_data[i] = abuf_rd_data[i];
            // BBuf is already laid out as the transposed B view: bank/row i is
            // the data for SA column i. Forward it unchanged into the array.
            sa_bin_data[i] = bbuf_rd_data[i];
        end
    end

    always_comb begin
        fifo_pop = 1'b0;

        load_uop_valid = 1'b0;
        load_uop_is_b = 1'b0;
        load_uop_addr = '0;
        load_uop_abufidx = '0;
        load_uop_bbufidx = '0;
        load_uop_valid_rows = '0;

        store_uop_valid = 1'b0;
        store_uop_addr = '0;
        store_uop_paccidx = '0;

        sa_gemm_valid = 1'b0;
        sa_gemm_instid = gemm_instid_q;
        sa_gemm_paccidx = '0;
        sa_gemm_accum = 1'b0;

        if (fifo_head_valid) begin
            unique case (fifo_head.typ)
                UOP_LOAD_A, UOP_LOAD_B: begin
                    load_uop_valid = 1'b1;
                    load_uop_is_b = fifo_head.typ == UOP_LOAD_B;
                    load_uop_addr = fifo_head.addr;
                    load_uop_abufidx = fifo_head.abufidx;
                    load_uop_bbufidx = fifo_head.bbufidx;
                    load_uop_valid_rows = fifo_head.valid_rows;
                    fifo_pop = load_uop_ready;
                end

                UOP_GEMM: begin
                    if ((gemm_pipe_state_q == GEMM_PIPE_IDLE) &&
                        gemm_track_free_found &&
                        (pacc_read_count_q[int'(fifo_head.paccidx)] == '0)) begin
                        sa_gemm_valid = 1'b1;
                        sa_gemm_paccidx = fifo_head.paccidx;
                        sa_gemm_accum = fifo_head.accum;
                        fifo_pop = sa_gemm_ready;
                    end
                end

                UOP_OUTPUT: begin
                    if ((pacc_write_count_q[int'(fifo_head.paccidx)] == '0) &&
                        output_track_can_push) begin
                        store_uop_valid = 1'b1;
                        store_uop_addr = fifo_head.addr;
                        store_uop_paccidx = fifo_head.paccidx;
                        fifo_pop = store_uop_ready;
                    end
                end

                UOP_BUF_SWAP: begin
                    fifo_pop = load_outstanding_q == '0;
                end

                UOP_ACC_FENCE: begin
                    fifo_pop = output_outstanding_q == '0;
                end

                default: begin
                    fifo_pop = 1'b1;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr_q <= '0;
            fifo_rd_ptr_q <= '0;
            fifo_count_q <= '0;
            gemm_pipe_state_q <= GEMM_PIPE_IDLE;
            gemm_lane_q <= '0;
            gemm_abufidx_q <= '0;
            gemm_bbufidx_q <= '0;
            gemm_instid_q <= '0;
            load_outstanding_q <= '0;
            output_outstanding_q <= '0;
            for (int i = 0; i < UOP_FIFO_DEPTH; i++) begin
                uop_fifo[i].typ <= UOP_LOAD_A;
                uop_fifo[i].addr <= '0;
                uop_fifo[i].abufidx <= '0;
                uop_fifo[i].bbufidx <= '0;
                uop_fifo[i].paccidx <= '0;
                uop_fifo[i].valid_rows <= '0;
                uop_fifo[i].accum <= 1'b0;
            end
            for (int i = 0; i < PACC_NUM; i++) begin
                pacc_write_count_q[i] <= '0;
                pacc_read_count_q[i] <= '0;
            end
            for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
                gemm_track_valid_q[i] <= 1'b0;
                gemm_track_instid_q[i] <= '0;
                gemm_track_paccidx_q[i] <= '0;
            end
            output_track_wr_ptr_q <= '0;
            output_track_rd_ptr_q <= '0;
            output_track_count_q <= '0;
            for (int i = 0; i < OUTPUT_TRACK_DEPTH; i++) begin
                output_track_paccidx_q[i] <= '0;
            end
        end else begin
            if (fifo_push) begin
                uop_fifo[int'(fifo_wr_ptr_q)].typ <= parser_uop_type;
                uop_fifo[int'(fifo_wr_ptr_q)].addr <= parser_uop_addr;
                uop_fifo[int'(fifo_wr_ptr_q)].abufidx <= parser_uop_abufidx;
                uop_fifo[int'(fifo_wr_ptr_q)].bbufidx <= parser_uop_bbufidx;
                uop_fifo[int'(fifo_wr_ptr_q)].paccidx <= parser_uop_paccidx;
                uop_fifo[int'(fifo_wr_ptr_q)].valid_rows <= parser_uop_valid_rows;
                uop_fifo[int'(fifo_wr_ptr_q)].accum <= parser_uop_accum;
                fifo_wr_ptr_q <= fifo_ptr_inc(fifo_wr_ptr_q);
            end

            if (fifo_pop_fire) begin
                fifo_rd_ptr_q <= fifo_ptr_inc(fifo_rd_ptr_q);
            end

            unique case ({fifo_push, fifo_pop_fire})
                2'b10: fifo_count_q <= fifo_count_q + UOP_FIFO_CNT_WIDTH'(1);
                2'b01: fifo_count_q <= fifo_count_q - UOP_FIFO_CNT_WIDTH'(1);
                default: begin
                end
            endcase

            unique case (gemm_pipe_state_q)
                GEMM_PIPE_IDLE: begin
                    if (gemm_dispatch_fire) begin
                        gemm_pipe_state_q <= GEMM_PIPE_READ;
                        gemm_lane_q <= sa_gemm_alloc_lane;
                        gemm_abufidx_q <= fifo_head.abufidx;
                        gemm_bbufidx_q <= fifo_head.bbufidx;
                        gemm_instid_q <= gemm_instid_q + GEMM_INSTID_WIDTH'(1);
                        gemm_track_valid_q[int'(gemm_track_free_idx)] <= 1'b1;
                        gemm_track_instid_q[int'(gemm_track_free_idx)] <= gemm_instid_q;
                        gemm_track_paccidx_q[int'(gemm_track_free_idx)] <= fifo_head.paccidx;
                    end
                end

                GEMM_PIPE_READ: begin
                    gemm_pipe_state_q <= GEMM_PIPE_WRITE;
                end

                GEMM_PIPE_WRITE: begin
                    gemm_pipe_state_q <= GEMM_PIPE_IDLE;
                end

                default: begin
                    gemm_pipe_state_q <= GEMM_PIPE_IDLE;
                end
            endcase

            load_outstanding_q <= load_outstanding_q +
                OUTSTANDING_CNT_WIDTH'(load_dispatch_fire) -
                OUTSTANDING_CNT_WIDTH'(load_done_count);
            output_outstanding_q <= output_outstanding_q +
                OUTSTANDING_CNT_WIDTH'(output_dispatch_fire) -
                OUTSTANDING_CNT_WIDTH'(output_done_count);

            if (sa_gemm_finish && gemm_finish_found) begin
                gemm_track_valid_q[int'(gemm_finish_idx)] <= 1'b0;
            end

            if (output_dispatch_fire) begin
                output_track_paccidx_q[int'(output_track_wr_ptr_q)] <= fifo_head.paccidx;
                output_track_wr_ptr_q <= output_track_ptr_inc(output_track_wr_ptr_q);
            end

            if (store_done_valid) begin
                output_track_rd_ptr_q <= output_track_ptr_inc(output_track_rd_ptr_q);
            end

            unique case ({output_dispatch_fire, store_done_valid})
                2'b10: output_track_count_q <= output_track_count_q +
                    OUTPUT_TRACK_CNT_WIDTH'(1);
                2'b01: output_track_count_q <= output_track_count_q -
                    OUTPUT_TRACK_CNT_WIDTH'(1);
                default: begin
                end
            endcase

            for (int pacc = 0; pacc < PACC_NUM; pacc++) begin
                pacc_write_count_q[pacc] <= pacc_write_count_q[pacc] +
                    OUTSTANDING_CNT_WIDTH'(gemm_dispatch_fire &&
                        (fifo_head.paccidx == PACC_IDX_WIDTH'(pacc))) -
                    OUTSTANDING_CNT_WIDTH'(sa_gemm_finish && gemm_finish_found &&
                        (gemm_finish_paccidx == PACC_IDX_WIDTH'(pacc)));
                pacc_read_count_q[pacc] <= pacc_read_count_q[pacc] +
                    OUTSTANDING_CNT_WIDTH'(output_dispatch_fire &&
                        (fifo_head.paccidx == PACC_IDX_WIDTH'(pacc))) -
                    OUTSTANDING_CNT_WIDTH'(store_done_valid &&
                        (output_finish_paccidx == PACC_IDX_WIDTH'(pacc)));
            end
        end
    end

endmodule

`default_nettype wire
