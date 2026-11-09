// Generated shared package; do not edit.
// Source: src/sa/sa.sv
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
//      whose PACC index differs from the lanes started in the previous three
//      cycles. Only one lane can start in a cycle. This four-cycle same-PACC
//      interlock matches paccreg's input protocol and prevents an ACC read
//      request from colliding with the preceding result writeback in the
//      synchronous SRAM.
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


`default_nettype none

package sa_pkg;

    import paccreg_pkg::*;

    localparam int GETACC_REQUEST_DELAY = 1;
    localparam int GETACC_REDUCE_STAGES = 2;
    localparam int GETACC_FIRST_LATENCY =
        GETACC_REQUEST_DELAY + paccreg_pkg::GETACC_PIPE_STAGES +
        GETACC_REDUCE_STAGES;

endpackage

`default_nettype wire
