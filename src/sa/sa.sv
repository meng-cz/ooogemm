// Two-dimensional systolic array built from pe tiles.
//
// The array owns one ping-pong lane buffer per left row/lane and one per top
// column/lane. GEMM allocation reserves the current write-side buffer for one
// lane; matrix writes fill that reserved buffer; the scheduler flips one ready
// lane per cycle into the read side when that physical lane is idle or on its
// last active cycle.
//
// GEMM timing:
//   1. A command is accepted when gemm_valid && gemm_ready. gemm_alloc_lane is
//      chosen from lanes whose current write-side ping-pong slot is free. The
//      allocator treats both active work and already-allocated, not-yet-active
//      work as lane occupancy. A lane can accept a new command only when its
//      current write-side slot is free. Among those lanes, the allocator prefers
//      the lane that can leave active state soonest; ties use increasing lane
//      id, the same order used by the ready-lane start scanner. The accepted
//      command reserves that write-side slot and records gemm_instid,
//      gemm_paccidx, and gemm_accum in it.
//   2. After allocation, software/control logic writes the matrices into the
//      allocated lane with ain_laneidx/bin_laneidx. A valid A write fills all
//      left-row lane buffers for that lane; a valid B write fills all top-column
//      lane buffers for that lane. The B matrix is expected in transposed form:
//      bin_data[col][k] is B[k][col]. Each row/column payload carries
//      SUBTILE_K FP8 values.
//   3. Every cycle the scheduler scans lanes in increasing lane order and
//      chooses the first lane whose current write-side slot has both A and B
//      ready, whose physical lane is inactive or in its last active cycle, and
//      whose PACC index differs from the lane started in the immediately
//      previous cycle.  Only one lane can start in a cycle.  This one-cycle
//      same-PACC interlock matches paccreg's input protocol: paccreg accepts one
//      submission per cycle, but not two consecutive submissions to the same
//      paccidx; a legal N/N+2 same-PACC sequence uses paccreg's writeback-to-read
//      bypass.
//   4. The selected lane flips all of its A/B lane buffers on that clock edge.
//      On the following cycles, the lane is active for exactly SUBTILE_K cycles
//      and reads rdidx=0..SUBTILE_K-1 from the just-flipped read-side buffers.
//   5. During those active cycles, the left-edge stream asserts first on rdidx=0
//      and last on rdidx=SUBTILE_K-1. The saved paccidx/accum travel with the
//      left-edge stream and are consumed by each PE when its fdot sees last.
//      Row and column skew buffers delay the boundary streams so A[row][k] and
//      B[k][col] meet at PE[row][col]; PE forwarding then moves A right and B
//      down one cycle per tile.
//   6. If a lane is in its last active cycle and a ready slot for the same lane
//      is selected, the next GEMM starts without an inactive bubble. Otherwise
//      the lane becomes inactive after the last active cycle.
//   7. Once a lane starts, execution latency is fixed. gemm_finish is generated
//      by a conservative fixed-delay pipe from the start event, after the
//      farthest PE's fdot output has had time to write its paccreg. At that
//      point the reported gemm_finish_instid is safe for a later getacc.
//
// GETACC timing:
//   1. A request is accepted when getacc_valid && getacc_ready. A new request
//      can be accepted while idle or on the last active row of the prior request.
//   2. An accepted request enters a SUBTILE_M/GETACC_ROWS_PER_CYCLE-cycle scan.
//      Scan cycle N requests GETACC_ROWS_PER_CYCLE consecutive PE rows.
//   3. Each PE's paccreg returns FP32 after paccreg_pkg::GETACC_PIPE_STAGES.
//      Per column, all row results are valid-masked and reduced by a two-stage
//      OR tree per row slot, preserving all concurrently returned rows.
//   4. getacc_data_valid marks each output row group. Row slot R occupies
//      getacc_data[R*SUBTILE_N*32 +: SUBTILE_N*32], and groups are emitted in
//      increasing row order.
//   5. sa_pkg::GETACC_FIRST_LATENCY is the fixed latency from a successful
//      getacc handshake clock edge to the first row's getacc_data_valid.

