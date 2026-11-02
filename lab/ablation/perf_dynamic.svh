
logic [3:0] perf_upstream_reason;
logic perf_pending [LANE_NUM], perf_operands_ready [LANE_NUM], perf_hazard [LANE_NUM];
for (genvar pl=0; pl<LANE_NUM; pl++) begin : gen_perf_lane
    assign perf_pending[pl] = array.slot_in_use[pl][array.lane_wr_slot[pl][0]];
    assign perf_operands_ready[pl] = array.slot_a_ready[pl][array.lane_wr_slot[pl][0]] &&
        array.slot_b_ready[pl][array.lane_wr_slot[pl][0]];
    always_comb begin
        perf_hazard[pl] = 1'b0;
        for (int recent=0; recent<3; recent++) begin
            if (array.recent_start_valid_q[recent] &&
                array.slot_paccidx[pl][array.lane_wr_slot[pl][0]] ==
                array.recent_start_paccidx_q[recent]) perf_hazard[pl] = 1'b1;
        end
    end
end
ablation_perf_monitor #(.M(SUBTILE_M), .N(SUBTILE_N), .LANES(LANE_NUM)) perf_monitor (
    .clk(clk), .rst_n(rst_n), .upstream_reason_i(perf_upstream_reason),
    .lane_active_i(array.lane_active), .pending_i(perf_pending),
    .operands_ready_i(perf_operands_ready), .hazard_i(perf_hazard),
    .start_i(array.start_lane), .mac_valid_i(array.pe_right_valid),
    .lane_active_o(perf_lane_active_o), .lane_idle_o(perf_lane_idle_o),
    .mac_active_o(perf_mac_active_o), .mac_idle_o(perf_mac_idle_o)
);
assign perf_block_fire_o = blocksel_gemm_valid && parser_cmd_ready;
assign perf_block_m_o = 32'(blocksel_block_m);
assign perf_block_n_o = 32'(blocksel_block_n);

always_comb begin
    perf_blockers_o = '0;
    for (int s=0; s<sche.SLOT_COUNT; s++) begin
        if (sche.gemm_count_q[s] != '0) begin
            if (!sche.abuf_ready_q[sche.gemm_q[s][sche.gemm_rd_q[s]].abuf]) perf_blockers_o[1] = 1;
            if (!sche.bbuf_ready_q[sche.gemm_q[s][sche.gemm_rd_q[s]].bbuf]) perf_blockers_o[2] = 1;
        end
        if (GEMM_IN_ORDER && sche.order_pending && sche.gemm_buf_valid_q[s] &&
            !sche.gemm_buf_valid_q[sche.order_head_slot]) perf_blockers_o[4] = 1;
    end
    perf_blockers_o[3] = perf_blockers_o[1] && perf_blockers_o[2];
    if (pv && !pr) begin
        perf_blockers_o[5] = pt == UOP_LOAD_A && !ren.abuf_alloc_found;
        perf_blockers_o[6] = pt == UOP_LOAD_B && !ren.bbuf_alloc_found;
        perf_blockers_o[7] = pt == UOP_GEMM && !pacc && !ren.acc_alloc_found;
    end
    perf_blockers_o[12] = (ov && !orr) || (sgetv && !sgetr);
    perf_upstream_reason = 13;
    if (perf_blockers_o[4]) perf_upstream_reason = 4;
    else if (perf_blockers_o[3]) perf_upstream_reason = 3;
    else if (perf_blockers_o[1]) perf_upstream_reason = 1;
    else if (perf_blockers_o[2]) perf_upstream_reason = 2;
    else if (perf_blockers_o[5]) perf_upstream_reason = 5;
    else if (perf_blockers_o[6]) perf_upstream_reason = 6;
    else if (perf_blockers_o[7]) perf_upstream_reason = 7;
    else if (perf_blockers_o[12]) perf_upstream_reason = 12;
    else if (gemm_s1_valid_q || gv) perf_upstream_reason = 10;
    for (int lane=0; lane<LANE_NUM; lane++) begin
        perf_blockers_o[8] = perf_blockers_o[8] || (perf_pending[lane] && perf_hazard[lane]);
        perf_blockers_o[9] = perf_blockers_o[9] || (perf_pending[lane] && perf_operands_ready[lane] &&
            !perf_hazard[lane] && !array.start_lane[lane] && !array.lane_active[lane]);
    end
end
