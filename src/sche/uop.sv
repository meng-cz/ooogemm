// Common uop definitions shared by schedulers and execution units.

`default_nettype none

package uopparse_pkg;

    typedef enum logic [2:0] {
        UOP_LOAD_A    = 3'd0,
        UOP_LOAD_B    = 3'd1,
        UOP_GEMM      = 3'd2,
        UOP_OUTPUT    = 3'd3,
        UOP_BUF_SWAP  = 3'd4,
        UOP_ACC_FENCE = 3'd5
    } uop_type_e;

endpackage

`default_nettype wire
