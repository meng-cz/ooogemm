# Standalone Synthesis Tops

Each SystemVerilog file in this directory defines one fixed-parameter top for
isolating timing paths from a complete GEMM system.  Array ports are converted
to packed vectors using only static slices; wrappers add no pipeline or
arbitration logic.

| Top | Representative configuration |
| --- | --- |
| `Fdot8e4m3_ACC96` | FP8 E4M3, 96-bit exact accumulation |
| `PaccReg_ACC128` | 128 PACC entries, 10-bit exponent, 40-bit significand |
| `BlockSel_M16_N16_AB24_ACC96` | runtime selector, logical AB24/ACC96 |
| `BlockSelMaxArea_M16_N16_AB16_ACC64` | static selector for AB32/ACC128 ping-pong halves |
| `StaticUopParse_M16_N16_K32_AB32_ACC128` | static three-stream parser |
| `DynamicUopParse_M16_N16_K32_AB24_ACC96` | dynamic parser, logical AB24/ACC96 |
| `DynamicSche_AB32_ACC128` | dynamic scheduler, physical AB32/ACC128 |
| `LoadUnit_M64_N64_K32_AB32_D1024` | 64-row load path, 1024-bit memory bus |
| `StoreUnit_M32_N32_ACC128_R2` | 32x32 output tile, two rows per cycle |
| `OprandBuf_R32_K32_S32` | 32 row banks, 32 slots, 256-bit rows |
| `SA_L4_M32_N32_K32_ACC128` | four-lane 32x32x32 systolic array |

Compile the wrapper together with the corresponding implementation and its
package/SRAM dependencies, and select the wrapper name as the synthesis top.
