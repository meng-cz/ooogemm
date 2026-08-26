#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/dynamic_sche_verilator.XXXXXX)}"

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  trap 'rm -rf "${BUILD_DIR}"' EXIT
fi

verilator --sv --cc --exe --build \
  --Mdir "${BUILD_DIR}" \
  --top-module dynamic_sche \
  -GABUF_PHYS_SIZE=4 -GBBUF_PHYS_SIZE=4 -GPACC_PHYS_SIZE=4 \
  -GLOAD_ROWS_WIDTH=3 \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/dynamic_sche.sv" \
  "${SCRIPT_DIR}/dynamic_sche.cpp"

"${BUILD_DIR}/Vdynamic_sche"
