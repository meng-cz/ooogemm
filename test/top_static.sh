#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SA_WIDTH="${SA_WIDTH:-2}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
SUBTILE_K="${SUBTILE_K:-2}"
LANE_NUM="${LANE_NUM:-1}"
ABUF_SIZE="${ABUF_SIZE:-4}"
BBUF_SIZE="${BBUF_SIZE:-4}"
PACC_NUM="${PACC_NUM:-4}"
STORE_ROWS_PER_CYCLE="${STORE_ROWS_PER_CYCLE:-1}"
LOAD_DATA_WIDTH="${LOAD_DATA_WIDTH:-1024}"
PERF_TEST="${PERF_TEST:-0}"
PERF_M="${PERF_M:-256}"
PERF_N="${PERF_N:-256}"
PERF_K="${PERF_K:-256}"
PERF_BATCH="${PERF_BATCH:-1}"

# Include all shape-defining parameters so concurrent rectangular builds do
# not share a Verilator build directory.
BUILD_DIR="${BUILD_DIR:-/tmp/top_static_verilator_${SA_WIDTH}_${SUBTILE_M}_${SUBTILE_N}_${SUBTILE_K}_${ABUF_SIZE}_${BBUF_SIZE}_${PACC_NUM}}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

verilator \
  --quiet \
  --sv \
  --cc \
  --exe \
  --build \
  --Wno-fatal \
  --build-jobs "${VERILATOR_JOBS:-1}" \
  --Mdir "${BUILD_DIR}" \
  --top-module top_static \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GLANE_NUM=${LANE_NUM}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GLOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
  "-GSTORE_ROWS_PER_CYCLE=${STORE_ROWS_PER_CYCLE}" \
  -CFLAGS "-O2 -g0 -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM} -DSTORE_ROWS_PER_CYCLE_TEST=${STORE_ROWS_PER_CYCLE} -DLOAD_DATA_WIDTH_TEST=${LOAD_DATA_WIDTH} -DTOP_STATIC_PERF_TEST=${PERF_TEST} -DPERF_M_TEST=${PERF_M} -DPERF_N_TEST=${PERF_N} -DPERF_K_TEST=${PERF_K} -DPERF_BATCH_TEST=${PERF_BATCH}" \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/blocksel.sv" \
  "${ROOT_DIR}/src/sche/new_static_uopparse.sv" \
  "${ROOT_DIR}/src/buf/oprandbuf.sv" \
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv" \
  "${ROOT_DIR}/src/pe/paccreg.sv" \
  "${ROOT_DIR}/src/pe/pe.sv" \
  "${ROOT_DIR}/src/sa/lanebuf.sv" \
  "${ROOT_DIR}/src/sa/sa.sv" \
  "${ROOT_DIR}/src/mem/loadunit.sv" \
  "${ROOT_DIR}/src/mem/storeunit.sv" \
  "${ROOT_DIR}/src/top_static.sv" \
  "${SCRIPT_DIR}/top_static.cpp"

"${BUILD_DIR}/Vtop_static"
