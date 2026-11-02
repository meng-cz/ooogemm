`timescale 1ns/1ps
module test_scheduler # (parameter bit IN_ORDER=0);
    import uopparse_pkg::*;
    logic clk=0, rst_n=0;
    logic valid=0, ready;
    uop_type_e typ=UOP_LOAD_A;
    logic [31:0] addr=0;
    logic [1:0] ai=0, bi=0, ci=0;
    logic lv, gv, ov;
    logic [31:0] la;
    logic [1:0] gc;
    logic ad=0, bd=0, gd=0;
    logic [1:0] adi=0, bdi=0, gdi=0;
    int loads=0, gemms=0, outputs=0;
    bit saw_zero=0, saw_one=0;
    dynamic_sche #(.ABUF_PHYS_SIZE(4), .BBUF_PHYS_SIZE(4), .PACC_PHYS_SIZE(4),
        .LOAD_ROWS_WIDTH(4), .GEMM_SLOT_DEPTH(4), .GEMM_IN_ORDER(IN_ORDER)) dut (
        .clk(clk), .rst_n(rst_n), .uop_valid_i(valid), .uop_ready_o(ready),
        .uop_type_i(typ), .uop_addr_i(addr), .uop_abufidx_i(ai), .uop_bbufidx_i(bi),
        .uop_paccidx_i(ci), .uop_valid_rows_i(4'd4), .uop_accum_i(1'b0),
        .load_valid_o(lv), .load_ready_i(1'b1), .load_type_o(), .load_addr_o(la),
        .load_abufidx_o(), .load_bbufidx_o(), .load_valid_rows_o(),
        .gemm_valid_o(gv), .gemm_ready_i(1'b1), .gemm_abufidx_o(), .gemm_bbufidx_o(),
        .gemm_paccidx_o(gc), .gemm_accum_o(), .output_valid_o(ov), .output_ready_i(1'b1),
        .output_addr_o(), .output_paccidx_o(), .load_a_done_valid_i(ad),
        .load_a_done_phys_i(adi), .load_b_done_valid_i(bd), .load_b_done_phys_i(bdi),
        .gemm_done_valid_i(gd), .gemm_done_paccidx_i(gdi),
        .output_done_valid_i(1'b0), .output_done_paccidx_i(2'b0)
    );
    task automatic tick;
        #4; clk=1; #1; clk=0; #1;
    endtask
    task automatic push(input uop_type_e t, input logic [1:0] a, b, c, input logic [31:0] address);
        typ=t; ai=a; bi=b; ci=c; addr=address; valid=1;
        #1;
        while (!ready) tick();
        tick(); valid=0; #1;
    endtask
    always @(posedge clk) begin
        if (rst_n) begin
            if (lv) begin
                assert (la==32'(100+100*loads)) else $fatal(1,"LOAD FIFO order changed");
                loads=loads+1;
            end
            if (gv) begin
                if (IN_ORDER) assert (gc==2'(gemms)) else $fatal(1,"GEMM passed oldest uop");
                else if (gemms==0) assert (gc==1) else $fatal(1,"ready later GEMM did not bypass");
                if(gc==0) saw_zero=1;
                if(gc==1) saw_one=1;
                gemms=gemms+1;
            end
            if (ov) outputs=outputs+1;
        end
    end
    initial begin
        tick(); tick(); rst_n=1; tick();
        // LOAD remains FIFO in both modes, using operands unrelated to GEMMs.
        push(UOP_LOAD_A,2,0,0,100);
        push(UOP_LOAD_A,3,0,0,200);
        adi=1; bdi=1; ad=1; bd=1; tick(); ad=0; bd=0;
        push(UOP_GEMM,0,0,0,0);
        push(UOP_GEMM,1,1,1,0);
        repeat(8) tick();
        if(IN_ORDER) assert (gemms==0) else $fatal(1,"blocked GEMM was bypassed");
        else assert (gemms==1 && saw_one && !saw_zero) else $fatal(1,"OoO bypass missing");
        push(UOP_OUTPUT,0,0,1,300);
        repeat(3) tick();
        assert(outputs==0) else $fatal(1,"OUTPUT bypassed GEMM completion");
        adi=0; bdi=0; ad=1; bd=1; tick(); ad=0; bd=0;
        repeat(12) tick();
        assert(gemms==2 && saw_zero && saw_one && loads==2) else $fatal(1,"missing issued work");
        gdi=1; gd=1; tick(); gd=0;
        repeat(8) tick();
        assert(outputs==1) else $fatal(1,"OUTPUT failed to wake up");
        $display("PASS scheduler IN_ORDER=%0d: GEMM ordering, LOAD FIFO, OUTPUT completion",IN_ORDER);
        $finish;
    end
    initial begin
        #10000; $fatal(1,"test timeout");
    end
endmodule
