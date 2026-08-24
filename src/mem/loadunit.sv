// Load uop pipeline.
//
// A LOAD uop names one SA_WIDTH x SUBTILE_K A tile or a B tile stored in
// transposed-view form in external memory: SA_WIDTH rows, one per output
// column, each row containing SUBTILE_K K-direction FP8 values.  The load unit
// does not transpose or reorder row payloads; memory row N is written directly
// to operand-buffer bank N.  The uop also carries the number of valid rows in
// the tile.  The load unit only issues memory requests for those rows and
// writes zero to invalid destination row banks locally.  This preserves padded
// GEMM semantics while saving tail-tile memory bandwidth.
//
// The external memory interface is a simplified read-only, AXI-lite-like
// protocol with explicit transaction IDs:
//   req: mem_req_valid_o && mem_req_ready_i, carrying mem_req_addr_o/id_o
//   rsp: mem_rsp_valid_i && mem_rsp_ready_o, carrying mem_rsp_id_i/data_i
//
// Requests are non-blocking.  IDs are reserved before requests are presented
// on the bus, held stable while req_valid is stalled, and marked outstanding
// after the request handshake.  The pipeline is split into:
//   1. uop accept: latch one tile-level load uop.
//   2. row issue: reserve an ID, write the metadata table, and present a stable
//      memory request.
//   3. response decode: register metadata/data looked up by mem_rsp_id_i.
//   4. buffer write: drive exactly one row-bank write and optional tile-ready
//      pulse.
// This keeps the response ID table lookup off the A/B buffer write critical
// path.  A/B buffer ready is reported when the last row response for that tile
// is written.
//
// Addressing convention: uop_addr_i is a tile-linear address.  Row request
// addresses are uop_addr_i * SA_WIDTH + row_idx.

