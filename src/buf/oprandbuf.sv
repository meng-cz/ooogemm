// Matrix operand buffer backed by row-banked 1R1W SRAMs.
//
// The logical storage contains BUF_SIZE matrices.  Each matrix is split across
// SA_WIDTH independent banks, and each bank stores one SA_WIDTH-byte row.  A
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
// Each bank is instantiated through oprandbuf_bank_sram so later backend flows
// can replace that module with a foundry/FPGA memory macro wrapper without
// changing the matrix buffer interface.

`default_nettype none

module oprandbuf #(
    parameter int BUF_SIZE        = 16,
    parameter int SA_WIDTH        = 4,
    parameter int BUF_IDX_WIDTH   = (BUF_SIZE <= 1) ? 1 : $clog2(BUF_SIZE),
    parameter int BANK_DATA_WIDTH = SA_WIDTH * 8
) (
    input  logic clk,
    input  logic rst_n,

    input  logic wr_valid_i,
    input  logic [BUF_IDX_WIDTH-1:0] wr_idx_i,
    input  logic [SA_WIDTH-1:0] wr_bank_en_i,
    input  logic [BANK_DATA_WIDTH-1:0] wr_data_i [SA_WIDTH],

    input  logic rd_valid_i,
    input  logic [BUF_IDX_WIDTH-1:0] rd_idx_i,
    output logic rd_valid_o,
    output logic [BANK_DATA_WIDTH-1:0] rd_data_o [SA_WIDTH]
);

    initial begin
        if (BUF_SIZE <= 0) begin
            $error("BUF_SIZE must be positive");
        end
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (BUF_IDX_WIDTH <= 0) begin
            $error("BUF_IDX_WIDTH must be positive");
        end
        if (BANK_DATA_WIDTH != SA_WIDTH * 8) begin
            $error("BANK_DATA_WIDTH must equal SA_WIDTH * 8");
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
        for (bank = 0; bank < SA_WIDTH; bank++) begin : gen_bank
            oprandbuf_bank_sram #(
                .DEPTH(BUF_SIZE),
                .ADDR_WIDTH(BUF_IDX_WIDTH),
                .DATA_WIDTH(BANK_DATA_WIDTH)
            ) u_bank_sram (
                .clk(clk),
                .wr_valid_i(wr_valid_i && wr_bank_en_i[bank]),
                .wr_idx_i(wr_idx_i),
                .wr_data_i(wr_data_i[bank]),
                .rd_valid_i(rd_valid_i),
                .rd_idx_i(rd_idx_i),
                .rd_data_o(rd_data_o[bank])
            );
        end
    endgenerate

endmodule

// Single-bank synchronous 1R1W SRAM wrapper.
//
// This module is the intended replacement boundary for backend-specific memory
// macros.  The default implementation uses a Vivado-friendly inferred RAM:
// - one-cycle synchronous read
// - independent same-cycle read and write
// - READ_FIRST behavior for same-address read/write in simulation
// - no reset on the memory array, preserving BRAM/SRAM inference
module oprandbuf_bank_sram #(
    parameter int DEPTH      = 16,
    parameter int ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int DATA_WIDTH = 32
) (
    input  logic clk,

    input  logic wr_valid_i,
    input  logic [ADDR_WIDTH-1:0] wr_idx_i,
    input  logic [DATA_WIDTH-1:0] wr_data_i,

    input  logic rd_valid_i,
    input  logic [ADDR_WIDTH-1:0] rd_idx_i,
    output logic [DATA_WIDTH-1:0] rd_data_o
);

    initial begin
        if (DEPTH <= 0) begin
            $error("DEPTH must be positive");
        end
        if (ADDR_WIDTH <= 0) begin
            $error("ADDR_WIDTH must be positive");
        end
        if (DATA_WIDTH <= 0) begin
            $error("DATA_WIDTH must be positive");
        end
    end

    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (rd_valid_i) begin
            rd_data_o <= ram[rd_idx_i];
        end
        if (wr_valid_i) begin
            ram[wr_idx_i] <= wr_data_i;
        end
    end

endmodule

`default_nettype wire
