// Present only in dedicated ablation builds. No extra legacy top-level ports.
,output logic [31:0] perf_lane_active_o
,output logic [31:0] perf_lane_idle_o [16]
,output logic [31:0] perf_mac_active_o
,output logic [31:0] perf_mac_idle_o [16]
,output logic [15:0] perf_blockers_o
,output logic perf_block_fire_o
,output logic [31:0] perf_block_m_o, perf_block_n_o
