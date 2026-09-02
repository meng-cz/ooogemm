// Generic synchronous 2R1W SRAM inference wrapper.
//
// Both read ports are registered: a read request accepted at clock edge N
// produces its data on the corresponding output after edge N.  The write port
// is also synchronous.  When a read and a write target the same address in the
// same cycle, the registered read data is READ_FIRST (the old array value).
//
// The memory array intentionally has no reset.  This keeps the implementation
// compatible with inferred BRAM/SRAM macros; users that require a reset value
// must initialize the entries through the write port.

`default_nettype none

module sram2r1w #(
    parameter int SIZE  = 16,
    parameter int WIDTH = 32
) (
    input  logic clk,

    input  logic                         wr_en_i,
    input  logic [$clog2((SIZE <= 1) ? 1 : SIZE)-1:0] wr_addr_i,
    input  logic [WIDTH-1:0]              wr_data_i,

    input  logic                         rd0_en_i,
    input  logic [$clog2((SIZE <= 1) ? 1 : SIZE)-1:0] rd0_addr_i,
    output logic [WIDTH-1:0]              rd0_data_o,

    input  logic                         rd1_en_i,
    input  logic [$clog2((SIZE <= 1) ? 1 : SIZE)-1:0] rd1_addr_i,
    output logic [WIDTH-1:0]              rd1_data_o
);

    initial begin
        if (SIZE <= 0) begin
            $error("SIZE must be positive");
        end
        if (WIDTH <= 0) begin
            $error("WIDTH must be positive");
        end
    end

    // The ram_style attribute is honored by Vivado for the generic
    // implementation and can be replaced by a backend-specific macro wrapper.
    (* ram_style = "block" *)
    logic [WIDTH-1:0] mem [0:SIZE-1];

    always_ff @(posedge clk) begin
        if (rd0_en_i && (int'(rd0_addr_i) < SIZE)) begin
            rd0_data_o <= mem[rd0_addr_i];
        end
        if (rd1_en_i && (int'(rd1_addr_i) < SIZE)) begin
            rd1_data_o <= mem[rd1_addr_i];
        end
        if (wr_en_i && (int'(wr_addr_i) < SIZE)) begin
            mem[wr_addr_i] <= wr_data_i;
        end
    end

endmodule

`default_nettype wire
