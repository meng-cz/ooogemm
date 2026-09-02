// Matrix operand buffer backed by row-banked 1R1W SRAMs.
//
// The logical storage contains BUF_SIZE matrices.  Each matrix is split across
// BANK_COUNT independent banks, and each bank stores one SUBTILE_K-byte row.  A
// read or write address selects one full matrix entry; all banks are read in
// parallel and each bank can be written independently through wr_bank_en_i.
//
// Timing model:
// - Synchronous read with one-cycle latency.
// - rd_valid_o follows rd_valid_i by one cycle.
// - Read and write may be asserted in the same cycle.
// - Same-cycle read/write to the same bank and address is modeled READ_FIRST:
//   the read returns the old stored row.
//
// Each bank is instantiated through sram1r1w so later backend flows can replace
// that module with a foundry/FPGA memory macro wrapper without changing the
// matrix buffer interface.

`default_nettype none

module oprandbuf #(
    parameter int BUF_SIZE        = 16,
    parameter int SA_WIDTH        = 4,
    // BANK_COUNT is the number of rows/columns represented by this instance.
    // SA_WIDTH remains as the legacy square-configuration default.
    parameter int BANK_COUNT      = SA_WIDTH,
    parameter int SUBTILE_K       = 32,
    parameter int BUF_IDX_WIDTH   = (BUF_SIZE <= 1) ? 1 : $clog2(BUF_SIZE),
    parameter int BANK_DATA_WIDTH = SUBTILE_K * 8
) (
    input  logic clk,
    input  logic rst_n,

    input  logic wr_valid_i,
    input  logic [BUF_IDX_WIDTH-1:0] wr_idx_i,
    input  logic [BANK_COUNT-1:0] wr_bank_en_i,
    input  logic [BANK_DATA_WIDTH-1:0] wr_data_i [BANK_COUNT],

    input  logic rd_valid_i,
    input  logic [BUF_IDX_WIDTH-1:0] rd_idx_i,
    output logic rd_valid_o,
    output logic [BANK_DATA_WIDTH-1:0] rd_data_o [BANK_COUNT]
);

    initial begin
        if (BUF_SIZE <= 0) begin
            $error("BUF_SIZE must be positive");
        end
        if (BANK_COUNT <= 0) begin
            $error("BANK_COUNT must be positive");
        end
        if (SUBTILE_K <= 0) begin
            $error("SUBTILE_K must be positive");
        end
        if (BUF_IDX_WIDTH <= 0) begin
            $error("BUF_IDX_WIDTH must be positive");
        end
        if (BANK_DATA_WIDTH != SUBTILE_K * 8) begin
            $error("BANK_DATA_WIDTH must equal SUBTILE_K * 8");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_o <= 1'b0;
        end else begin
            rd_valid_o <= rd_valid_i;
        end
    end

    genvar bank;
    generate
        for (bank = 0; bank < BANK_COUNT; bank++) begin : gen_bank
            sram1r1w #(
                .SIZE(BUF_SIZE),
                .WIDTH(BANK_DATA_WIDTH)
            ) u_bank_sram (
                .clk(clk),
                .wr_en_i(wr_valid_i && wr_bank_en_i[bank]),
                .wr_addr_i(wr_idx_i),
                .wr_data_i(wr_data_i[bank]),
                .rd_en_i(rd_valid_i),
                .rd_addr_i(rd_idx_i),
                .rd_data_o(rd_data_o[bank])
            );
        end
    endgenerate

endmodule

`default_nettype wire
