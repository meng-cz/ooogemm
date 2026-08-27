#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/ooogemm_debug_new_static_uopparse_L1_W8}"
OUT_FILE="${1:-${SCRIPT_DIR}/data/new_static_L1_W8_P8_AB16_M64N64K64.txt}"
SA_WIDTH="${SA_WIDTH:-8}"
SUBTILE_K="${SUBTILE_K:-16}"
ABUF_SIZE="${ABUF_SIZE:-16}"
BBUF_SIZE="${BBUF_SIZE:-16}"
PACC_NUM="${PACC_NUM:-8}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "$(dirname "${OUT_FILE}")"

verilator \
  --quiet \
  --sv \
  --cc \
  --exe \
  --build \
  --Wno-fatal \
  --build-jobs "${VERILATOR_JOBS:-1}" \
  --Mdir "${BUILD_DIR}" \
  --top-module new_static_uopparse \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GPACC_NUM=${PACC_NUM}" \
  -GADDR_WIDTH=32 \
  -GDIM_WIDTH=16 \
  -CFLAGS "-O2 -g0 -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_K_TEST=${SUBTILE_K} -DPACC_GROUP_SIZE_TEST=$((PACC_NUM / 2))" \
  "${ROOT_DIR}/src/sche/new_static_uopparse.sv" \
  "${SCRIPT_DIR}/export_new_static_uops.cpp"

"${BUILD_DIR}/Vnew_static_uopparse" > "${OUT_FILE}"
printf 'new_static_debug: wrote %s\n' "${OUT_FILE}"
