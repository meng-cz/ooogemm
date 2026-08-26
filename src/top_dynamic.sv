// Dynamic GEMM top: parser -> renamer -> OoO scheduler -> load/SA/store.
`default_nettype none
module top_dynamic #(
 parameter int SA_WIDTH=32, SUBTILE_K=32, LANE_NUM=4, ABUF_SIZE=64, BBUF_SIZE=64,
 parameter int PACC_NUM=24, ADDR_WIDTH=32, DIM_WIDTH=16, STORE_ROW_WRITE_BEATS=1,
 parameter int ABUF_LOGIC_SIZE=ABUF_SIZE/2, BBUF_LOGIC_SIZE=BBUF_SIZE/2,
 parameter int PACC_LOGIC_SIZE=16,
 parameter int LANE_IDX_WIDTH=(LANE_NUM<=1)?1:$clog2(LANE_NUM),
 parameter int ABUF_IDX_WIDTH=(ABUF_SIZE<=1)?1:$clog2(ABUF_SIZE),
 parameter int BBUF_IDX_WIDTH=(BBUF_SIZE<=1)?1:$clog2(BBUF_SIZE),
 parameter int PACC_IDX_WIDTH=(PACC_NUM<=1)?1:$clog2(PACC_NUM),
 parameter int ROW8_WIDTH=SUBTILE_K*8, LOAD_DATA_WIDTH=256,
 parameter int LOAD_BUS_ID_WIDTH=((SA_WIDTH*((ROW8_WIDTH>=LOAD_DATA_WIDTH)?(ROW8_WIDTH/LOAD_DATA_WIDTH):1))<=1)?1:$clog2(SA_WIDTH*((ROW8_WIDTH>=LOAD_DATA_WIDTH)?(ROW8_WIDTH/LOAD_DATA_WIDTH):1)),
 parameter int ROW32_WIDTH=SA_WIDTH*32,
 parameter int LOAD_ROWS_WIDTH=(SA_WIDTH<=1)?1:$clog2(SA_WIDTH+1),
 parameter int STORE_MEM_DATA_WIDTH=ROW32_WIDTH/STORE_ROW_WRITE_BEATS
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
 logic pv,pr; uop_type_e pt; logic [ADDR_WIDTH-1:0] pa; logic [$clog2(ABUF_LOGIC_SIZE)-1:0] pab; logic [$clog2(BBUF_LOGIC_SIZE)-1:0] pbb; logic [$clog2(PACC_LOGIC_SIZE)-1:0] ppc; logic [LOAD_ROWS_WIDTH-1:0] prow; logic pacc;
 dynamic_uopparse #(.SA_WIDTH(SA_WIDTH),.SUBTILE_K(SUBTILE_K),.ABUF_SIZE(ABUF_SIZE),.BBUF_SIZE(BBUF_SIZE),.PACC_NUM(PACC_NUM),.ABUF_LOGIC_SIZE(ABUF_LOGIC_SIZE),.BBUF_LOGIC_SIZE(BBUF_LOGIC_SIZE),.PACC_LOGIC_SIZE(PACC_LOGIC_SIZE),.ADDR_WIDTH(ADDR_WIDTH),.DIM_WIDTH(DIM_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)) parser(.*,.cmd_ready_o(cmd_ready_o),.uop_valid_o(pv),.uop_ready_i(pr),.uop_type_o(pt),.uop_addr_o(pa),.uop_abufidx_o(pab),.uop_bbufidx_o(pbb),.uop_paccidx_o(ppc),.uop_valid_rows_o(prow),.uop_accum_o(pacc));
 logic rv,rr; uop_type_e rt; logic [ADDR_WIDTH-1:0] ra; logic [ABUF_IDX_WIDTH-1:0] rab; logic [BBUF_IDX_WIDTH-1:0] rbb; logic [PACC_IDX_WIDTH-1:0] rpc; logic [LOAD_ROWS_WIDTH-1:0] rrow; logic racc;
 logic ab_done,bb_done,acc_done; logic [ABUF_IDX_WIDTH-1:0] ab_done_idx; logic [BBUF_IDX_WIDTH-1:0] bb_done_idx; logic [PACC_IDX_WIDTH-1:0] acc_done_idx;
 logic load_a_done,load_b_done; logic [ABUF_IDX_WIDTH-1:0] load_a_done_idx; logic [BBUF_IDX_WIDTH-1:0] load_b_done_idx;
 dynamic_rename #(.ABUF_LOGIC_SIZE(ABUF_LOGIC_SIZE),.BBUF_LOGIC_SIZE(BBUF_LOGIC_SIZE),.ACC_LOGIC_SIZE(PACC_LOGIC_SIZE),.ABUF_PHYS_SIZE(ABUF_SIZE),.BBUF_PHYS_SIZE(BBUF_SIZE),.ACC_PHYS_SIZE(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)) ren(.clk,.rst_n,.uop_valid_i(pv),.uop_ready_o(pr),.uop_type_i(pt),.uop_addr_i(pa),.uop_abufidx_i(pab),.uop_bbufidx_i(pbb),.uop_paccidx_i(ppc),.uop_valid_rows_i(prow),.uop_accum_i(pacc),.renamed_uop_valid_o(rv),.renamed_uop_ready_i(rr),.renamed_uop_type_o(rt),.renamed_uop_addr_o(ra),.renamed_uop_abufidx_o(rab),.renamed_uop_bbufidx_o(rbb),.renamed_uop_paccidx_o(rpc),.renamed_uop_valid_rows_o(rrow),.renamed_uop_accum_o(racc),.abuf_read_done_valid_i(ab_done),.abuf_read_done_phys_i(ab_done_idx),.bbuf_read_done_valid_i(bb_done),.bbuf_read_done_phys_i(bb_done_idx),.acc_read_done_valid_i(acc_done),.acc_read_done_phys_i(acc_done_idx));
 logic lv,lr; uop_type_e lt; logic [ADDR_WIDTH-1:0] la; logic [ABUF_IDX_WIDTH-1:0] lab; logic [BBUF_IDX_WIDTH-1:0] lbb; logic [LOAD_ROWS_WIDTH-1:0] lrows;
 logic gv,gr; logic [ABUF_IDX_WIDTH-1:0] gab; logic [BBUF_IDX_WIDTH-1:0] gbb; logic [PACC_IDX_WIDTH-1:0] gpc; logic gacc;
 logic ov,orr; logic [ADDR_WIDTH-1:0] oa; logic [PACC_IDX_WIDTH-1:0] opc;
 logic ga_done,so_done; logic [PACC_IDX_WIDTH-1:0] ga_done_idx,so_done_idx;
 dynamic_sche #(.ABUF_PHYS_SIZE(ABUF_SIZE),.BBUF_PHYS_SIZE(BBUF_SIZE),.PACC_PHYS_SIZE(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.LOAD_ROWS_WIDTH(LOAD_ROWS_WIDTH)) sche(.clk,.rst_n,.uop_valid_i(rv),.uop_ready_o(rr),.uop_type_i(rt),.uop_addr_i(ra),.uop_abufidx_i(rab),.uop_bbufidx_i(rbb),.uop_paccidx_i(rpc),.uop_valid_rows_i(rrow),.uop_accum_i(racc),.load_valid_o(lv),.load_ready_i(lr),.load_type_o(lt),.load_addr_o(la),.load_abufidx_o(lab),.load_bbufidx_o(lbb),.load_valid_rows_o(lrows),.gemm_valid_o(gv),.gemm_ready_i(gr),.gemm_abufidx_o(gab),.gemm_bbufidx_o(gbb),.gemm_paccidx_o(gpc),.gemm_accum_o(gacc),.output_valid_o(ov),.output_ready_i(orr),.output_addr_o(oa),.output_paccidx_o(opc),.load_a_done_valid_i(load_a_done),.load_a_done_phys_i(load_a_done_idx),.load_b_done_valid_i(load_b_done),.load_b_done_phys_i(load_b_done_idx),.gemm_done_valid_i(ga_done),.gemm_done_paccidx_i(ga_done_idx),.output_done_valid_i(so_done),.output_done_paccidx_i(so_done_idx));
 logic awv,bwv; logic [ABUF_IDX_WIDTH-1:0] awi; logic [BBUF_IDX_WIDTH-1:0] bwi; logic [SA_WIDTH-1:0] awen,bwen; logic [ROW8_WIDTH-1:0] awd[SA_WIDTH],bwd[SA_WIDTH];
 loadunit #(.SA_WIDTH(SA_WIDTH),.SUBTILE_K(SUBTILE_K),.ABUF_SIZE(ABUF_SIZE),.BBUF_SIZE(BBUF_SIZE),.ADDR_WIDTH(ADDR_WIDTH),.ABUF_IDX_WIDTH(ABUF_IDX_WIDTH),.BBUF_IDX_WIDTH(BBUF_IDX_WIDTH),.BUS_ID_WIDTH(LOAD_BUS_ID_WIDTH),.ROWS_LEFT_WIDTH(LOAD_ROWS_WIDTH),.ROW_DATA_WIDTH(ROW8_WIDTH),.LOAD_DATA_WIDTH(LOAD_DATA_WIDTH)) lu(.clk,.rst_n,.uop_valid_i(lv),.uop_ready_o(lr),.uop_is_b_i(lt==UOP_LOAD_B),.uop_addr_i(la),.uop_abufidx_i(lab),.uop_bbufidx_i(lbb),.uop_valid_rows_i(lrows),.mem_req_valid_o(load_mem_req_valid_o),.mem_req_ready_i(load_mem_req_ready_i),.mem_req_addr_o(load_mem_req_addr_o),.mem_req_id_o(load_mem_req_id_o),.mem_rsp_valid_i(load_mem_rsp_valid_i),.mem_rsp_ready_o(load_mem_rsp_ready_o),.mem_rsp_id_i(load_mem_rsp_id_i),.mem_rsp_data_i(load_mem_rsp_data_i),.abuf_wr_valid_o(awv),.abuf_wr_idx_o(awi),.abuf_wr_bank_en_o(awen),.abuf_wr_data_o(awd),.bbuf_wr_valid_o(bwv),.bbuf_wr_idx_o(bwi),.bbuf_wr_bank_en_o(bwen),.bbuf_wr_data_o(bwd),.abuf_ready_valid_o(load_a_done),.abuf_ready_idx_o(load_a_done_idx),.bbuf_ready_valid_o(load_b_done),.bbuf_ready_idx_o(load_b_done_idx));
 logic arv,brv,aru,bru; logic [ABUF_IDX_WIDTH-1:0] ari; logic [BBUF_IDX_WIDTH-1:0] bri; logic [ROW8_WIDTH-1:0] ard[SA_WIDTH],brd[SA_WIDTH];
 oprandbuf #(.BUF_SIZE(ABUF_SIZE),.SA_WIDTH(SA_WIDTH),.SUBTILE_K(SUBTILE_K),.BUF_IDX_WIDTH(ABUF_IDX_WIDTH),.BANK_DATA_WIDTH(ROW8_WIDTH)) ab(.clk,.rst_n,.wr_valid_i(awv),.wr_idx_i(awi),.wr_bank_en_i(awen),.wr_data_i(awd),.rd_valid_i(arv),.rd_idx_i(ari),.rd_valid_o(aru),.rd_data_o(ard));
 oprandbuf #(.BUF_SIZE(BBUF_SIZE),.SA_WIDTH(SA_WIDTH),.SUBTILE_K(SUBTILE_K),.BUF_IDX_WIDTH(BBUF_IDX_WIDTH),.BANK_DATA_WIDTH(ROW8_WIDTH)) bb(.clk,.rst_n,.wr_valid_i(bwv),.wr_idx_i(bwi),.wr_bank_en_i(bwen),.wr_data_i(bwd),.rd_valid_i(brv),.rd_idx_i(bri),.rd_valid_o(bru),.rd_data_o(brd));
 logic sav,sbv,sgv,sgr,sfin; logic [LANE_IDX_WIDTH-1:0] slane,salane,sblane; logic [PACC_IDX_WIDTH-1:0] sgpc,sfinid; logic sgacc; logic sgetv,sgetr,sdatv; logic [PACC_IDX_WIDTH-1:0] sgeti; logic [ROW32_WIDTH-1:0] sdat;
 sa #(.SA_WIDTH(SA_WIDTH),.SUBTILE_K(SUBTILE_K),.LANE_NUM(LANE_NUM),.LANE_IDX_WIDTH(LANE_IDX_WIDTH),.PACC_NUM(PACC_NUM),.PACC_IDX_WIDTH(PACC_IDX_WIDTH),.GEMM_INSTID_WIDTH(PACC_IDX_WIDTH)) array(.clk,.rst_n,.ain_valid(sav),.ain_data(ard),.ain_laneidx(salane),.bin_valid(sbv),.bin_data(brd),.bin_laneidx(sblane),.gemm_valid(sgv),.gemm_ready(sgr),.gemm_alloc_lane(slane),.gemm_instid(sgpc),.gemm_paccidx(sgpc),.gemm_accum(sgacc),.gemm_finish(sfin),.gemm_finish_instid(sfinid),.getacc_valid(sgetv),.getacc_ready(sgetr),.getacc_idx(sgeti),.getacc_data_valid(sdatv),.getacc_data(sdat));
 typedef enum logic[1:0]{IDLE,READ,WRITE} st_t; st_t st; logic [LANE_IDX_WIDTH-1:0] pl; logic [ABUF_IDX_WIDTH-1:0] pabq; logic [BBUF_IDX_WIDTH-1:0] pbbq; logic [PACC_IDX_WIDTH-1:0] ppq;
 assign gr=(st==IDLE)&&sgr; assign sgv=gv&&gr; assign sgpc=gpc; assign sgacc=gacc; assign arv=st==READ; assign brv=st==READ; assign ari=pabq; assign bri=pbbq; assign sav=st==WRITE; assign sbv=st==WRITE; assign salane=pl; assign sblane=pl; assign ga_done=sfin; assign ga_done_idx=sfinid; assign ab_done=(st==WRITE); assign ab_done_idx=pabq; assign bb_done=(st==WRITE); assign bb_done_idx=pbbq;
 logic sv; logic [PACC_IDX_WIDTH-1:0] sp; logic [ADDR_WIDTH-1:0] saq; logic sdone;
 storeunit #(.SA_WIDTH(SA_WIDTH),.PACC_NUM(PACC_NUM),.ADDR_WIDTH(ADDR_WIDTH),.PACC_IDX_WIDTH(PACC_IDX_WIDTH),.ROW_DATA_WIDTH(ROW32_WIDTH),.ROW_WRITE_BEATS(STORE_ROW_WRITE_BEATS),.MEM_DATA_WIDTH(STORE_MEM_DATA_WIDTH)) su(.clk,.rst_n,.uop_valid_i(ov),.uop_ready_o(orr),.uop_addr_i(oa),.uop_paccidx_i(opc),.sa_getacc_valid_o(sgetv),.sa_getacc_ready_i(sgetr),.sa_getacc_idx_o(sgeti),.sa_getacc_data_valid_i(sdatv),.sa_getacc_data_i(sdat),.mem_wr_valid_o(store_mem_wr_valid_o),.mem_wr_ready_i(store_mem_wr_ready_i),.mem_wr_addr_o(store_mem_wr_addr_o),.mem_wr_data_o(store_mem_wr_data_o),.done_valid_o(sdone));
 always_ff @(posedge clk or negedge rst_n) if(!rst_n) begin st<=IDLE;pl<='0;pabq<='0;pbbq<='0;ppq<='0;sp<='0; end else begin if(sgv) begin st<=READ;pl<=slane;pabq<=gab;pbbq<=gbb;ppq<=gpc;end else if(st==READ)st<=WRITE;else if(st==WRITE)st<=IDLE; if(ov&&orr)sp<=opc; end
 assign so_done=sdone; assign so_done_idx=sp; assign acc_done=sdone; assign acc_done_idx=sp;
endmodule
`default_nettype wire
