// Store uop pipeline.
//
// A STORE/OUTPUT uop names one SA_WIDTH x SA_WIDTH FP32 output tile by an
// external tile-linear base address and one PACC index.  The unit requests the
// complete tile from the systolic array through getacc and receives one row
// per getacc_data_valid pulse.  Each row can then be split into
// ROW_WRITE_BEATS write-channel requests, where ROW_WRITE_BEATS must be one or
// a power of two.
//
// Addressing convention:
//   write beat address =
//       uop_addr_i * SA_WIDTH * ROW_WRITE_BEATS +
//       row_idx * ROW_WRITE_BEATS + beat_idx
//
// Pipeline structure:
//   1. uop accept: latch tile address and pacc index when enough row-FIFO space
//      is available for an entire SA response burst.
//   2. getacc request: hold sa_getacc_valid_o/paccidx stable until SA accepts.
//   3. row capture: push every SA getacc row into a row FIFO.  SA has no
//      backpressure on getacc_data, so the FIFO is sized to absorb a full tile.
//   4. write output: pop rows into a registered write-channel stage, split
//      them into ROW_WRITE_BEATS bus writes, preserve row/beat order, and hold
//      addr/data stable under bus backpressure.

`default_nettype none

module storeunit #(
    parameter int SA_WIDTH        = 4,
    parameter int PACC_NUM        = 16,
    parameter int ADDR_WIDTH      = 32,
    parameter int PACC_IDX_WIDTH  = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int ROW_IDX_WIDTH   = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH),
    parameter int ROW_DATA_WIDTH  = SA_WIDTH * 32,
    parameter int ROW_WRITE_BEATS = 1,
    parameter int BEAT_IDX_WIDTH  = (ROW_WRITE_BEATS <= 1) ? 1 : $clog2(ROW_WRITE_BEATS),
    parameter int MEM_DATA_WIDTH  = ROW_DATA_WIDTH / ROW_WRITE_BEATS,
    parameter int FIFO_DEPTH      = SA_WIDTH * 2,
    parameter int FIFO_IDX_WIDTH  = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH),
    parameter int FIFO_CNT_WIDTH  = (FIFO_DEPTH <= 1) ? 1 : $clog2(FIFO_DEPTH + 1)
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
    input  logic [ROW_DATA_WIDTH-1:0] sa_getacc_data_i,

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
        if (ROW_WRITE_BEATS <= 0) begin
            $error("ROW_WRITE_BEATS must be positive");
        end
        if ((ROW_WRITE_BEATS & (ROW_WRITE_BEATS - 1)) != 0) begin
            $error("ROW_WRITE_BEATS must be one or a power of two");
        end
        if ((ROW_DATA_WIDTH % ROW_WRITE_BEATS) != 0) begin
            $error("ROW_DATA_WIDTH must be divisible by ROW_WRITE_BEATS");
        end
        if (MEM_DATA_WIDTH != (ROW_DATA_WIDTH / ROW_WRITE_BEATS)) begin
            $error("MEM_DATA_WIDTH must equal ROW_DATA_WIDTH / ROW_WRITE_BEATS");
        end
        if (FIFO_DEPTH < SA_WIDTH) begin
            $error("FIFO_DEPTH must be at least SA_WIDTH");
        end
    end

    logic req_valid_q;
    logic [PACC_IDX_WIDTH-1:0] req_paccidx_q;
    logic [ADDR_WIDTH-1:0] req_row_base_q;

    logic getacc_active_q;
    logic [ROW_IDX_WIDTH-1:0] recv_row_q;
    logic [ADDR_WIDTH-1:0] active_row_base_q;

    logic [ADDR_WIDTH-1:0] fifo_addr [FIFO_DEPTH];
    logic [ROW_DATA_WIDTH-1:0] fifo_data [FIFO_DEPTH];
    logic fifo_last_row [FIFO_DEPTH];
    logic [FIFO_IDX_WIDTH-1:0] fifo_wr_ptr_q;
    logic [FIFO_IDX_WIDTH-1:0] fifo_rd_ptr_q;
    logic [FIFO_CNT_WIDTH-1:0] fifo_count_q;

    logic out_valid_q;
    logic [ADDR_WIDTH-1:0] out_addr_q;
    logic [ROW_DATA_WIDTH-1:0] out_data_q;
    logic out_last_row_q;
    logic [BEAT_IDX_WIDTH-1:0] out_beat_q;

    function automatic logic [ADDR_WIDTH-1:0] row_base_addr(
        input logic [ADDR_WIDTH-1:0] tile_addr
    );
        begin
            return tile_addr * ADDR_WIDTH'(SA_WIDTH * ROW_WRITE_BEATS);
        end
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] row_addr(
        input logic [ADDR_WIDTH-1:0] row_base,
        input logic [ROW_IDX_WIDTH-1:0] row_idx
    );
        begin
            return row_base + (ADDR_WIDTH'(row_idx) * ADDR_WIDTH'(ROW_WRITE_BEATS));
        end
    endfunction

    function automatic logic [MEM_DATA_WIDTH-1:0] beat_data(
        input logic [ROW_DATA_WIDTH-1:0] row_data,
        input logic [BEAT_IDX_WIDTH-1:0] beat_idx
    );
        begin
            return row_data[int'(beat_idx) * MEM_DATA_WIDTH +: MEM_DATA_WIDTH];
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

    wire [FIFO_CNT_WIDTH-1:0] fifo_free_count =
        FIFO_CNT_WIDTH'(FIFO_DEPTH) - fifo_count_q;
    wire fifo_has_full_tile_space =
        fifo_free_count >= FIFO_CNT_WIDTH'(SA_WIDTH);

    assign uop_ready_o = !req_valid_q && !getacc_active_q && fifo_has_full_tile_space;
    wire uop_fire = uop_valid_i && uop_ready_o;

    assign sa_getacc_valid_o = req_valid_q;
    assign sa_getacc_idx_o = req_paccidx_q;
    wire sa_getacc_fire = sa_getacc_valid_o && sa_getacc_ready_i;

    wire row_push = sa_getacc_data_valid_i && getacc_active_q;
    wire recv_last_row = int'(recv_row_q) == (SA_WIDTH - 1);

    wire mem_wr_fire = mem_wr_valid_o && mem_wr_ready_i;
    wire out_last_beat = int'(out_beat_q) == (ROW_WRITE_BEATS - 1);
    wire out_can_load_row = !out_valid_q || (mem_wr_fire && out_last_beat);
    wire fifo_pop_to_out = out_can_load_row && (fifo_count_q != '0);

    assign mem_wr_valid_o = out_valid_q;
    assign mem_wr_addr_o = out_addr_q + ADDR_WIDTH'(out_beat_q);
    assign mem_wr_data_o = beat_data(out_data_q, out_beat_q);
    assign done_valid_o = mem_wr_fire && out_last_beat && out_last_row_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_valid_q <= 1'b0;
            req_paccidx_q <= '0;
            req_row_base_q <= '0;
            getacc_active_q <= 1'b0;
            recv_row_q <= '0;
            active_row_base_q <= '0;
            fifo_wr_ptr_q <= '0;
            fifo_rd_ptr_q <= '0;
            fifo_count_q <= '0;
            out_valid_q <= 1'b0;
            out_addr_q <= '0;
            out_data_q <= '0;
            out_last_row_q <= 1'b0;
            out_beat_q <= '0;
            for (int i = 0; i < FIFO_DEPTH; i++) begin
                fifo_addr[i] <= '0;
                fifo_data[i] <= '0;
                fifo_last_row[i] <= 1'b0;
            end
        end else begin
            if (uop_fire) begin
                req_valid_q <= 1'b1;
                req_paccidx_q <= uop_paccidx_i;
                req_row_base_q <= row_base_addr(uop_addr_i);
            end

            if (sa_getacc_fire) begin
                req_valid_q <= 1'b0;
                getacc_active_q <= 1'b1;
                active_row_base_q <= req_row_base_q;
                recv_row_q <= '0;
            end

            if (row_push) begin
                fifo_addr[int'(fifo_wr_ptr_q)] <= row_addr(active_row_base_q, recv_row_q);
                fifo_data[int'(fifo_wr_ptr_q)] <= sa_getacc_data_i;
                fifo_last_row[int'(fifo_wr_ptr_q)] <= recv_last_row;
                fifo_wr_ptr_q <= fifo_ptr_inc(fifo_wr_ptr_q);

                if (recv_last_row) begin
                    getacc_active_q <= 1'b0;
                    recv_row_q <= '0;
                end else begin
                    recv_row_q <= recv_row_q + ROW_IDX_WIDTH'(1);
                end
            end

            if (fifo_pop_to_out) begin
                out_valid_q <= 1'b1;
                out_addr_q <= fifo_addr[int'(fifo_rd_ptr_q)];
                out_data_q <= fifo_data[int'(fifo_rd_ptr_q)];
                out_last_row_q <= fifo_last_row[int'(fifo_rd_ptr_q)];
                out_beat_q <= '0;
                fifo_rd_ptr_q <= fifo_ptr_inc(fifo_rd_ptr_q);
            end else if (mem_wr_fire && !out_last_beat) begin
                out_beat_q <= out_beat_q + BEAT_IDX_WIDTH'(1);
            end else if (mem_wr_fire) begin
                out_valid_q <= 1'b0;
                out_last_row_q <= 1'b0;
                out_beat_q <= '0;
            end

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
