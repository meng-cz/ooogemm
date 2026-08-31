// Dynamic GEMM top: parser -> renamer -> OoO scheduler -> load/SA/store.
`default_nettype none
module top_dynamic #(
 parameter int SA_WIDTH=32, SUBTILE_M=SA_WIDTH, SUBTILE_N=SA_WIDTH,
 parameter int SUBTILE_K=32, LANE_NUM=4, ABUF_SIZE=64, BBUF_SIZE=64,
 parameter int PACC_NUM=24, ADDR_WIDTH=32, DIM_WIDTH=16, STORE_ROWS_PER_CYCLE=1,
 parameter int ABUF_LOGIC_SIZE=ABUF_SIZE/2, BBUF_LOGIC_SIZE=BBUF_SIZE/2,
 parameter int PACC_LOGIC_SIZE=16,
 parameter int LANE_IDX_WIDTH=(LANE_NUM<=1)?1:$clog2(LANE_NUM),
 parameter int ABUF_IDX_WIDTH=(ABUF_SIZE<=1)?1:$clog2(ABUF_SIZE),
 parameter int BBUF_IDX_WIDTH=(BBUF_SIZE<=1)?1:$clog2(BBUF_SIZE),
 parameter int PACC_IDX_WIDTH=(PACC_NUM<=1)?1:$clog2(PACC_NUM),
 parameter int ROW8_WIDTH=SUBTILE_K*8, LOAD_DATA_WIDTH=1024,
 parameter int MAX_SUBTILE_ROWS=(SUBTILE_M>SUBTILE_N)?SUBTILE_M:SUBTILE_N,
 parameter int LOAD_BUS_ID_WIDTH=((MAX_SUBTILE_ROWS*((ROW8_WIDTH>=LOAD_DATA_WIDTH)?(ROW8_WIDTH/LOAD_DATA_WIDTH):1))<=1)?1:$clog2(MAX_SUBTILE_ROWS*((ROW8_WIDTH>=LOAD_DATA_WIDTH)?(ROW8_WIDTH/LOAD_DATA_WIDTH):1)),
 parameter int ROW32_WIDTH=SUBTILE_N*32,
 parameter int LOAD_ROWS_WIDTH=(MAX_SUBTILE_ROWS<=1)?1:$clog2(MAX_SUBTILE_ROWS+1),
 parameter int STORE_MEM_DATA_WIDTH=ROW32_WIDTH*STORE_ROWS_PER_CYCLE,
 parameter int GEMM_INSTID_WIDTH=16,
 parameter int GEMM_TRACK_DEPTH=64,
 parameter int GEMM_TRACK_IDX_WIDTH=(GEMM_TRACK_DEPTH<=1)?1:$clog2(GEMM_TRACK_DEPTH),
 parameter int BLOCKSEL_UNROLL_NUM=1,
 parameter int BLOCK_M_WIDTH=(ABUF_LOGIC_SIZE<=1)?1:$clog2(ABUF_LOGIC_SIZE+1),
 parameter int BLOCK_N_WIDTH=(BBUF_LOGIC_SIZE<=1)?1:$clog2(BBUF_LOGIC_SIZE+1),
 parameter int ABUF_LOGIC_IDX_WIDTH=(ABUF_LOGIC_SIZE<=1)?1:$clog2(ABUF_LOGIC_SIZE),
 parameter int BBUF_LOGIC_IDX_WIDTH=(BBUF_LOGIC_SIZE<=1)?1:$clog2(BBUF_LOGIC_SIZE),
 parameter int PACC_LOGIC_IDX_WIDTH=(PACC_LOGIC_SIZE<=1)?1:$clog2(PACC_LOGIC_SIZE)
) (
 input logic clk,rst_n, input logic cmd_valid_i, output logic cmd_ready_o,
 input logic [ADDR_WIDTH-1:0] cmd_a_base_i,cmd_b_base_i,cmd_c_base_i,
 input logic [DIM_WIDTH-1:0] cmd_m_i,cmd_n_i,cmd_k_i,cmd_batch_i,
 output logic load_mem_req_valid_o,input logic load_mem_req_ready_i,
 output logic [ADDR_WIDTH-1:0] load_mem_req_addr_o,
 output logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_req_id_o,
 input logic load_mem_rsp_valid_i,output logic load_mem_rsp_ready_o,
 input logic [LOAD_BUS_ID_WIDTH-1:0] load_mem_rsp_id_i,
 input logic [LOAD_DATA_WIDTH-1:0] load_mem_rsp_data_i,
 output logic store_mem_wr_valid_o,input logic store_mem_wr_ready_i,
 output logic [ADDR_WIDTH-1:0] store_mem_wr_addr_o,
 output logic [STORE_MEM_DATA_WIDTH-1:0] store_mem_wr_data_o
);
 import uopparse_pkg::*;
 logic blocksel_cmd_ready, blocksel_gemm_valid, blocksel_gemm_ready;
 logic [BLOCK_M_WIDTH-1:0] blocksel_block_m;
 logic [BLOCK_N_WIDTH-1:0] blocksel_block_n;
 logic [ADDR_WIDTH-1:0] blocksel_a_base, blocksel_b_base, blocksel_c_base;
 logic [DIM_WIDTH-1:0] blocksel_m, blocksel_n, blocksel_k, blocksel_batch;
 logic parser_cmd_ready;
 blocksel #(.SA_WIDTH(SA_WIDTH),.SUBTILE_M(SUBTILE_M),.SUBTILE_N(SUBTILE_N),.LOGIC_ABUF_SIZE(ABUF_LOGIC_SIZE),
     .LOGIC_BBUF_SIZE(BBUF_LOGIC_SIZE),.LOGIC_ACC_NUM(PACC_LOGIC_SIZE),
     .ADDR_WIDTH(ADDR_WIDTH),.DIM_WIDTH(DIM_WIDTH),
     .UNROLL_NUM(BLOCKSEL_UNROLL_NUM),.BLOCK_M_WIDTH(BLOCK_M_WIDTH),
     .BLOCK_N_WIDTH(BLOCK_N_WIDTH)) block_selector (
     .clk(clk),.rst_n(rst_n),.cmd_valid_i(cmd_valid_i),
     .cmd_ready_o(blocksel_cmd_ready),.cmd_a_base_i(cmd_a_base_i),
     .cmd_b_base_i(cmd_b_base_i),.cmd_c_base_i(cmd_c_base_i),
     .cmd_m_i(cmd_m_i),.cmd_n_i(cmd_n_i),.cmd_k_i(cmd_k_i),
     .cmd_batch_i(cmd_batch_i),.gemm_valid_o(blocksel_gemm_valid),
     .gemm_ready_i(blocksel_gemm_ready),.gemm_a_base_o(blocksel_a_base),
     .gemm_b_base_o(blocksel_b_base),.gemm_c_base_o(blocksel_c_base),
     .gemm_m_o(blocksel_m),.gemm_n_o(blocksel_n),.gemm_k_o(blocksel_k),
     .gemm_batch_o(blocksel_batch),.block_m_o(blocksel_block_m),
     .block_n_o(blocksel_block_n));
 assign cmd_ready_o = blocksel_cmd_ready;
 logic pv,pr; uop_type_e pt; logic [ADDR_WIDTH-1:0] pa; logic [ABUF_LOGIC_IDX_WIDTH-1:0] pab; logic [BBUF_LOGIC_IDX_WIDTH-1:0] pbb; logic [PACC_LOGIC_IDX_WIDTH-1:0] ppc; logic [LOAD_ROWS_WIDTH-1:0] prow; logic pacc;
 dynamic_uopparse #(.SA_WIDTH(SA_WIDTH),.SUBTILE_M(SUBTILE_M),.SUBTILE_N(SUBTILE_N),.SUBTILE_K(SUBTILE_K),.ABUF_SIZE(ABUF_SIZE),.BBUF_SIZE(BBUF_SIZE),.PACC_NUM(PACC_NUM),.ABUF_LOGIC_SIZE(ABUF_LOGIC_SIZE),.BBUF_LOGIC_SIZE(BBUF_LOGIC_SIZE),.PACC_LOGIC_SIZE(PACC_LOGIC_SIZE),.ADDR_WIDTH(ADDR_WIDTH),.DIM_WIDTH(DIM_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH),.BLOCK_M_WIDTH(BLOCK_M_WIDTH),.BLOCK_N_WIDTH(BLOCK_N_WIDTH)) parser(.clk,.rst_n,.cmd_valid_i(blocksel_gemm_valid),.cmd_ready_o(parser_cmd_ready),.cmd_a_base_i(blocksel_a_base),.cmd_b_base_i(blocksel_b_base),.cmd_c_base_i(blocksel_c_base),.cmd_m_i(blocksel_m),.cmd_n_i(blocksel_n),.cmd_k_i(blocksel_k),.cmd_batch_i(blocksel_batch),.block_m_i(blocksel_block_m),.block_n_i(blocksel_block_n),.uop_valid_o(pv),.uop_ready_i(pr),.uop_type_o(pt),.uop_addr_o(pa),.uop_abufidx_o(pab),.uop_bbufidx_o(pbb),.uop_paccidx_o(ppc),.uop_valid_rows_o(prow),.uop_accum_o(pacc));
 assign blocksel_gemm_ready = parser_cmd_ready;
 logic rv,rr; uop_type_e rt; logic [ADDR_WIDTH-1:0] ra; logic [ABUF_IDX_WIDTH-1:0] rab; logic [BBUF_IDX_WIDTH-1:0] rbb; logic [PACC_IDX_WIDTH-1:0] rpc; logic [LOAD_ROWS_WIDTH-1:0] rrow; logic racc;
 logic ab_done,bb_done,acc_done; logic [ABUF_IDX_WIDTH-1:0] ab_done_idx; logic [BBUF_IDX_WIDTH-1:0] bb_done_idx; logic [PACC_IDX_WIDTH-1:0] acc_done_idx;
 logic load_a_done,load_b_done; logic [ABUF_IDX_WIDTH-1:0] load_a_done_idx; logic [BBUF_IDX_WIDTH-1:0] load_b_done_idx;
 dynamic_rename #(.ABUF_LOGIC_SIZE(ABUF_LOGIC_SIZE),.BBUF_LOGIC_SIZE(BBUF_LOGIC_SIZE),.ACC_LOGIC_SIZE(PACC_LOGIC_SIZE),.ABUF_PHYS_SIZE(ABUF_SIZE),.BBUF_PHYS_SIZE(BBUF_SIZE),.ACC_PHYS_SIZE(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)) ren(.clk,.rst_n,.uop_valid_i(pv),.uop_ready_o(pr),.uop_type_i(pt),.uop_addr_i(pa),.uop_abufidx_i(pab),.uop_bbufidx_i(pbb),.uop_paccidx_i(ppc),.uop_valid_rows_i(prow),.uop_accum_i(pacc),.renamed_uop_valid_o(rv),.renamed_uop_ready_i(rr),.renamed_uop_type_o(rt),.renamed_uop_addr_o(ra),.renamed_uop_abufidx_o(rab),.renamed_uop_bbufidx_o(rbb),.renamed_uop_paccidx_o(rpc),.renamed_uop_valid_rows_o(rrow),.renamed_uop_accum_o(racc),.abuf_read_done_valid_i(ab_done),.abuf_read_done_phys_i(ab_done_idx),.bbuf_read_done_valid_i(bb_done),.bbuf_read_done_phys_i(bb_done_idx),.acc_read_done_valid_i(acc_done),.acc_read_done_phys_i(acc_done_idx),.acc_gemm_done_valid_i(ga_done),.acc_gemm_done_phys_i(ga_done_idx));
 logic lv,lr; uop_type_e lt; logic [ADDR_WIDTH-1:0] la; logic [ABUF_IDX_WIDTH-1:0] lab; logic [BBUF_IDX_WIDTH-1:0] lbb; logic [LOAD_ROWS_WIDTH-1:0] lrows;
 logic gv,gr; logic [ABUF_IDX_WIDTH-1:0] gab; logic [BBUF_IDX_WIDTH-1:0] gbb; logic [PACC_IDX_WIDTH-1:0] gpc; logic gacc;
 logic ov,orr; logic [ADDR_WIDTH-1:0] oa; logic [PACC_IDX_WIDTH-1:0] opc;
 logic ga_done,so_done; logic [PACC_IDX_WIDTH-1:0] ga_done_idx,so_done_idx;
 dynamic_sche #(.ABUF_PHYS_SIZE(ABUF_SIZE),.BBUF_PHYS_SIZE(BBUF_SIZE),.PACC_PHYS_SIZE(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)) sche(.clk,.rst_n,.uop_valid_i(rv),.uop_ready_o(rr),.uop_type_i(rt),.uop_addr_i(ra),.uop_abufidx_i(rab),.uop_bbufidx_i(rbb),.uop_paccidx_i(rpc),.uop_valid_rows_i(rrow),.uop_accum_i(racc),.load_valid_o(lv),.load_ready_i(lr),.load_type_o(lt),.load_addr_o(la),.load_abufidx_o(lab),.load_bbufidx_o(lbb),.load_valid_rows_o(lrows),.gemm_valid_o(gv),.gemm_ready_i(gr),.gemm_abufidx_o(gab),.gemm_bbufidx_o(gbb),.gemm_paccidx_o(gpc),.gemm_accum_o(gacc),.output_valid_o(ov),.output_ready_i(orr),.output_addr_o(oa),.output_paccidx_o(opc),.load_a_done_valid_i(load_a_done),.load_a_done_phys_i(load_a_done_idx),.load_b_done_valid_i(load_b_done),.load_b_done_phys_i(load_b_done_idx),.gemm_done_valid_i(ga_done),.gemm_done_paccidx_i(ga_done_idx),.output_done_valid_i(so_done),.output_done_paccidx_i(so_done_idx));
 logic awv,bwv; logic [ABUF_IDX_WIDTH-1:0] awi; logic [BBUF_IDX_WIDTH-1:0] bwi; logic [SUBTILE_M-1:0] awen; logic [SUBTILE_N-1:0] bwen; logic [ROW8_WIDTH-1:0] awd[SUBTILE_M],bwd[SUBTILE_N];
 loadunit #(.SA_WIDTH(SA_WIDTH),.SUBTILE_M(SUBTILE_M),.SUBTILE_N(SUBTILE_N),.SUBTILE_K(SUBTILE_K),.ABUF_SIZE(ABUF_SIZE),.BBUF_SIZE(BBUF_SIZE),.ADDR_WIDTH(ADDR_WIDTH),.ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),.BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),.BUS_ID_WIDTH(LOAD_BUS_ID_WIDTH),.ROWS_LEFT_WIDTH(LOAD_ROWS_WIDTH),.ROW_DATA_WIDTH(ROW8_WIDTH),.LOAD_DATA_WIDTH(LOAD_DATA_WIDTH)) lu(.clk,.rst_n,.uop_valid_i(lv),.uop_ready_o(lr),.uop_is_b_i(lt==UOP_LOAD_B),.uop_addr_i(la),.uop_abufidx_i(lab),.uop_bbufidx_i(lbb),.uop_valid_rows_i(lrows),.mem_req_valid_o(load_mem_req_valid_o),.mem_req_ready_i(load_mem_req_ready_i),.mem_req_addr_o(load_mem_req_addr_o),.mem_req_id_o(load_mem_req_id_o),.mem_rsp_valid_i(load_mem_rsp_valid_i),.mem_rsp_ready_o(load_mem_rsp_ready_o),.mem_rsp_id_i(load_mem_rsp_id_i),.mem_rsp_data_i(load_mem_rsp_data_i),.abuf_wr_valid_o(awv),.abuf_wr_idx_o(awi),.abuf_wr_bank_en_o(awen),.abuf_wr_data_o(awd),.bbuf_wr_valid_o(bwv),.bbuf_wr_idx_o(bwi),.bbuf_wr_bank_en_o(bwen),.bbuf_wr_data_o(bwd),.abuf_ready_valid_o(load_a_done),.abuf_ready_idx_o(load_a_done_idx),.bbuf_ready_valid_o(load_b_done),.bbuf_ready_idx_o(load_b_done_idx));
 logic arv,brv,aru,bru; logic [ABUF_IDX_WIDTH-1:0] ari; logic [BBUF_IDX_WIDTH-1:0] bri; logic [ROW8_WIDTH-1:0] ard[SUBTILE_M],brd[SUBTILE_N];
 oprandbuf #(.BUF_SIZE(ABUF_SIZE),.SA_WIDTH(SA_WIDTH),.BANK_COUNT(SUBTILE_M),.SUBTILE_K(SUBTILE_K),.BUF_IDX_WIDTH(ABUF_IDX_WIDTH),.BANK_DATA_WIDTH(ROW8_WIDTH)) ab(.clk,.rst_n,.wr_valid_i(awv),.wr_idx_i(awi),.wr_bank_en_i(awen),.wr_data_i(awd),.rd_valid_i(arv),.rd_idx_i(ari),.rd_valid_o(aru),.rd_data_o(ard));
 oprandbuf #(.BUF_SIZE(BBUF_SIZE),.SA_WIDTH(SA_WIDTH),.BANK_COUNT(SUBTILE_N),.SUBTILE_K(SUBTILE_K),.BUF_IDX_WIDTH(BBUF_IDX_WIDTH),.BANK_DATA_WIDTH(ROW8_WIDTH)) bb(.clk,.rst_n,.wr_valid_i(bwv),.wr_idx_i(bwi),.wr_bank_en_i(bwen),.wr_data_i(bwd),.rd_valid_i(brv),.rd_idx_i(bri),.rd_valid_o(bru),.rd_data_o(brd));
 logic sav,sbv,sgv,sgr,sfin; logic [LANE_IDX_WIDTH-1:0] slane,salane,sblane; logic [PACC_IDX_WIDTH-1:0] sgpc; logic [GEMM_INSTID_WIDTH-1:0] sfinid; logic sgacc; logic sgetv,sgetr,sdatv; logic [PACC_IDX_WIDTH-1:0] sgeti; logic [STORE_MEM_DATA_WIDTH-1:0] sdat;

 // GEMM issue pipeline.  The three stages are independent, so after the
 // initial fill one GEMM can be accepted from dynamic_sche every cycle:
 //
 //   S1: capture the scheduler's GEMM uop while the previous uop is in S2.
 //   S2: handshake with SA, obtain a lane, and start synchronous A/B reads.
 //   S3: submit the matrices returned by the operand buffers to that lane.
 //
 // SA has no backpressure on the A/B matrix ports.  Its GEMM ready signal is
 // therefore the only S2 stall source; S1 can be replaced in the same cycle
 // that the current S1 uop is accepted by SA.
 logic gemm_s1_valid_q;
 logic [ABUF_IDX_WIDTH-1:0] gemm_s1_abuf_q;
 logic [BBUF_IDX_WIDTH-1:0] gemm_s1_bbuf_q;
 logic [PACC_IDX_WIDTH-1:0] gemm_s1_pacc_q;
 logic gemm_s1_accum_q;
 logic gemm_s3_valid_q;
 logic [LANE_IDX_WIDTH-1:0] gemm_s3_lane_q;
 logic [ABUF_IDX_WIDTH-1:0] gemm_s3_abuf_q;
 logic [BBUF_IDX_WIDTH-1:0] gemm_s3_bbuf_q;
 logic [GEMM_INSTID_WIDTH-1:0] sa_gemm_instid;
 logic [GEMM_INSTID_WIDTH-1:0] gemm_id_q;
 logic gemm_track_valid_q [GEMM_TRACK_DEPTH];
 logic [GEMM_INSTID_WIDTH-1:0] gemm_track_id_q [GEMM_TRACK_DEPTH];
 logic [PACC_IDX_WIDTH-1:0] gemm_track_pacc_q [GEMM_TRACK_DEPTH];
 logic gemm_track_free_found;
 logic [GEMM_TRACK_IDX_WIDTH-1:0] gemm_track_free_idx;
 logic gemm_finish_found;
 logic [PACC_IDX_WIDTH-1:0] gemm_finish_pacc;

 always_comb begin
   gemm_track_free_found = 1'b0;
   gemm_track_free_idx = '0;
   for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
     if (!gemm_track_valid_q[i] && !gemm_track_free_found) begin
       gemm_track_free_found = 1'b1;
       gemm_track_free_idx = GEMM_TRACK_IDX_WIDTH'(i);
     end
   end

   gemm_finish_found = 1'b0;
   gemm_finish_pacc = '0;
   for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
     if (sfin && gemm_track_valid_q[i] &&
         (gemm_track_id_q[i] == sfinid) && !gemm_finish_found) begin
       gemm_finish_found = 1'b1;
       gemm_finish_pacc = gemm_track_pacc_q[i];
     end
   end
 end

 wire gemm_s1_ready = !gemm_s1_valid_q || (sgr && gemm_track_free_found);
 wire gemm_sa_fire = sgv && sgr && gemm_track_free_found;

 assign gr = gemm_s1_ready;
 assign sgv = gemm_s1_valid_q && gemm_track_free_found;
 assign sgpc = gemm_s1_pacc_q;
 assign sgacc = gemm_s1_accum_q;
 assign arv = gemm_sa_fire;
 assign brv = gemm_sa_fire;
 assign ari = gemm_s1_abuf_q;
 assign bri = gemm_s1_bbuf_q;
 assign sav = gemm_s3_valid_q && aru && bru;
 assign sbv = sav;
 assign salane = gemm_s3_lane_q;
 assign sblane = gemm_s3_lane_q;
 assign ga_done = sfin && gemm_finish_found;
 assign ga_done_idx = gemm_finish_pacc;
 assign ab_done = sav;
 assign ab_done_idx = gemm_s3_abuf_q;
 assign bb_done = sav;
 assign bb_done_idx = gemm_s3_bbuf_q;
 assign sa_gemm_instid = gemm_id_q;

 sa #(.SA_WIDTH(SA_WIDTH),.SUBTILE_M(SUBTILE_M),.SUBTILE_N(SUBTILE_N),.SUBTILE_K(SUBTILE_K),.LANE_NUM(LANE_NUM),.LANE_IDX_WIDTH(LANE_IDX_WIDTH),.PACC_NUM(PACC_NUM),.PACC_IDX_WIDTH(PACC_IDX_WIDTH),.GEMM_INSTID_WIDTH(GEMM_INSTID_WIDTH),.GETACC_ROWS_PER_CYCLE(STORE_ROWS_PER_CYCLE)) array(.clk,.rst_n,.ain_valid(sav),.ain_data(ard),.ain_laneidx(salane),.bin_valid(sbv),.bin_data(brd),.bin_laneidx(sblane),.gemm_valid(sgv),.gemm_ready(sgr),.gemm_alloc_lane(slane),.gemm_instid(sa_gemm_instid),.gemm_paccidx(sgpc),.gemm_accum(sgacc),.gemm_finish(sfin),.gemm_finish_instid(sfinid),.getacc_valid(sgetv),.getacc_ready(sgetr),.getacc_idx(sgeti),.getacc_data_valid(sdatv),.getacc_data(sdat));
 logic sv; logic [PACC_IDX_WIDTH-1:0] sp; logic [ADDR_WIDTH-1:0] saq; logic sdone;
 storeunit #(.SA_WIDTH(SA_WIDTH),.SUBTILE_M(SUBTILE_M),.SUBTILE_N(SUBTILE_N),.PACC_NUM(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.PACC_IDX_WIDTH(PACC_IDX_WIDTH),.ROW_DATA_WIDTH(ROW32_WIDTH),.ROWS_PER_CYCLE(STORE_ROWS_PER_CYCLE),.MEM_DATA_WIDTH(STORE_MEM_DATA_WIDTH),.UOP_FIFO_DEPTH(1)) su(.clk,.rst_n,.uop_valid_i(ov),.uop_ready_o(orr),.uop_addr_i(oa),.uop_paccidx_i(opc),.sa_getacc_valid_o(sgetv),.sa_getacc_ready_i(sgetr),.sa_getacc_idx_o(sgeti),.sa_getacc_data_valid_i(sdatv),.sa_getacc_data_i(sdat),.mem_wr_valid_o(store_mem_wr_valid_o),.mem_wr_ready_i(store_mem_wr_ready_i),.mem_wr_addr_o(store_mem_wr_addr_o),.mem_wr_data_o(store_mem_wr_data_o),.done_valid_o(sdone));

 // The store unit may accept the next OUTPUT while the previous tile's last
 // row is still waiting on the memory bus.  Keep completion IDs in issue
 // order instead of associating a completion with only the most recent uop.
 logic [PACC_IDX_WIDTH-1:0] output_id_fifo [PACC_NUM];
 logic [PACC_IDX_WIDTH-1:0] output_id_wr_q, output_id_rd_q;
 logic [$clog2(PACC_NUM + 1)-1:0] output_id_count_q;
 wire output_issue_fire = ov && orr;
 wire output_complete = sdone && (output_id_count_q != '0);

 function automatic logic [PACC_IDX_WIDTH-1:0] output_id_inc(
     input logic [PACC_IDX_WIDTH-1:0] ptr
 );
   if (int'(ptr) == PACC_NUM - 1) begin
     return '0;
   end
   return ptr + 1'b1;
 endfunction
 always_ff @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     gemm_s1_valid_q <= 1'b0;
     gemm_s1_abuf_q <= '0;
     gemm_s1_bbuf_q <= '0;
     gemm_s1_pacc_q <= '0;
     gemm_s1_accum_q <= 1'b0;
     gemm_s3_valid_q <= 1'b0;
     gemm_s3_lane_q <= '0;
     gemm_s3_abuf_q <= '0;
     gemm_s3_bbuf_q <= '0;
     gemm_id_q <= '0;
     sp <= '0;
     output_id_wr_q <= '0;
     output_id_rd_q <= '0;
     output_id_count_q <= '0;
     for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
       gemm_track_valid_q[i] <= 1'b0;
       gemm_track_id_q[i] <= '0;
       gemm_track_pacc_q[i] <= '0;
     end
   end else begin
     // S3 advances whenever S2 accepts a GEMM; S1 is replaced concurrently.
     gemm_s3_valid_q <= gemm_sa_fire;
     if (gemm_sa_fire) begin
       gemm_s3_lane_q <= slane;
       gemm_s3_abuf_q <= gemm_s1_abuf_q;
       gemm_s3_bbuf_q <= gemm_s1_bbuf_q;
       gemm_track_valid_q[gemm_track_free_idx] <= 1'b1;
       gemm_track_id_q[gemm_track_free_idx] <= gemm_id_q;
       gemm_track_pacc_q[gemm_track_free_idx] <= gemm_s1_pacc_q;
       gemm_id_q <= gemm_id_q + 1'b1;
     end

     if (gemm_finish_found) begin
       for (int i = 0; i < GEMM_TRACK_DEPTH; i++) begin
         if (gemm_track_valid_q[i] && (gemm_track_id_q[i] == sfinid)) begin
           gemm_track_valid_q[i] <= 1'b0;
         end
       end
     end

     if (gemm_s1_ready) begin
       gemm_s1_valid_q <= gv;
       if (gv) begin
         gemm_s1_abuf_q <= gab;
         gemm_s1_bbuf_q <= gbb;
         gemm_s1_pacc_q <= gpc;
         gemm_s1_accum_q <= gacc;
       end
     end

     if (output_issue_fire) begin
       sp <= opc;
       output_id_fifo[int'(output_id_wr_q)] <= opc;
       output_id_wr_q <= output_id_inc(output_id_wr_q);
     end
     if (output_complete) begin
       output_id_rd_q <= output_id_inc(output_id_rd_q);
     end
     unique case ({output_issue_fire, output_complete})
       2'b10: output_id_count_q <= output_id_count_q + 1'b1;
       2'b01: output_id_count_q <= output_id_count_q - 1'b1;
       default: begin end
     endcase
   end
 end
 assign so_done=output_complete;
 assign so_done_idx=output_complete ? output_id_fifo[int'(output_id_rd_q)] : '0;
 assign acc_done=output_complete;
 assign acc_done_idx=so_done_idx;
endmodule
`default_nettype wire