`default_nettype none

package sa_pkg;

    import paccreg_pkg::*;

    localparam int GETACC_REQUEST_DELAY = 1;
    localparam int GETACC_REDUCE_STAGES = 2;
    localparam int GETACC_FIRST_LATENCY =
        GETACC_REQUEST_DELAY + paccreg_pkg::GETACC_PIPE_STAGES +
        GETACC_REDUCE_STAGES;

endpackage

module sa #(
    parameter int SA_WIDTH        = 4,
    // Compatibility default for the legacy square interface.
    parameter int SUBTILE_M      = SA_WIDTH,
    parameter int SUBTILE_N      = SA_WIDTH,
    parameter int SUBTILE_K       = 32,
    parameter int LANE_NUM        = 4,
    parameter int LANE_IDX_WIDTH  = (LANE_NUM <= 1) ? 1 : $clog2(LANE_NUM),
    parameter int PACC_NUM        = 16,
    parameter int PACC_IDX_WIDTH  = (PACC_NUM <= 1) ? 1 : $clog2(PACC_NUM),
    parameter int PACC_EXP_WIDTH  = 10,
    parameter int PACC_SIG_WIDTH  = 40,
    parameter int FDOT_ACC_WIDTH  = 96,
    parameter int FDOT_ACC_FRAC_BITS = 18,
    parameter int FDOT_CSA_WIDTH  = FDOT_ACC_WIDTH + 2,
    parameter int GEMM_INSTID_WIDTH = 16,
    parameter int K_IDX_WIDTH     = (SUBTILE_K <= 1) ? 1 : $clog2(SUBTILE_K),
    parameter int GETACC_ROWS_PER_CYCLE = 1,
    parameter int GETACC_GROUPS_PER_TILE = SUBTILE_M / GETACC_ROWS_PER_CYCLE,
    parameter int GETACC_GROUP_IDX_WIDTH =
        (GETACC_GROUPS_PER_TILE <= 1) ? 1 : $clog2(GETACC_GROUPS_PER_TILE)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic ain_valid,
    input  logic [SUBTILE_K*8-1:0] ain_data [SUBTILE_M],
    input  logic [LANE_IDX_WIDTH-1:0] ain_laneidx,

    input  logic bin_valid,
    input  logic [SUBTILE_K*8-1:0] bin_data [SUBTILE_N],
    input  logic [LANE_IDX_WIDTH-1:0] bin_laneidx,

    input  logic gemm_valid,
    output logic gemm_ready,
    output logic [LANE_IDX_WIDTH-1:0] gemm_alloc_lane,
    input  logic [GEMM_INSTID_WIDTH-1:0] gemm_instid,
    input  logic [PACC_IDX_WIDTH-1:0] gemm_paccidx,
    input  logic gemm_accum,

    output logic gemm_finish,
    output logic [GEMM_INSTID_WIDTH-1:0] gemm_finish_instid,

    input  logic getacc_valid,
    output logic getacc_ready,
    input  logic [PACC_IDX_WIDTH-1:0] getacc_idx,

    output logic getacc_data_valid,
    output logic [SUBTILE_N*32*GETACC_ROWS_PER_CYCLE-1:0] getacc_data
);

    import fdot8e4m3_pkg::*;
    import paccreg_pkg::*;

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (SUBTILE_M <= 0) begin
            $error("SUBTILE_M must be positive");
        end
        if (SUBTILE_N <= 0) begin
            $error("SUBTILE_N must be positive");
        end
        if (SUBTILE_K <= 0) begin
            $error("SUBTILE_K must be positive");
        end
        if ((SUBTILE_M & (SUBTILE_M - 1)) != 0) begin
            $error("SUBTILE_M must be a power of two");
        end
        if ((SUBTILE_N & (SUBTILE_N - 1)) != 0) begin
            $error("SUBTILE_N must be a power of two");
        end
        if ((SUBTILE_K & (SUBTILE_K - 1)) != 0) begin
            $error("SUBTILE_K must be a power of two");
        end
        if (LANE_NUM <= 0) begin
            $error("LANE_NUM must be positive");
        end
        if (LANE_IDX_WIDTH <= 0) begin
            $error("LANE_IDX_WIDTH must be positive");
        end
        if (PACC_NUM <= 0) begin
            $error("PACC_NUM must be positive");
        end
        if (PACC_IDX_WIDTH <= 0) begin
            $error("PACC_IDX_WIDTH must be positive");
        end
        if (GETACC_ROWS_PER_CYCLE <= 0 ||
            GETACC_ROWS_PER_CYCLE > SUBTILE_M) begin
            $error("GETACC_ROWS_PER_CYCLE must be in [1, SUBTILE_M]");
        end
        if ((SUBTILE_M % GETACC_ROWS_PER_CYCLE) != 0) begin
            $error("SUBTILE_M must be divisible by GETACC_ROWS_PER_CYCLE");
        end
    end

    localparam int FDOT_TO_PACC_REDUCE_STAGES = 1;
    localparam int GEMM_FINISH_LATENCY =
        (SUBTILE_M + SUBTILE_N) + SUBTILE_K +
        fdot8e4m3_pkg::LAST_TO_OUT_LATENCY +
        FDOT_TO_PACC_REDUCE_STAGES + paccreg_pkg::ACCUM_PIPE_STAGES + 3;

    logic slot_in_use [LANE_NUM][2];
    logic slot_a_ready [LANE_NUM][2];
    logic slot_b_ready [LANE_NUM][2];
    logic [GEMM_INSTID_WIDTH-1:0] slot_instid [LANE_NUM][2];
    logic [PACC_IDX_WIDTH-1:0] slot_paccidx [LANE_NUM][2];
    logic slot_accum [LANE_NUM][2];

    logic lane_rd_sel [LANE_NUM];
    logic lane_active [LANE_NUM];
    logic [K_IDX_WIDTH-1:0] lane_count [LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] lane_paccidx [LANE_NUM];
    logic lane_accum [LANE_NUM];
    logic last_start_valid_q;
    logic [PACC_IDX_WIDTH-1:0] last_start_paccidx_q;

    logic [1:0] lane_wr_slot [LANE_NUM];
    logic [1:0] lane_rd_slot [LANE_NUM];
    logic lane_last_cycle [LANE_NUM];

    always_comb begin
        for (int lane = 0; lane < LANE_NUM; lane++) begin
            lane_rd_slot[lane] = {1'b0, lane_rd_sel[lane]};
            lane_wr_slot[lane] = {1'b0, ~lane_rd_sel[lane]};
            lane_last_cycle[lane] = lane_active[lane] &&
                (int'(lane_count[lane]) == (SUBTILE_K - 1));
        end
    end

    logic alloc_found;
    logic [LANE_IDX_WIDTH-1:0] alloc_lane_comb;
    logic lane_alloc_pending_comb [LANE_NUM];
    logic lane_alloc_available_comb [LANE_NUM];
    int alloc_wait_comb [LANE_NUM];
    int alloc_best_wait_comb;

    always_comb begin
        alloc_found = 1'b0;
        alloc_lane_comb = '0;
        alloc_best_wait_comb = SUBTILE_K;
        for (int lane = 0; lane < LANE_NUM; lane++) begin
            lane_alloc_pending_comb[lane] =
                slot_in_use[lane][lane_wr_slot[lane][0]];
            lane_alloc_available_comb[lane] =
                !lane_alloc_pending_comb[lane];

            if (lane_active[lane]) begin
                alloc_wait_comb[lane] = (SUBTILE_K - 1) - int'(lane_count[lane]);
            end else if (lane_alloc_pending_comb[lane]) begin
                alloc_wait_comb[lane] = SUBTILE_K;
            end else begin
                alloc_wait_comb[lane] = 0;
            end

            if (lane_alloc_available_comb[lane] &&
                (!alloc_found ||
                 (alloc_wait_comb[lane] < alloc_best_wait_comb))) begin
                alloc_found = 1'b1;
                alloc_lane_comb = lane[LANE_IDX_WIDTH-1:0];
                alloc_best_wait_comb = alloc_wait_comb[lane];
            end
        end
    end

    assign gemm_ready = alloc_found;
    assign gemm_alloc_lane = alloc_lane_comb;

    wire gemm_fire = gemm_valid && gemm_ready;

    logic start_found;
    logic [LANE_IDX_WIDTH-1:0] start_lane_comb;
    logic [GEMM_INSTID_WIDTH-1:0] start_instid_comb;

    always_comb begin
        start_found = 1'b0;
        start_lane_comb = '0;
        start_instid_comb = '0;
        for (int lane = 0; lane < LANE_NUM; lane++) begin
            if (!start_found &&
                slot_in_use[lane][lane_wr_slot[lane][0]] &&
                slot_a_ready[lane][lane_wr_slot[lane][0]] &&
                slot_b_ready[lane][lane_wr_slot[lane][0]] &&
                (!lane_active[lane] || lane_last_cycle[lane]) &&
                !(last_start_valid_q &&
                  (slot_paccidx[lane][lane_wr_slot[lane][0]] == last_start_paccidx_q))) begin
                start_found = 1'b1;
                start_lane_comb = lane[LANE_IDX_WIDTH-1:0];
                start_instid_comb = slot_instid[lane][lane_wr_slot[lane][0]];
            end
        end
    end

    logic start_lane [LANE_NUM];

    always_comb begin
        for (int lane = 0; lane < LANE_NUM; lane++) begin
            start_lane[lane] = start_found &&
                (start_lane_comb == lane[LANE_IDX_WIDTH-1:0]);
        end
    end

    logic a_buf_valid [SUBTILE_M][LANE_NUM];
    logic b_buf_valid [SUBTILE_N][LANE_NUM];
    logic [7:0] a_buf_rddata [SUBTILE_M][LANE_NUM];
    logic [7:0] b_buf_rddata [SUBTILE_N][LANE_NUM];

    always_comb begin
        for (int row = 0; row < SUBTILE_M; row++) begin
            for (int lane = 0; lane < LANE_NUM; lane++) begin
                a_buf_valid[row][lane] = ain_valid &&
                    (ain_laneidx == lane[LANE_IDX_WIDTH-1:0]) &&
                    slot_in_use[lane][lane_wr_slot[lane][0]] &&
                    !slot_a_ready[lane][lane_wr_slot[lane][0]];
            end
        end

        for (int col = 0; col < SUBTILE_N; col++) begin
            for (int lane = 0; lane < LANE_NUM; lane++) begin
                b_buf_valid[col][lane] = bin_valid &&
                    (bin_laneidx == lane[LANE_IDX_WIDTH-1:0]) &&
                    slot_in_use[lane][lane_wr_slot[lane][0]] &&
                    !slot_b_ready[lane][lane_wr_slot[lane][0]];
            end
        end
    end

    genvar buf_row;
    genvar buf_col;
    genvar buf_lane;
    generate
        for (buf_row = 0; buf_row < SUBTILE_M; buf_row++) begin : gen_a_lanebuf_row
            for (buf_lane = 0; buf_lane < LANE_NUM; buf_lane++) begin : gen_a_lanebuf_lane
                lanebuf #(
                    .SA_WIDTH(SUBTILE_M),
                    .SUBTILE_K(SUBTILE_K),
                    .K_IDX_WIDTH(K_IDX_WIDTH)
                ) u_a_lanebuf (
                    .clk(clk),
                    .rst_n(rst_n),
                    .valid(a_buf_valid[buf_row][buf_lane]),
                    .linedata(ain_data[buf_row]),
                    .flip(start_lane[buf_lane]),
                    .rdidx(lane_count[buf_lane]),
                    .rddata(a_buf_rddata[buf_row][buf_lane])
                );
            end
        end

        for (buf_col = 0; buf_col < SUBTILE_N; buf_col++) begin : gen_b_lanebuf_col
            for (buf_lane = 0; buf_lane < LANE_NUM; buf_lane++) begin : gen_b_lanebuf_lane
                lanebuf #(
                    .SA_WIDTH(SUBTILE_N),
                    .SUBTILE_K(SUBTILE_K),
                    .K_IDX_WIDTH(K_IDX_WIDTH)
                ) u_b_lanebuf (
                    .clk(clk),
                    .rst_n(rst_n),
                    .valid(b_buf_valid[buf_col][buf_lane]),
                    .linedata(bin_data[buf_col]),
                    .flip(start_lane[buf_lane]),
                    .rdidx(lane_count[buf_lane]),
                    .rddata(b_buf_rddata[buf_col][buf_lane])
                );
            end
        end
    endgenerate

    logic a_src_valid [SUBTILE_M][LANE_NUM];
    logic [7:0] a_src_data [SUBTILE_M][LANE_NUM];
    logic a_src_first [SUBTILE_M][LANE_NUM];
    logic a_src_last [SUBTILE_M][LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] a_src_paccidx [SUBTILE_M][LANE_NUM];
    logic a_src_accum [SUBTILE_M][LANE_NUM];
    logic [7:0] b_src_data [SUBTILE_N][LANE_NUM];

    always_comb begin
        for (int row = 0; row < SUBTILE_M; row++) begin
            for (int lane = 0; lane < LANE_NUM; lane++) begin
                a_src_valid[row][lane] = lane_active[lane];
                a_src_data[row][lane] = a_buf_rddata[row][lane];
                a_src_first[row][lane] = lane_active[lane] &&
                    (int'(lane_count[lane]) == 0);
                a_src_last[row][lane] = lane_last_cycle[lane];
                a_src_paccidx[row][lane] = lane_paccidx[lane];
                a_src_accum[row][lane] = lane_accum[lane];
            end
        end

        for (int col = 0; col < SUBTILE_N; col++) begin
            for (int lane = 0; lane < LANE_NUM; lane++) begin
                b_src_data[col][lane] = b_buf_rddata[col][lane];
            end
        end
    end

    logic a_skew_valid [SUBTILE_M][LANE_NUM];
    logic [7:0] a_skew_data [SUBTILE_M][LANE_NUM];
    logic a_skew_first [SUBTILE_M][LANE_NUM];
    logic a_skew_last [SUBTILE_M][LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] a_skew_paccidx [SUBTILE_M][LANE_NUM];
    logic a_skew_accum [SUBTILE_M][LANE_NUM];
    logic [7:0] b_skew_data [SUBTILE_N][LANE_NUM];

    genvar skew_row;
    genvar skew_col;
    genvar skew_lane;
    generate
        for (skew_row = 0; skew_row < SUBTILE_M; skew_row++) begin : gen_a_skew_row
            for (skew_lane = 0; skew_lane < LANE_NUM; skew_lane++) begin : gen_a_skew_lane
                if (skew_row == 0) begin : gen_a_no_skew
                    assign a_skew_valid[skew_row][skew_lane] =
                        a_src_valid[skew_row][skew_lane];
                    assign a_skew_data[skew_row][skew_lane] =
                        a_src_data[skew_row][skew_lane];
                    assign a_skew_first[skew_row][skew_lane] =
                        a_src_first[skew_row][skew_lane];
                    assign a_skew_last[skew_row][skew_lane] =
                        a_src_last[skew_row][skew_lane];
                    assign a_skew_paccidx[skew_row][skew_lane] =
                        a_src_paccidx[skew_row][skew_lane];
                    assign a_skew_accum[skew_row][skew_lane] =
                        a_src_accum[skew_row][skew_lane];
                end else begin : gen_a_skew_pipe
                    logic valid_q [skew_row];
                    logic [7:0] data_q [skew_row];
                    logic first_q [skew_row];
                    logic last_q [skew_row];
                    logic [PACC_IDX_WIDTH-1:0] paccidx_q [skew_row];
                    logic accum_q [skew_row];

                    always_ff @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            for (int i = 0; i < skew_row; i++) begin
                                valid_q[i] <= 1'b0;
                                data_q[i] <= 8'd0;
                                first_q[i] <= 1'b0;
                                last_q[i] <= 1'b0;
                                paccidx_q[i] <= '0;
                                accum_q[i] <= 1'b0;
                            end
                        end else begin
                            valid_q[0] <= a_src_valid[skew_row][skew_lane];
                            data_q[0] <= a_src_data[skew_row][skew_lane];
                            first_q[0] <= a_src_first[skew_row][skew_lane];
                            last_q[0] <= a_src_last[skew_row][skew_lane];
                            paccidx_q[0] <= a_src_paccidx[skew_row][skew_lane];
                            accum_q[0] <= a_src_accum[skew_row][skew_lane];
                            for (int i = 1; i < skew_row; i++) begin
                                valid_q[i] <= valid_q[i-1];
                                data_q[i] <= data_q[i-1];
                                first_q[i] <= first_q[i-1];
                                last_q[i] <= last_q[i-1];
                                paccidx_q[i] <= paccidx_q[i-1];
                                accum_q[i] <= accum_q[i-1];
                            end
                        end
                    end

                    assign a_skew_valid[skew_row][skew_lane] = valid_q[skew_row-1];
                    assign a_skew_data[skew_row][skew_lane] = data_q[skew_row-1];
                    assign a_skew_first[skew_row][skew_lane] = first_q[skew_row-1];
                    assign a_skew_last[skew_row][skew_lane] = last_q[skew_row-1];
                    assign a_skew_paccidx[skew_row][skew_lane] =
                        paccidx_q[skew_row-1];
                    assign a_skew_accum[skew_row][skew_lane] = accum_q[skew_row-1];
                end
            end
        end

        for (skew_col = 0; skew_col < SUBTILE_N; skew_col++) begin : gen_b_skew_col
            for (skew_lane = 0; skew_lane < LANE_NUM; skew_lane++) begin : gen_b_skew_lane
                if (skew_col == 0) begin : gen_b_no_skew
                    assign b_skew_data[skew_col][skew_lane] =
                        b_src_data[skew_col][skew_lane];
                end else begin : gen_b_skew_pipe
                    logic [7:0] data_q [skew_col];

                    always_ff @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            for (int i = 0; i < skew_col; i++) begin
                                data_q[i] <= 8'd0;
                            end
                        end else begin
                            data_q[0] <= b_src_data[skew_col][skew_lane];
                            for (int i = 1; i < skew_col; i++) begin
                                data_q[i] <= data_q[i-1];
                            end
                        end
                    end

                    assign b_skew_data[skew_col][skew_lane] = data_q[skew_col-1];
                end
            end
        end
    endgenerate

    logic pe_left_valid [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [7:0] pe_left_a [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_left_first [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_left_last [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] pe_left_paccidx [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_left_accum [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [7:0] pe_top_b [SUBTILE_M][SUBTILE_N][LANE_NUM];

    logic pe_right_valid [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [7:0] pe_right_a [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_right_first [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_right_last [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [PACC_IDX_WIDTH-1:0] pe_right_paccidx [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic pe_right_accum [SUBTILE_M][SUBTILE_N][LANE_NUM];
    logic [7:0] pe_bottom_b [SUBTILE_M][SUBTILE_N][LANE_NUM];

    logic pe_getacc_i [SUBTILE_M][SUBTILE_N];
    logic [PACC_IDX_WIDTH-1:0] pe_getacc_idx_i [SUBTILE_M][SUBTILE_N];
    logic pe_getacc_o [SUBTILE_M][SUBTILE_N];
    logic [31:0] pe_getacc_data_o [SUBTILE_M][SUBTILE_N];

    logic getacc_active;
    logic [GETACC_GROUP_IDX_WIDTH-1:0] getacc_count;
    logic [PACC_IDX_WIDTH-1:0] getacc_idx_q;
    logic getacc_last_cycle;

    assign getacc_last_cycle = getacc_active &&
        (int'(getacc_count) == (GETACC_GROUPS_PER_TILE - 1));
    assign getacc_ready = !getacc_active || getacc_last_cycle;

    wire getacc_fire = getacc_valid && getacc_ready;

    genvar pe_row;
    genvar pe_col;
    genvar pe_lane;
    generate
        for (pe_row = 0; pe_row < SUBTILE_M; pe_row++) begin : gen_pe_row
            for (pe_col = 0; pe_col < SUBTILE_N; pe_col++) begin : gen_pe_col
                for (pe_lane = 0; pe_lane < LANE_NUM; pe_lane++) begin : gen_pe_input_lane
                    if (pe_col == 0) begin : gen_from_left_edge
                        assign pe_left_valid[pe_row][pe_col][pe_lane] =
                            a_skew_valid[pe_row][pe_lane];
                        assign pe_left_a[pe_row][pe_col][pe_lane] =
                            a_skew_data[pe_row][pe_lane];
                        assign pe_left_first[pe_row][pe_col][pe_lane] =
                            a_skew_first[pe_row][pe_lane];
                        assign pe_left_last[pe_row][pe_col][pe_lane] =
                            a_skew_last[pe_row][pe_lane];
                        assign pe_left_paccidx[pe_row][pe_col][pe_lane] =
                            a_skew_paccidx[pe_row][pe_lane];
                        assign pe_left_accum[pe_row][pe_col][pe_lane] =
                            a_skew_accum[pe_row][pe_lane];
                    end else begin : gen_from_left_pe
                        assign pe_left_valid[pe_row][pe_col][pe_lane] =
                            pe_right_valid[pe_row][pe_col-1][pe_lane];
                        assign pe_left_a[pe_row][pe_col][pe_lane] =
                            pe_right_a[pe_row][pe_col-1][pe_lane];
                        assign pe_left_first[pe_row][pe_col][pe_lane] =
                            pe_right_first[pe_row][pe_col-1][pe_lane];
                        assign pe_left_last[pe_row][pe_col][pe_lane] =
                            pe_right_last[pe_row][pe_col-1][pe_lane];
                        assign pe_left_paccidx[pe_row][pe_col][pe_lane] =
                            pe_right_paccidx[pe_row][pe_col-1][pe_lane];
                        assign pe_left_accum[pe_row][pe_col][pe_lane] =
                            pe_right_accum[pe_row][pe_col-1][pe_lane];
                    end

                    if (pe_row == 0) begin : gen_from_top_edge
                        assign pe_top_b[pe_row][pe_col][pe_lane] =
                            b_skew_data[pe_col][pe_lane];
                    end else begin : gen_from_top_pe
                        assign pe_top_b[pe_row][pe_col][pe_lane] =
                            pe_bottom_b[pe_row-1][pe_col][pe_lane];
                    end
                end

                assign pe_getacc_i[pe_row][pe_col] = getacc_active &&
                    (pe_row >= (int'(getacc_count) * GETACC_ROWS_PER_CYCLE)) &&
                    (pe_row < ((int'(getacc_count) + 1) *
                               GETACC_ROWS_PER_CYCLE));
                assign pe_getacc_idx_i[pe_row][pe_col] = getacc_idx_q;

                pe #(
                    .GEMM_LANE_NUM(LANE_NUM),
                    .PACC_NUM(PACC_NUM),
                    .PACC_IDX_WIDTH(PACC_IDX_WIDTH),
                    .PACC_EXP_WIDTH(PACC_EXP_WIDTH),
                    .PACC_SIG_WIDTH(PACC_SIG_WIDTH),
                    .FDOT_ACC_WIDTH(FDOT_ACC_WIDTH),
                    .FDOT_ACC_FRAC_BITS(FDOT_ACC_FRAC_BITS),
                    .FDOT_CSA_WIDTH(FDOT_CSA_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .left_valid_i(pe_left_valid[pe_row][pe_col]),
                    .left_a_i(pe_left_a[pe_row][pe_col]),
                    .left_first_i(pe_left_first[pe_row][pe_col]),
                    .left_last_i(pe_left_last[pe_row][pe_col]),
                    .left_paccidx_i(pe_left_paccidx[pe_row][pe_col]),
                    .left_accum_i(pe_left_accum[pe_row][pe_col]),
                    .right_valid_o(pe_right_valid[pe_row][pe_col]),
                    .right_a_o(pe_right_a[pe_row][pe_col]),
                    .right_first_o(pe_right_first[pe_row][pe_col]),
                    .right_last_o(pe_right_last[pe_row][pe_col]),
                    .right_paccidx_o(pe_right_paccidx[pe_row][pe_col]),
                    .right_accum_o(pe_right_accum[pe_row][pe_col]),
                    .top_b_i(pe_top_b[pe_row][pe_col]),
                    .bottom_b_o(pe_bottom_b[pe_row][pe_col]),
                    .getacc_i(pe_getacc_i[pe_row][pe_col]),
                    .getacc_idx_i(pe_getacc_idx_i[pe_row][pe_col]),
                    .getacc_o(pe_getacc_o[pe_row][pe_col]),
                    .getacc_data_o(pe_getacc_data_o[pe_row][pe_col])
                );
            end
        end
    endgenerate

    logic finish_pipe_valid [GEMM_FINISH_LATENCY];
    logic [GEMM_INSTID_WIDTH-1:0] finish_pipe_instid [GEMM_FINISH_LATENCY];

    logic reduce_s1_valid [GETACC_ROWS_PER_CYCLE][SUBTILE_N][2];
    logic [31:0] reduce_s1_data [GETACC_ROWS_PER_CYCLE][SUBTILE_N][2];
    logic reduce_s1_valid_comb [GETACC_ROWS_PER_CYCLE][SUBTILE_N][2];
    logic [31:0] reduce_s1_data_comb [GETACC_ROWS_PER_CYCLE][SUBTILE_N][2];
    logic reduce_s1_any_comb [GETACC_ROWS_PER_CYCLE][SUBTILE_N];
    logic [31:0] reduce_s1_or_comb [GETACC_ROWS_PER_CYCLE][SUBTILE_N];
    logic reduce_s1_any_all_comb;

    always_comb begin
        reduce_s1_any_all_comb = 1'b0;
        for (int slot = 0; slot < GETACC_ROWS_PER_CYCLE; slot++) begin
            for (int col = 0; col < SUBTILE_N; col++) begin
                for (int part = 0; part < 2; part++) begin
                    reduce_s1_valid_comb[slot][col][part] = 1'b0;
                    reduce_s1_data_comb[slot][col][part] = 32'd0;
                end

                for (int row = 0; row < SUBTILE_M; row++) begin
                    int part;
                    part = (row < ((SUBTILE_M + 1) / 2)) ? 0 : 1;
                    if ((row % GETACC_ROWS_PER_CYCLE) == slot) begin
                        reduce_s1_valid_comb[slot][col][part] |=
                            pe_getacc_o[row][col];
                        reduce_s1_data_comb[slot][col][part] |=
                            pe_getacc_data_o[row][col] &
                            {32{pe_getacc_o[row][col]}};
                    end
                end

                reduce_s1_any_comb[slot][col] =
                    reduce_s1_valid[slot][col][0] |
                    reduce_s1_valid[slot][col][1];
                reduce_s1_or_comb[slot][col] =
                    (reduce_s1_data[slot][col][0] &
                     {32{reduce_s1_valid[slot][col][0]}}) |
                    (reduce_s1_data[slot][col][1] &
                     {32{reduce_s1_valid[slot][col][1]}});
                reduce_s1_any_all_comb |= reduce_s1_any_comb[slot][col];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int lane = 0; lane < LANE_NUM; lane++) begin
                lane_rd_sel[lane] <= 1'b0;
                lane_active[lane] <= 1'b0;
                lane_count[lane] <= '0;
                lane_paccidx[lane] <= '0;
                lane_accum[lane] <= 1'b0;

                for (int slot = 0; slot < 2; slot++) begin
                    slot_in_use[lane][slot] <= 1'b0;
                    slot_a_ready[lane][slot] <= 1'b0;
                    slot_b_ready[lane][slot] <= 1'b0;
                    slot_instid[lane][slot] <= '0;
                    slot_paccidx[lane][slot] <= '0;
                    slot_accum[lane][slot] <= 1'b0;
                end
            end

            for (int i = 0; i < GEMM_FINISH_LATENCY; i++) begin
                finish_pipe_valid[i] <= 1'b0;
                finish_pipe_instid[i] <= '0;
            end
            gemm_finish <= 1'b0;
            gemm_finish_instid <= '0;
            last_start_valid_q <= 1'b0;
            last_start_paccidx_q <= '0;

            getacc_active <= 1'b0;
            getacc_count <= '0;
            getacc_idx_q <= '0;

            for (int slot = 0; slot < GETACC_ROWS_PER_CYCLE; slot++) begin
                for (int col = 0; col < SUBTILE_N; col++) begin
                    for (int part = 0; part < 2; part++) begin
                        reduce_s1_valid[slot][col][part] <= 1'b0;
                        reduce_s1_data[slot][col][part] <= 32'd0;
                    end
                    getacc_data[(slot*SUBTILE_N+col)*32 +: 32] <= 32'd0;
                end
            end
            getacc_data_valid <= 1'b0;
        end else begin
            if (gemm_fire) begin
                slot_in_use[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <= 1'b1;
                slot_a_ready[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <= 1'b0;
                slot_b_ready[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <= 1'b0;
                slot_instid[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <=
                    gemm_instid;
                slot_paccidx[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <=
                    gemm_paccidx;
                slot_accum[alloc_lane_comb][lane_wr_slot[alloc_lane_comb][0]] <=
                    gemm_accum;
            end

            if (ain_valid && (int'(ain_laneidx) < LANE_NUM) &&
                slot_in_use[ain_laneidx][lane_wr_slot[ain_laneidx][0]]) begin
                slot_a_ready[ain_laneidx][lane_wr_slot[ain_laneidx][0]] <= 1'b1;
            end

            if (bin_valid && (int'(bin_laneidx) < LANE_NUM) &&
                slot_in_use[bin_laneidx][lane_wr_slot[bin_laneidx][0]]) begin
                slot_b_ready[bin_laneidx][lane_wr_slot[bin_laneidx][0]] <= 1'b1;
            end

            for (int lane = 0; lane < LANE_NUM; lane++) begin
                if (lane_last_cycle[lane]) begin
                    slot_in_use[lane][lane_rd_slot[lane][0]] <= 1'b0;
                    slot_a_ready[lane][lane_rd_slot[lane][0]] <= 1'b0;
                    slot_b_ready[lane][lane_rd_slot[lane][0]] <= 1'b0;
                end

                if (start_lane[lane]) begin
                    lane_rd_sel[lane] <= ~lane_rd_sel[lane];
                    lane_active[lane] <= 1'b1;
                    lane_count[lane] <= '0;
                    lane_paccidx[lane] <=
                        slot_paccidx[lane][lane_wr_slot[lane][0]];
                    lane_accum[lane] <=
                        slot_accum[lane][lane_wr_slot[lane][0]];
                end else if (lane_active[lane]) begin
                    if (lane_last_cycle[lane]) begin
                        lane_active[lane] <= 1'b0;
                        lane_count[lane] <= '0;
                    end else begin
                        lane_count[lane] <= lane_count[lane] +
                            {{(K_IDX_WIDTH-1){1'b0}}, 1'b1};
                    end
                end
            end

            last_start_valid_q <= start_found;
            if (start_found) begin
                last_start_paccidx_q <=
                    slot_paccidx[start_lane_comb][lane_wr_slot[start_lane_comb][0]];
            end

            finish_pipe_valid[0] <= start_found;
            finish_pipe_instid[0] <= start_instid_comb;
            for (int i = 1; i < GEMM_FINISH_LATENCY; i++) begin
                finish_pipe_valid[i] <= finish_pipe_valid[i-1];
                finish_pipe_instid[i] <= finish_pipe_instid[i-1];
            end
            gemm_finish <= finish_pipe_valid[GEMM_FINISH_LATENCY-1];
            gemm_finish_instid <= finish_pipe_instid[GEMM_FINISH_LATENCY-1];

            if (getacc_active) begin
                if (getacc_fire) begin
                    getacc_active <= 1'b1;
                    getacc_count <= '0;
                    getacc_idx_q <= getacc_idx;
                end else if (getacc_last_cycle) begin
                    getacc_active <= 1'b0;
                    getacc_count <= '0;
                end else begin
                    getacc_count <= getacc_count +
                        GETACC_GROUP_IDX_WIDTH'(1);
                end
            end else if (getacc_fire) begin
                getacc_active <= 1'b1;
                getacc_count <= '0;
                getacc_idx_q <= getacc_idx;
            end

            for (int slot = 0; slot < GETACC_ROWS_PER_CYCLE; slot++) begin
                for (int col = 0; col < SUBTILE_N; col++) begin
                    for (int part = 0; part < 2; part++) begin
                        reduce_s1_valid[slot][col][part] <=
                            reduce_s1_valid_comb[slot][col][part];
                        reduce_s1_data[slot][col][part] <=
                            reduce_s1_data_comb[slot][col][part];
                    end
                    getacc_data[(slot*SUBTILE_N+col)*32 +: 32] <=
                        reduce_s1_or_comb[slot][col];
                end
            end
            getacc_data_valid <= reduce_s1_any_all_comb;
        end
    end

endmodule

`default_nettype wire