`default_nettype none

module loadunit #(
    parameter int SA_WIDTH       = 4,
    parameter int SUBTILE_K      = 32,
    parameter int ABUF_SIZE      = 8,
    parameter int BBUF_SIZE      = 8,
    parameter int ADDR_WIDTH     = 32,
    parameter int ABUF_IDX_WIDTH = (ABUF_SIZE <= 1) ? 1 : $clog2(ABUF_SIZE),
    parameter int BBUF_IDX_WIDTH = (BBUF_SIZE <= 1) ? 1 : $clog2(BBUF_SIZE),
    parameter int BUS_ID_WIDTH   = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH * 2),
    parameter int OUTSTANDING_NUM = (1 << BUS_ID_WIDTH),
    parameter int ROW_IDX_WIDTH  = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH),
    parameter int ROW_DATA_WIDTH = SUBTILE_K * 8,
    parameter int ROWS_LEFT_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  logic uop_is_b_i,
    input  logic [ADDR_WIDTH-1:0] uop_addr_i,
    input  logic [ABUF_IDX_WIDTH-1:0] uop_abufidx_i,
    input  logic [BBUF_IDX_WIDTH-1:0] uop_bbufidx_i,
    input  logic [ROWS_LEFT_WIDTH-1:0] uop_valid_rows_i,

    output logic mem_req_valid_o,
    input  logic mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] mem_req_addr_o,
    output logic [BUS_ID_WIDTH-1:0] mem_req_id_o,

    input  logic mem_rsp_valid_i,
    output logic mem_rsp_ready_o,
    input  logic [BUS_ID_WIDTH-1:0] mem_rsp_id_i,
    input  logic [ROW_DATA_WIDTH-1:0] mem_rsp_data_i,

    output logic abuf_wr_valid_o,
    output logic [ABUF_IDX_WIDTH-1:0] abuf_wr_idx_o,
    output logic [SA_WIDTH-1:0] abuf_wr_bank_en_o,
    output logic [ROW_DATA_WIDTH-1:0] abuf_wr_data_o [SA_WIDTH],

    output logic bbuf_wr_valid_o,
    output logic [BBUF_IDX_WIDTH-1:0] bbuf_wr_idx_o,
    output logic [SA_WIDTH-1:0] bbuf_wr_bank_en_o,
    output logic [ROW_DATA_WIDTH-1:0] bbuf_wr_data_o [SA_WIDTH],

    output logic abuf_ready_valid_o,
    output logic [ABUF_IDX_WIDTH-1:0] abuf_ready_idx_o,
    output logic bbuf_ready_valid_o,
    output logic [BBUF_IDX_WIDTH-1:0] bbuf_ready_idx_o
);

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (SUBTILE_K <= 0) begin
            $error("SUBTILE_K must be positive");
        end
        if (ABUF_SIZE <= 0) begin
            $error("ABUF_SIZE must be positive");
        end
        if (BBUF_SIZE <= 0) begin
            $error("BBUF_SIZE must be positive");
        end
        if (ADDR_WIDTH <= 0) begin
            $error("ADDR_WIDTH must be positive");
        end
        if (BUS_ID_WIDTH <= 0) begin
            $error("BUS_ID_WIDTH must be positive");
        end
        if (OUTSTANDING_NUM < SA_WIDTH) begin
            $error("OUTSTANDING_NUM must be at least SA_WIDTH");
        end
        if (OUTSTANDING_NUM != (1 << BUS_ID_WIDTH)) begin
            $error("OUTSTANDING_NUM must equal 1 << BUS_ID_WIDTH");
        end
        if (ROW_DATA_WIDTH != SUBTILE_K * 8) begin
            $error("ROW_DATA_WIDTH must equal SUBTILE_K * 8");
        end
    end

    localparam int FREE_COUNT_WIDTH =
        (OUTSTANDING_NUM <= 1) ? 1 : $clog2(OUTSTANDING_NUM + 1);

    logic id_busy [OUTSTANDING_NUM];
    logic id_outstanding [OUTSTANDING_NUM];
    logic id_is_b [OUTSTANDING_NUM];
    logic [ROW_IDX_WIDTH-1:0] id_row [OUTSTANDING_NUM];
    logic [ABUF_IDX_WIDTH-1:0] id_abufidx [OUTSTANDING_NUM];
    logic [BBUF_IDX_WIDTH-1:0] id_bbufidx [OUTSTANDING_NUM];

    logic [ROWS_LEFT_WIDTH-1:0] a_rows_left [ABUF_SIZE];
    logic [ROWS_LEFT_WIDTH-1:0] b_rows_left [BBUF_SIZE];

    logic issue_active_q;
    logic issue_is_b_q;
    logic [ADDR_WIDTH-1:0] issue_tile_addr_q;
    logic [ABUF_IDX_WIDTH-1:0] issue_abufidx_q;
    logic [BBUF_IDX_WIDTH-1:0] issue_bbufidx_q;
    logic [ROW_IDX_WIDTH-1:0] issue_row_q;
    logic [ROWS_LEFT_WIDTH-1:0] issue_rows_q;

    logic req_hold_valid_q;
    logic [BUS_ID_WIDTH-1:0] req_hold_id_q;
    logic [ADDR_WIDTH-1:0] req_hold_addr_q;

    logic [FREE_COUNT_WIDTH-1:0] free_count_q;
    logic free_found;
    logic [BUS_ID_WIDTH-1:0] free_id;

    always_comb begin
        free_found = 1'b0;
        free_id = '0;
        for (int id = 0; id < OUTSTANDING_NUM; id++) begin
            if (!id_busy[id]) begin
                if (!free_found) begin
                    free_found = 1'b1;
                    free_id = BUS_ID_WIDTH'(id);
                end
            end
        end
    end

    logic target_busy;

    always_comb begin
        target_busy = 1'b1;
        if (uop_is_b_i) begin
            if (int'(uop_bbufidx_i) < BBUF_SIZE) begin
                target_busy = b_rows_left[int'(uop_bbufidx_i)] != '0;
            end
        end else begin
            if (int'(uop_abufidx_i) < ABUF_SIZE) begin
                target_busy = a_rows_left[int'(uop_abufidx_i)] != '0;
            end
        end
    end

    logic [ROWS_LEFT_WIDTH-1:0] uop_rows_eff;
    logic uop_needs_zero_init;

    always_comb begin
        if (uop_valid_rows_i == '0 ||
            uop_valid_rows_i > ROWS_LEFT_WIDTH'(SA_WIDTH)) begin
            uop_rows_eff = ROWS_LEFT_WIDTH'(SA_WIDTH);
        end else begin
            uop_rows_eff = uop_valid_rows_i;
        end
        uop_needs_zero_init = uop_rows_eff < ROWS_LEFT_WIDTH'(SA_WIDTH);
    end

    assign uop_ready_o = !issue_active_q &&
                         !req_hold_valid_q &&
                         (free_count_q >= FREE_COUNT_WIDTH'(uop_rows_eff)) &&
                         !target_busy &&
                         !(uop_needs_zero_init && rsp_valid_q);

    wire uop_fire = uop_valid_i && uop_ready_o;
    wire req_fire = mem_req_valid_o && mem_req_ready_i;

    function automatic logic [ADDR_WIDTH-1:0] row_addr(
        input logic [ADDR_WIDTH-1:0] tile_addr,
        input logic [ROW_IDX_WIDTH-1:0] row_idx
    );
        logic [ADDR_WIDTH-1:0] scaled_tile;
        logic [ADDR_WIDTH-1:0] row_offset;
        begin
            scaled_tile = tile_addr * ADDR_WIDTH'(SA_WIDTH);
            row_offset = ADDR_WIDTH'(row_idx);
            return scaled_tile + row_offset;
        end
    endfunction

    assign mem_req_valid_o = req_hold_valid_q;
    assign mem_req_addr_o = req_hold_addr_q;
    assign mem_req_id_o = req_hold_id_q;
    assign mem_rsp_ready_o = 1'b1;

    logic rsp_accept;
    logic rsp_is_b_comb;
    logic [ROW_IDX_WIDTH-1:0] rsp_row_comb;
    logic [ABUF_IDX_WIDTH-1:0] rsp_abufidx_comb;
    logic [BBUF_IDX_WIDTH-1:0] rsp_bbufidx_comb;
    logic rsp_a_last_comb;
    logic rsp_b_last_comb;

    logic rsp_valid_q;
    logic rsp_is_b_q;
    logic [ROW_IDX_WIDTH-1:0] rsp_row_q;
    logic [ABUF_IDX_WIDTH-1:0] rsp_abufidx_q;
    logic [BBUF_IDX_WIDTH-1:0] rsp_bbufidx_q;
    logic [ROW_DATA_WIDTH-1:0] rsp_data_q;
    logic rsp_a_last_q;
    logic rsp_b_last_q;

    always_comb begin
        rsp_accept = mem_rsp_valid_i && id_outstanding[int'(mem_rsp_id_i)];
        rsp_is_b_comb = id_is_b[int'(mem_rsp_id_i)];
        rsp_row_comb = id_row[int'(mem_rsp_id_i)];
        rsp_abufidx_comb = id_abufidx[int'(mem_rsp_id_i)];
        rsp_bbufidx_comb = id_bbufidx[int'(mem_rsp_id_i)];

        rsp_a_last_comb = 1'b0;
        rsp_b_last_comb = 1'b0;
        if (rsp_accept && !rsp_is_b_comb) begin
            rsp_a_last_comb =
                a_rows_left[int'(rsp_abufidx_comb)] == ROWS_LEFT_WIDTH'(1);
        end
        if (rsp_accept && rsp_is_b_comb) begin
            rsp_b_last_comb =
                b_rows_left[int'(rsp_bbufidx_comb)] == ROWS_LEFT_WIDTH'(1);
        end
    end

    always_comb begin
        abuf_wr_valid_o = rsp_valid_q && !rsp_is_b_q;
        abuf_wr_idx_o = rsp_abufidx_q;
        abuf_wr_bank_en_o = '0;
        for (int row = 0; row < SA_WIDTH; row++) begin
            abuf_wr_data_o[row] = '0;
        end
        if (rsp_valid_q && !rsp_is_b_q) begin
            abuf_wr_bank_en_o[int'(rsp_row_q)] = 1'b1;
            abuf_wr_data_o[int'(rsp_row_q)] = rsp_data_q;
        end else if (uop_fire && !uop_is_b_i && uop_needs_zero_init) begin
            abuf_wr_valid_o = 1'b1;
            abuf_wr_idx_o = uop_abufidx_i;
            for (int row = 0; row < SA_WIDTH; row++) begin
                if (row >= int'(uop_rows_eff)) begin
                    abuf_wr_bank_en_o[row] = 1'b1;
                    abuf_wr_data_o[row] = '0;
                end
            end
        end

        bbuf_wr_valid_o = rsp_valid_q && rsp_is_b_q;
        bbuf_wr_idx_o = rsp_bbufidx_q;
        bbuf_wr_bank_en_o = '0;
        for (int row = 0; row < SA_WIDTH; row++) begin
            bbuf_wr_data_o[row] = '0;
        end
        if (rsp_valid_q && rsp_is_b_q) begin
            bbuf_wr_bank_en_o[int'(rsp_row_q)] = 1'b1;
            bbuf_wr_data_o[int'(rsp_row_q)] = rsp_data_q;
        end else if (uop_fire && uop_is_b_i && uop_needs_zero_init) begin
            bbuf_wr_valid_o = 1'b1;
            bbuf_wr_idx_o = uop_bbufidx_i;
            for (int row = 0; row < SA_WIDTH; row++) begin
                if (row >= int'(uop_rows_eff)) begin
                    bbuf_wr_bank_en_o[row] = 1'b1;
                    bbuf_wr_data_o[row] = '0;
                end
            end
        end

        abuf_ready_valid_o = rsp_valid_q && !rsp_is_b_q && rsp_a_last_q;
        abuf_ready_idx_o = rsp_abufidx_q;
        bbuf_ready_valid_o = rsp_valid_q && rsp_is_b_q && rsp_b_last_q;
        bbuf_ready_idx_o = rsp_bbufidx_q;
    end

    wire can_reserve_req = issue_active_q &&
                           (!req_hold_valid_q || req_fire) &&
                           free_found;
    wire issue_reserve_last = ROWS_LEFT_WIDTH'(issue_row_q) ==
                              (issue_rows_q - ROWS_LEFT_WIDTH'(1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_active_q <= 1'b0;
            issue_is_b_q <= 1'b0;
            issue_tile_addr_q <= '0;
            issue_abufidx_q <= '0;
            issue_bbufidx_q <= '0;
            issue_row_q <= '0;
            issue_rows_q <= '0;
            req_hold_valid_q <= 1'b0;
            req_hold_id_q <= '0;
            req_hold_addr_q <= '0;
            free_count_q <= FREE_COUNT_WIDTH'(OUTSTANDING_NUM);
            rsp_valid_q <= 1'b0;
            rsp_is_b_q <= 1'b0;
            rsp_row_q <= '0;
            rsp_abufidx_q <= '0;
            rsp_bbufidx_q <= '0;
            rsp_data_q <= '0;
            rsp_a_last_q <= 1'b0;
            rsp_b_last_q <= 1'b0;

            for (int id = 0; id < OUTSTANDING_NUM; id++) begin
                id_busy[id] <= 1'b0;
                id_outstanding[id] <= 1'b0;
                id_is_b[id] <= 1'b0;
                id_row[id] <= '0;
                id_abufidx[id] <= '0;
                id_bbufidx[id] <= '0;
            end
            for (int idx = 0; idx < ABUF_SIZE; idx++) begin
                a_rows_left[idx] <= '0;
            end
            for (int idx = 0; idx < BBUF_SIZE; idx++) begin
                b_rows_left[idx] <= '0;
            end
        end else begin
            rsp_valid_q <= rsp_accept;
            rsp_is_b_q <= rsp_is_b_comb;
            rsp_row_q <= rsp_row_comb;
            rsp_abufidx_q <= rsp_abufidx_comb;
            rsp_bbufidx_q <= rsp_bbufidx_comb;
            rsp_data_q <= mem_rsp_data_i;
            rsp_a_last_q <= rsp_a_last_comb;
            rsp_b_last_q <= rsp_b_last_comb;

            if (can_reserve_req && !rsp_accept) begin
                free_count_q <= free_count_q - FREE_COUNT_WIDTH'(1);
            end else if (!can_reserve_req && rsp_accept) begin
                free_count_q <= free_count_q + FREE_COUNT_WIDTH'(1);
            end

            if (req_fire) begin
                id_outstanding[int'(req_hold_id_q)] <= 1'b1;
                req_hold_valid_q <= 1'b0;
            end

            if (rsp_accept) begin
                id_busy[int'(mem_rsp_id_i)] <= 1'b0;
                id_outstanding[int'(mem_rsp_id_i)] <= 1'b0;
                if (rsp_is_b_comb) begin
                    if (b_rows_left[int'(rsp_bbufidx_comb)] != '0) begin
                        b_rows_left[int'(rsp_bbufidx_comb)] <=
                            b_rows_left[int'(rsp_bbufidx_comb)] - ROWS_LEFT_WIDTH'(1);
                    end
                end else begin
                    if (a_rows_left[int'(rsp_abufidx_comb)] != '0) begin
                        a_rows_left[int'(rsp_abufidx_comb)] <=
                            a_rows_left[int'(rsp_abufidx_comb)] - ROWS_LEFT_WIDTH'(1);
                    end
                end
            end

            if (uop_fire) begin
                issue_active_q <= 1'b1;
                issue_is_b_q <= uop_is_b_i;
                issue_tile_addr_q <= uop_addr_i;
                issue_abufidx_q <= uop_abufidx_i;
                issue_bbufidx_q <= uop_bbufidx_i;
                issue_row_q <= '0;
                issue_rows_q <= uop_rows_eff;
                if (uop_is_b_i) begin
                    b_rows_left[int'(uop_bbufidx_i)] <= uop_rows_eff;
                end else begin
                    a_rows_left[int'(uop_abufidx_i)] <= uop_rows_eff;
                end
            end

            if (can_reserve_req) begin
                id_busy[int'(free_id)] <= 1'b1;
                id_outstanding[int'(free_id)] <= 1'b0;
                id_is_b[int'(free_id)] <= issue_is_b_q;
                id_row[int'(free_id)] <= issue_row_q;
                id_abufidx[int'(free_id)] <= issue_abufidx_q;
                id_bbufidx[int'(free_id)] <= issue_bbufidx_q;

                req_hold_valid_q <= 1'b1;
                req_hold_id_q <= free_id;
                req_hold_addr_q <= row_addr(issue_tile_addr_q, issue_row_q);

                if (issue_reserve_last) begin
                    issue_active_q <= 1'b0;
                    issue_row_q <= '0;
                end else begin
                    issue_row_q <= issue_row_q + ROW_IDX_WIDTH'(1);
                end
            end
        end
    end

endmodule

`default_nettype wire
