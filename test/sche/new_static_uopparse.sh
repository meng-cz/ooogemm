#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/new_static_uopparse_verilator}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

verilator \
  --sv \
  --cc \
  --exe \
  --build \
  --Wno-fatal \
  --build-jobs "${VERILATOR_JOBS:-1}" \
  --Mdir "${BUILD_DIR}" \
  --top-module new_static_uopparse \
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
  "${ROOT_DIR}/src/sche/new_static_uopparse.sv" \
  "${SCRIPT_DIR}/new_static_uopparse.cpp"

"${BUILD_DIR}/Vnew_static_uopparse"
