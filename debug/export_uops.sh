#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/ooogemm_debug_uopparse_L1_W8}"
OUT_FILE="${1:-${SCRIPT_DIR}/data/static_uops_64x64x64.txt}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "$(dirname "${OUT_FILE}")"

verilator \
  --quiet \
  --sv \
  --cc \
  --exe \
  --build \
  --build-jobs "${VERILATOR_JOBS:-1}" \
  --Mdir "${BUILD_DIR}" \
  --top-module static_uopparse \
  -GSA_WIDTH=8 \
  -GSUBTILE_K=16 \
  -GABUF_SIZE=4 \
  -GBBUF_SIZE=4 \
  -GPACC_NUM=4 \
  -GADDR_WIDTH=32 \
  -GDIM_WIDTH=16 \
  -GABUF_IDX_WIDTH=2 \
  -GBBUF_IDX_WIDTH=2 \
  -GPACC_IDX_WIDTH=2 \
  -CFLAGS '-O2 -g0' \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/static_uopparse.sv" \
  "${SCRIPT_DIR}/export_uops.cpp"

"${BUILD_DIR}/Vstatic_uopparse" > "${OUT_FILE}"
echo "static_debug: wrote ${OUT_FILE}"
