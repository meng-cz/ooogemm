
logic [3:0] perf_upstream_reason;
logic perf_pending [LANE_NUM], perf_operands_ready [LANE_NUM], perf_hazard [LANE_NUM];
for (genvar pl=0; pl<LANE_NUM; pl++) begin : gen_perf_lane
    assign perf_pending[pl] = sa_impl.slot_in_use[pl][sa_impl.lane_wr_slot[pl][0]];
    assign perf_operands_ready[pl] = sa_impl.slot_a_ready[pl][sa_impl.lane_wr_slot[pl][0]] &&
        sa_impl.slot_b_ready[pl][sa_impl.lane_wr_slot[pl][0]];
    always_comb begin
        perf_hazard[pl] = 1'b0;
        for (int recent=0; recent<3; recent++) begin
            if (sa_impl.recent_start_valid_q[recent] &&
                sa_impl.slot_paccidx[pl][sa_impl.lane_wr_slot[pl][0]] ==
                sa_impl.recent_start_paccidx_q[recent]) perf_hazard[pl] = 1'b1;
        end
    end
end
ablation_perf_monitor #(.M(SUBTILE_M), .N(SUBTILE_N), .LANES(LANE_NUM)) perf_monitor (
    .clk(clk), .rst_n(rst_n), .upstream_reason_i(perf_upstream_reason),
    .lane_active_i(sa_impl.lane_active), .pending_i(perf_pending),
    .operands_ready_i(perf_operands_ready), .hazard_i(perf_hazard),
    .start_i(sa_impl.start_lane), .mac_valid_i(sa_impl.pe_right_valid),
    .lane_active_o(perf_lane_active_o), .lane_idle_o(perf_lane_idle_o),
    .mac_active_o(perf_mac_active_o), .mac_idle_o(perf_mac_idle_o)
);
assign perf_block_fire_o = blocksel_gemm_valid && parser_cmd_ready;
assign perf_block_m_o = 32'(blocksel_block_m);
assign perf_block_n_o = 32'(blocksel_block_n);

integer perf_a_outstanding, perf_b_outstanding;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        perf_a_outstanding <= 0;
        perf_b_outstanding <= 0;
    end else begin
        perf_a_outstanding <= perf_a_outstanding + int'(load_valid && load_ready && !load_is_b) - int'(abuf_ready_valid);
        perf_b_outstanding <= perf_b_outstanding + int'(load_valid && load_ready && load_is_b) - int'(bbuf_ready_valid);
    end
end
always_comb begin
    perf_blockers_o = '0;
    perf_blockers_o[1] = perf_a_outstanding > 0;
    perf_blockers_o[2] = perf_b_outstanding > 0;
    perf_blockers_o[3] = perf_blockers_o[1] && perf_blockers_o[2];
    perf_blockers_o[11] = !gemm_valid && (parser.state_q != 0);
    perf_blockers_o[12] = (output_valid && !output_ready) ||
        (parser.output_count_q != 0 && parser.state_q == 3);
    perf_upstream_reason = 13;
    if (gemm_s1_valid_q || gemm_valid) perf_upstream_reason = 10;
    else if (perf_blockers_o[3]) perf_upstream_reason = 3;
    else if (perf_blockers_o[1]) perf_upstream_reason = 1;
    else if (perf_blockers_o[2]) perf_upstream_reason = 2;
    else if (perf_blockers_o[12]) perf_upstream_reason = 12;
    else if (perf_blockers_o[11]) perf_upstream_reason = 11;
    for (int lane=0; lane<LANE_NUM; lane++) begin
        perf_blockers_o[8] = perf_blockers_o[8] || (perf_pending[lane] && perf_hazard[lane]);
        perf_blockers_o[9] = perf_blockers_o[9] || (perf_pending[lane] && perf_operands_ready[lane] &&
            !perf_hazard[lane] && !sa_impl.start_lane[lane] && !sa_impl.lane_active[lane]);
    end
end
