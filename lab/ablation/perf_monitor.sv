// Read-only simulation instrumentation. Reasons travel with bubbles through
// exactly the row skew + PE forwarding + PE input-register latency.
module ablation_perf_monitor #(
    parameter int M=8, N=8, LANES=1
) (
    input logic clk, rst_n,
    input logic [3:0] upstream_reason_i,
    input logic lane_active_i [LANES],
    input logic pending_i [LANES],
    input logic operands_ready_i [LANES],
    input logic hazard_i [LANES],
    input logic start_i [LANES],
    input logic mac_valid_i [M][N][LANES],
    output logic [31:0] lane_active_o,
    output logic [31:0] lane_idle_o [16],
    output logic [31:0] mac_active_o,
    output logic [31:0] mac_idle_o [16]
);
    logic [3:0] reason [LANES];
    logic [3:0] history [M+N][LANES];
    always_comb begin
        lane_active_o = '0;
        mac_active_o = '0;
        for (int r=0; r<16; r++) begin
            lane_idle_o[r] = '0;
            mac_idle_o[r] = '0;
        end
        for (int lane=0; lane<LANES; lane++) begin
            reason[lane] = upstream_reason_i;
            if (lane_active_i[lane]) begin
                reason[lane] = 0;
                lane_active_o = lane_active_o + 1;
            end else begin
                if (pending_i[lane]) begin
                    if (!operands_ready_i[lane] || start_i[lane]) reason[lane] = 10;
                    else if (hazard_i[lane]) reason[lane] = 8;
                    else reason[lane] = 9;
                end
                lane_idle_o[reason[lane]] = lane_idle_o[reason[lane]] + 1;
            end
        end
        for (int row=0; row<M; row++) begin
            for (int col=0; col<N; col++) begin
                for (int lane=0; lane<LANES; lane++) begin
                    if (mac_valid_i[row][col][lane]) mac_active_o = mac_active_o + 1;
                    else mac_idle_o[history[row+col][lane]] =
                        mac_idle_o[history[row+col][lane]] + 1;
                end
            end
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int d=0; d<M+N; d++) begin
                for (int lane=0; lane<LANES; lane++) history[d][lane] <= 14;
            end
        end else begin
            for (int lane=0; lane<LANES; lane++) history[0][lane] <= reason[lane];
            for (int d=1; d<M+N; d++) begin
                for (int lane=0; lane<LANES; lane++) history[d][lane] <= history[d-1][lane];
            end
            for (int row=0; row<M; row++) begin
                for (int col=0; col<N; col++) begin
                    for (int lane=0; lane<LANES; lane++) begin
                        assert ((history[row+col][lane] == 0) == mac_valid_i[row][col][lane])
                            else $fatal(1, "MAC bubble reason is misaligned with data validity");
                    end
                end
            end
        end
    end
endmodule
