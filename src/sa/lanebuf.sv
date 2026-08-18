// Ping-pong lane buffer for one systolic-array row.
//
// The module stores two SA_WIDTH-byte rows. One buffer is the write side and
// the other is the read side. A valid input writes the current write buffer on
// the next clock edge. A flip swaps the read/write roles on the same edge.
// rddata is a combinational byte selected from the current read buffer.

`default_nettype none

module lanebuf #(
    parameter int SA_WIDTH     = 16,
    parameter int SA_IDX_WIDTH = (SA_WIDTH <= 1) ? 1 : $clog2(SA_WIDTH)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic valid,
    input  logic [SA_WIDTH*8-1:0] linedata,
    input  logic flip,
    input  logic [SA_IDX_WIDTH-1:0] rdidx,

    output logic [7:0] rddata
);

    initial begin
        if (SA_WIDTH <= 0) begin
            $error("SA_WIDTH must be positive");
        end
        if (SA_IDX_WIDTH <= 0) begin
            $error("SA_IDX_WIDTH must be positive");
        end
    end

    logic [SA_WIDTH*8-1:0] row_buf [2];
    logic rd_sel;

    wire wr_sel = ~rd_sel;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_buf[0] <= '0;
            row_buf[1] <= '0;
            rd_sel     <= 1'b0;
        end else begin
            if (valid) begin
                row_buf[wr_sel] <= linedata;
            end
            if (flip) begin
                rd_sel <= ~rd_sel;
            end
        end
    end

    always_comb begin
        rddata = 8'd0;
        if (int'(rdidx) < SA_WIDTH) begin
            rddata = row_buf[rd_sel][int'(rdidx) * 8 +: 8];
        end
    end

endmodule

`default_nettype wire
