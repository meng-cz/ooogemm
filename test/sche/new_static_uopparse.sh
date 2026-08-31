#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/new_static_uopparse_verilator}"

SA_WIDTH="${SA_WIDTH:-8}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
SUBTILE_K="${SUBTILE_K:-16}"
ABUF_SIZE="${ABUF_SIZE:-4}"
BBUF_SIZE="${BBUF_SIZE:-4}"
PACC_NUM="${PACC_NUM:-4}"

clog2_width() {
  local value="$1"
  local width=0
  local x=$((value - 1))
  while (( x > 0 )); do
    width=$((width + 1))
    x=$((x >> 1))
  done
  (( width < 1 )) && width=1
  printf '%d\n' "${width}"
}

ABUF_IDX_WIDTH="${ABUF_IDX_WIDTH:-$(clog2_width "${ABUF_SIZE}")}"
BBUF_IDX_WIDTH="${BBUF_IDX_WIDTH:-$(clog2_width "${BBUF_SIZE}")}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-$(clog2_width "${PACC_NUM}")}"

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
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GPACC_NUM=${PACC_NUM}" \
  -GADDR_WIDTH=32 \
  -GDIM_WIDTH=16 \
  "-GABUF_IDX_WIDTH=${ABUF_IDX_WIDTH}" \
  "-GBBUF_IDX_WIDTH=${BBUF_IDX_WIDTH}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  -CFLAGS "-O2 -g0 -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM}" \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/new_static_uopparse.sv" \
  "${SCRIPT_DIR}/new_static_uopparse.cpp"

"${BUILD_DIR}/Vnew_static_uopparse"
