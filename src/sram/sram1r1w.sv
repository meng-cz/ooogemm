// Generic synchronous 1R1W SRAM inference wrapper.
//
// The read port is registered: a request sampled at clock edge N updates
// rd_data_o after edge N.  The independent write port is synchronous and may
// be used in the same cycle as the read port.  A same-address read and write
// is READ_FIRST, so the read returns the old array value.
//
// The memory array intentionally has no reset.  This permits FPGA block-RAM
// inference and replacement with a backend-specific SRAM macro wrapper.

`default_nettype none

module sram1r1w #(
    parameter int SIZE  = 16,
    parameter int WIDTH = 32
) (
    input  logic clk,

    input  logic                              wr_en_i,
    input  logic [$clog2((SIZE <= 1) ? 1 : SIZE)-1:0] wr_addr_i,
    input  logic [WIDTH-1:0]                  wr_data_i,

    input  logic                              rd_en_i,
    input  logic [$clog2((SIZE <= 1) ? 1 : SIZE)-1:0] rd_addr_i,
    output logic [WIDTH-1:0]                  rd_data_o
);

    initial begin
        if (SIZE <= 0) begin
            $error("SIZE must be positive");
        end
        if (WIDTH <= 0) begin
            $error("WIDTH must be positive");
        end
    end

    (* ram_style = "block" *)
    logic [WIDTH-1:0] mem [0:SIZE-1];

    always_ff @(posedge clk) begin
        if (rd_en_i && (int'(rd_addr_i) < SIZE)) begin
            rd_data_o <= mem[rd_addr_i];
        end
        if (wr_en_i && (int'(wr_addr_i) < SIZE)) begin
            mem[wr_addr_i] <= wr_data_i;
        end
    end

endmodule

`default_nettype wire
