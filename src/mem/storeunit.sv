// Store uop pipeline.
//
// A STORE/OUTPUT uop names one SA_WIDTH x SA_WIDTH FP32 output tile by an
// external tile-linear base address and one PACC index.  The unit requests the
// complete tile from the systolic array through getacc and receives
// ROWS_PER_CYCLE consecutive rows per getacc_data_valid pulse.  One such row
// group is exactly one write-channel request, so the SA and store-bus widths
// are identical.
//
// Addressing convention:
//   write beat address =
//       uop_addr_i * (SA_WIDTH / ROWS_PER_CYCLE) + row_group_idx
//
// Pipeline structure:
//   1. uop accept: enqueue tile address and PACC index in an ordered descriptor
//      FIFO, independently of the active getacc and writeback operations.
//   2. getacc request: walk the descriptor FIFO with a fetch pointer and start
//      the next SA scan whenever the data FIFO has room for a complete tile.
//   3. data capture: enqueue one multi-row group.  Since both getacc and
//      writeback are ordered, the data FIFO head always belongs to the
//      descriptor FIFO head.
//   4. write output: derive the group address from the head descriptor and pop
//      the descriptor after its final group.

`default_nettype none

module storeunit #(
    parameter int SA_WIDTH        = 4,
    parameter int PACC_NUM        = 16,
    parameter int ADDR_WIDTH      = 32,
    parameter int PACC_IDX_WIDTH  = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ROW_DATA_WIDTH  = SA_WIDTH * 32,
    parameter int ROWS_PER_CYCLE  = 1,
    parameter int GROUPS_PER_TILE = SA_WIDTH / ROWS_PER_CYCLE,
    parameter int GROUP_IDX_WIDTH =
        (GROUPS_PER_TILE <= 1) ? 1 : $clog2(GROUPS_PER_TILE),
    parameter int SA_DATA_WIDTH   = ROW_DATA_WIDTH * ROWS_PER_CYCLE,
    parameter int MEM_DATA_WIDTH  = SA_DATA_WIDTH,
    parameter int FIFO_DEPTH      = GROUPS_PER_TILE * 2,
    parameter int FIFO_IDX_WIDTH  = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    parameter int FIFO_CNT_WIDTH  = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1),
    parameter int UOP_FIFO_DEPTH  = PACC_NUM,
    parameter int UOP_FIFO_IDX_WIDTH =
        (UOP_FIFO_DEPTH <= 1) ? 1 : $clog2(UOP_FIFO_DEPTH),
    parameter int UOP_FIFO_CNT_WIDTH =
        (UOP_FIFO_DEPTH <= 1) ? 1 : $clog2(UOP_FIFO_DEPTH + 1)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic uop_valid_i,
    output logic uop_ready_o,
    input  logic [ADDR_WIDTH-1:0] uop_addr_i,
    input  logic [PACC_IDX_WIDTH-1:0] uop_paccidx_i,

    output logic sa_getacc_valid_o,
    input  logic sa_getacc_ready_i,
    output logic [PACC_IDX_WIDTH-1:0] sa_getacc_idx_o,
    input  logic sa_getacc_data_valid_i,
    input  logic [SA_DATA_WIDTH-1:0] sa_getacc_data_i,

    output logic mem_wr_valid_o,
    input  logic mem_wr_ready_i,
    output logic [ADDR_WIDTH-1:0] mem_wr_addr_o,
    output logic [MEM_DATA_WIDTH-1:0] mem_wr_data_o,

    output logic done_valid_o
);

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
        if (ADDR_WIDTH <= 0) begin
            $error("ADDR_WIDTH must be positive");
        end
        if (PACC_IDX_WIDTH <= 0) begin
            $error("PACC_IDX_WIDTH must be positive");
        end
        if (ROW_DATA_WIDTH != SA_WIDTH * 32) begin
            $error("ROW_DATA_WIDTH must equal SA_WIDTH * 32");
        end
        if (ROWS_PER_CYCLE <= 0) begin
            $error("ROWS_PER_CYCLE must be positive");
        end
        if (ROWS_PER_CYCLE > SA_WIDTH) begin
            $error("ROWS_PER_CYCLE must not exceed SA_WIDTH");
        end
        if ((SA_WIDTH % ROWS_PER_CYCLE) != 0) begin
            $error("SA_WIDTH must be divisible by ROWS_PER_CYCLE");
        end
        if (SA_DATA_WIDTH != (ROW_DATA_WIDTH * ROWS_PER_CYCLE)) begin
            $error("SA_DATA_WIDTH must equal ROW_DATA_WIDTH * ROWS_PER_CYCLE");
        end
        if (MEM_DATA_WIDTH != SA_DATA_WIDTH) begin
            $error("MEM_DATA_WIDTH must equal SA_DATA_WIDTH");
        end
        if (FIFO_DEPTH < GROUPS_PER_TILE) begin
            $error("FIFO_DEPTH must hold at least one complete output tile");
        end
        if (UOP_FIFO_DEPTH <= 0) begin
            $error("UOP_FIFO_DEPTH must be positive");
        end
    end

    logic [ADDR_WIDTH-1:0] uop_addr_fifo [UOP_FIFO_DEPTH];
    logic [PACC_IDX_WIDTH-1:0] uop_pacc_fifo [UOP_FIFO_DEPTH];
    logic [UOP_FIFO_IDX_WIDTH-1:0] uop_wr_ptr_q;
    logic [UOP_FIFO_IDX_WIDTH-1:0] uop_rd_ptr_q;
    logic [UOP_FIFO_IDX_WIDTH-1:0] uop_fetch_ptr_q;
    logic [UOP_FIFO_CNT_WIDTH-1:0] uop_count_q;
    logic [UOP_FIFO_CNT_WIDTH-1:0] unfetched_count_q;

    logic getacc_active_q;
    logic [GROUP_IDX_WIDTH-1:0] recv_group_q;

    (* ram_style = "block" *)
    logic [SA_DATA_WIDTH-1:0] row_fifo_data [FIFO_DEPTH];
    logic [FIFO_IDX_WIDTH-1:0] fifo_wr_ptr_q;
    logic [FIFO_IDX_WIDTH-1:0] fifo_rd_ptr_q;
    logic [FIFO_CNT_WIDTH-1:0] fifo_count_q;

    logic out_valid_q;
    logic [ADDR_WIDTH-1:0] out_addr_q;
    logic [SA_DATA_WIDTH-1:0] out_data_q;
    logic out_last_group_q;
    logic [GROUP_IDX_WIDTH-1:0] write_group_q;

    function automatic logic [ADDR_WIDTH-1:0] tile_base_addr(
        input logic [ADDR_WIDTH-1:0] tile_addr
    );
        begin
            return tile_addr * ADDR_WIDTH'(GROUPS_PER_TILE);
        end
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] group_addr(
        input logic [ADDR_WIDTH-1:0] tile_base,
        input logic [GROUP_IDX_WIDTH-1:0] group_idx
    );
        begin
            return tile_base + ADDR_WIDTH'(group_idx);
        end
    endfunction

    function automatic logic [FIFO_IDX_WIDTH-1:0] fifo_ptr_inc(
        input logic [FIFO_IDX_WIDTH-1:0] ptr
    );
        begin
            if (int'(ptr) == (FIFO_DEPTH - 1)) begin
                return '0;
            end
            return ptr + FIFO_IDX_WIDTH'(1);
        end
    endfunction

    function automatic logic [UOP_FIFO_IDX_WIDTH-1:0] uop_fifo_ptr_inc(
        input logic [UOP_FIFO_IDX_WIDTH-1:0] ptr
    );
        begin
            if (int'(ptr) == (UOP_FIFO_DEPTH - 1)) begin
                return '0;
            end
            return ptr + UOP_FIFO_IDX_WIDTH'(1);
        end
    endfunction

    wire [FIFO_CNT_WIDTH-1:0] fifo_free_count =
        FIFO_CNT_WIDTH'(FIFO_DEPTH) - fifo_count_q;
    wire fifo_has_full_tile_space =
        fifo_free_count >= FIFO_CNT_WIDTH'(GROUPS_PER_TILE);

    wire descriptor_pop;
    assign uop_ready_o =
        (uop_count_q < UOP_FIFO_CNT_WIDTH'(UOP_FIFO_DEPTH)) || descriptor_pop;
    wire uop_fire = uop_valid_i && uop_ready_o;

    assign sa_getacc_valid_o = !getacc_active_q &&
        (unfetched_count_q != '0) && fifo_has_full_tile_space;
    assign sa_getacc_idx_o = uop_pacc_fifo[int'(uop_fetch_ptr_q)];
    wire sa_getacc_fire = sa_getacc_valid_o && sa_getacc_ready_i;

    wire row_push = sa_getacc_data_valid_i && getacc_active_q;
    wire recv_last_group = int'(recv_group_q) == (GROUPS_PER_TILE - 1);

    wire mem_wr_fire = mem_wr_valid_o && mem_wr_ready_i;
    // Do not replace the output stage on a tile's final group: the descriptor
    // head advances on that edge, so the next tile is loaded one cycle later.
    wire out_can_load_row = !out_valid_q ||
        (mem_wr_fire && !out_last_group_q);
    wire fifo_pop_to_out = out_can_load_row &&
        (fifo_count_q != '0) && (uop_count_q != '0);
    wire [GROUP_IDX_WIDTH-1:0] group_to_load =
        (out_valid_q && mem_wr_fire) ?
        (write_group_q + GROUP_IDX_WIDTH'(1)) : write_group_q;
    wire group_to_load_is_last =
        int'(group_to_load) == (GROUPS_PER_TILE - 1);

    assign mem_wr_valid_o = out_valid_q;
    assign mem_wr_addr_o = out_addr_q;
    assign mem_wr_data_o = out_data_q;
    assign done_valid_o = mem_wr_fire && out_last_group_q;
    // Once the final group is registered in the output stage, no more FIFO
    // data belongs to this descriptor.  Advance the descriptor head now so
    // the two FIFO heads retain their strict ordering invariant under bus stalls.
    assign descriptor_pop = fifo_pop_to_out && group_to_load_is_last;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uop_wr_ptr_q <= '0;
            uop_rd_ptr_q <= '0;
            uop_fetch_ptr_q <= '0;
            uop_count_q <= '0;
            unfetched_count_q <= '0;
            getacc_active_q <= 1'b0;
            recv_group_q <= '0;
            fifo_wr_ptr_q <= '0;
            fifo_rd_ptr_q <= '0;
            fifo_count_q <= '0;
            out_valid_q <= 1'b0;
            out_addr_q <= '0;
            out_data_q <= '0;
            out_last_group_q <= 1'b0;
            write_group_q <= '0;
        end else begin
            if (uop_fire) begin
                uop_addr_fifo[int'(uop_wr_ptr_q)] <= uop_addr_i;
                uop_pacc_fifo[int'(uop_wr_ptr_q)] <= uop_paccidx_i;
                uop_wr_ptr_q <= uop_fifo_ptr_inc(uop_wr_ptr_q);
            end

            if (sa_getacc_fire) begin
                getacc_active_q <= 1'b1;
                recv_group_q <= '0;
                uop_fetch_ptr_q <= uop_fifo_ptr_inc(uop_fetch_ptr_q);
            end

            if (row_push) begin
                row_fifo_data[int'(fifo_wr_ptr_q)] <= sa_getacc_data_i;
                fifo_wr_ptr_q <= fifo_ptr_inc(fifo_wr_ptr_q);

                if (recv_last_group) begin
                    getacc_active_q <= 1'b0;
                    recv_group_q <= '0;
                end else begin
                    recv_group_q <= recv_group_q + GROUP_IDX_WIDTH'(1);
                end
            end

            if (fifo_pop_to_out) begin
                out_valid_q <= 1'b1;
                out_addr_q <= group_addr(
                    tile_base_addr(uop_addr_fifo[int'(uop_rd_ptr_q)]),
                    group_to_load);
                out_data_q <= row_fifo_data[int'(fifo_rd_ptr_q)];
                out_last_group_q <= group_to_load_is_last;
                fifo_rd_ptr_q <= fifo_ptr_inc(fifo_rd_ptr_q);
            end else if (mem_wr_fire) begin
                out_valid_q <= 1'b0;
                out_last_group_q <= 1'b0;
            end

            if (descriptor_pop) begin
                write_group_q <= '0;
                uop_rd_ptr_q <= uop_fifo_ptr_inc(uop_rd_ptr_q);
            end else if (mem_wr_fire && !out_last_group_q) begin
                write_group_q <= write_group_q + GROUP_IDX_WIDTH'(1);
            end

            unique case ({uop_fire, descriptor_pop})
                2'b10: uop_count_q <= uop_count_q + UOP_FIFO_CNT_WIDTH'(1);
                2'b01: uop_count_q <= uop_count_q - UOP_FIFO_CNT_WIDTH'(1);
                default: begin
                end
            endcase

            unique case ({uop_fire, sa_getacc_fire})
                2'b10: unfetched_count_q <=
                    unfetched_count_q + UOP_FIFO_CNT_WIDTH'(1);
                2'b01: unfetched_count_q <=
                    unfetched_count_q - UOP_FIFO_CNT_WIDTH'(1);
                default: begin
                end
            endcase

            unique case ({row_push, fifo_pop_to_out})
                2'b10: fifo_count_q <= fifo_count_q + FIFO_CNT_WIDTH'(1);
                2'b01: fifo_count_q <= fifo_count_q - FIFO_CNT_WIDTH'(1);
                default: begin
                end
            endcase
        end
    end

endmodule

`default_nettype wire
