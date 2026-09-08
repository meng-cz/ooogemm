`default_nettype none

// Standalone 32-row, 32-slot operand buffer.  Packing is static wiring and
// leaves each row bank visible as one sram1r1w instance after elaboration.
module OprandBuf_R32_K32_S32 (
    input  logic clk,
    input  logic rst_n,
    input  logic wr_valid_i,
    input  logic [4:0] wr_idx_i,
    input  logic [31:0] wr_bank_en_i,
    input  logic [8191:0] wr_data_i,
    input  logic rd_valid_i,
    input  logic [4:0] rd_idx_i,
    output logic rd_valid_o,
    output logic [8191:0] rd_data_o
);

    logic [255:0] wr_data [32];
    logic [255:0] rd_data [32];

    for (genvar row = 0; row < 32; row++) begin : gen_pack
        assign wr_data[row] = wr_data_i[row*256 +: 256];
        assign rd_data_o[row*256 +: 256] = rd_data[row];
    end

    oprandbuf #(
        .BUF_SIZE(32),
        .SA_WIDTH(32),
        .BANK_COUNT(32),
        .SUBTILE_K(32),
        .BUF_IDX_WIDTH(5),
        .BANK_DATA_WIDTH(256)
    ) impl (
        .wr_data_i(wr_data),
        .rd_data_o(rd_data),
        .*
    );

endmodule

`default_nettype wire
