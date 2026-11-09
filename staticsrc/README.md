# Fixed SystemVerilog hierarchy

Generated from the nine `synthv2` tops and their reachable `src` modules.
Do not edit generated files; regenerate from the repository root:

```bash
python3 tools/generate_staticsrc.py
python3 tools/generate_staticsrc.py --check
```

There are **82 unique modules**, including nine unchanged top names.
Original overrideable parameters are fixed typed localparams. Fixed generate loops
remain compact; only loops selecting different child specializations are expanded.
Functions, sequential logic, reset behavior and simulation checks remain RTL.
`OOOGEMM_ABLATION` is undefined. Existing `SYNTHESIS` guards are retained.

Names contain readable configuration fields and a 12-digit SHA-256 suffix over
the original module name and every effective typed parameter (including defaults).
Identical parameter values share a module even when supplied with different expressions.
Different original module names are never merged. Packages are defined once.

Each `filelists/<module>.f` contains the complete standalone dependency closure.
Use Verilator `-F`, which resolves entries relative to the file list:

```bash
verilator --lint-only -Wno-fatal --top-module L4W32 -F staticsrc/filelists/L4W32.f
```

No `src` or `synthv2` files are needed to compile this tree. For other tools, resolve
file-list entries against their containing directory before passing source paths.
`manifest.json` records all parameters, public port types, direct child counts and
recursive per-top counts. It also records locally expanded generate labels/indices.

## Explicit SRAM specializations

Only `sram1r1w` and `sram2r1w` wrappers are inventoried. Internal arrays in other
modules are not extracted or reclassified as SRAMs. These are behavioral RTL
models, not precompiled hardware macros. All reads are synchronous (one cycle),
writes are synchronous, and same-address simultaneous reads return the old value.

| Module | Depth | Width | Bits/instance | Read/write ports |
| --- | ---: | ---: | ---: | --- |
| `sram1r1w__D16_W256__d4473c7e3fcd` | 16 | 256 | 4096 | 1R1W |
| `sram1r1w__D32_W256__fe9070aab4db` | 32 | 256 | 8192 | 1R1W |
| `sram1r1w__D8_W256__99188397ff91` | 8 | 256 | 2048 | 1R1W |
| `sram2r1w__D128_W50__88b2538a53dc` | 128 | 50 | 6400 | 2R1W |
| `sram2r1w__D32_W50__f2836cc4b5a3` | 32 | 50 | 1600 | 2R1W |
| `sram2r1w__D8_W50__03de8313fe79` | 8 | 50 | 400 | 2R1W |

### SRAM counts per top

| Top | 1R1W instances | 2R1W instances | Total explicit SRAM bits |
| --- | ---: | ---: | ---: |
| `L16W16` | 0 | 256 | 1638400 |
| `L1W64` | 0 | 4096 | 1638400 |
| `L4W32` | 0 | 1024 | 1638400 |
| `dynamic_L16W16_full` | 32 | 256 | 1900544 |
| `dynamic_L1W64_full` | 128 | 4096 | 1900544 |
| `dynamic_L4W32_full` | 64 | 1024 | 1900544 |
| `static_L16W16_full` | 32 | 256 | 1900544 |
| `static_L1W64_full` | 128 | 4096 | 1900544 |
| `static_L4W32_full` | 64 | 1024 | 1900544 |

The CSV includes each specialization's count and total bits for every top.

## Validation

`--check` regenerates in a temporary directory, compares every generated file,
elaborates all nine tops, and checks every specialization as an independent top.
It compares public port datatypes, instance connections, child configurations and
recursive counts against the original hierarchy. It rejects residual module
parameters, parameter overrides and duplicate definitions. Unit tests additionally
exercise typed deduplication, source editing and differential SRAM simulation.
No synthesis, place-and-route or nine full C++ system simulations are run.

Requires Python 3.10+ and an XML-capable Verilator (tested with 5.040).
Verilator XML and logs are cached under ignored `build/staticsrc/`.
