#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SEED="${SEED:-0x7057a71c}"
BIG="${BIG:-0}"

if [[ "${BIG}" == "1" ]]; then
  SA_WIDTH="${SA_WIDTH:-32}"
  SUBTILE_K="${SUBTILE_K:-32}"
  LANE_NUMS="${LANE_NUMS:-1 2 3 4}"
  ABUF_SIZE="${ABUF_SIZE:-64}"
  BBUF_SIZE="${BBUF_SIZE:-64}"
  PACC_NUM="${PACC_NUM:-16}"
  PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-4}"
  UOP_FIFO_DEPTH="${UOP_FIFO_DEPTH:-32}"
  STORE_ROWS_PER_CYCLE="${STORE_ROWS_PER_CYCLE:-2}"
  GEMM_TRACK_DEPTH="${GEMM_TRACK_DEPTH:-256}"
  OUTPUT_TRACK_DEPTH="${OUTPUT_TRACK_DEPTH:-32}"
else
  SA_WIDTH="${SA_WIDTH:-2}"
  SUBTILE_K="${SUBTILE_K:-2}"
  LANE_NUMS="${LANE_NUMS:-${LANE_NUM:-2}}"
  ABUF_SIZE="${ABUF_SIZE:-4}"
  BBUF_SIZE="${BBUF_SIZE:-4}"
  PACC_NUM="${PACC_NUM:-4}"
  PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-2}"
  UOP_FIFO_DEPTH="${UOP_FIFO_DEPTH:-16}"
  STORE_ROWS_PER_CYCLE="${STORE_ROWS_PER_CYCLE:-1}"
  GEMM_TRACK_DEPTH="${GEMM_TRACK_DEPTH:-32}"
  OUTPUT_TRACK_DEPTH="${OUTPUT_TRACK_DEPTH:-8}"
fi

SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"
LOAD_DATA_WIDTH="${LOAD_DATA_WIDTH:-256}"
GEMM_INSTID_WIDTH="${GEMM_INSTID_WIDTH:-16}"
VERILATOR_JOBS="${VERILATOR_JOBS:-$([[ "${BIG}" == "1" ]] && echo 4 || echo 1)}"
CXX_OPT_FLAGS="${CXX_OPT_FLAGS:-$([[ "${BIG}" == "1" ]] && echo "-O3 -g0" || echo "-O0 -g0")}"
read -r -a VERILATOR_EXTRA_FLAGS <<< "${VERILATOR_EXTRA_FLAGS:-$([[ "${BIG}" == "1" ]] && echo "--hierarchical --hierarchical-threads 2" || echo "")}"

BUILD_ROOT="${BUILD_DIR:-$(mktemp -d /tmp/top_dynamic_verilator.XXXXXX)}"

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  trap 'rm -rf "${BUILD_ROOT}"' EXIT
fi

mkdir -p "${BUILD_ROOT}"

for LANE_NUM in ${LANE_NUMS}; do
  BUILD_DIR_LANE="${BUILD_ROOT}/lane${LANE_NUM}"
  rm -rf "${BUILD_DIR_LANE}"
  mkdir -p "${BUILD_DIR_LANE}"

  echo "top_dynamic: build/run SA_WIDTH=${SA_WIDTH} LANE_NUM=${LANE_NUM} BIG=${BIG} SEED=${SEED}"

  verilator \
    --quiet \
    --sv \
    --cc \
    --exe \
    --build \
    --build-jobs "${VERILATOR_JOBS}" \
    --Mdir "${BUILD_DIR_LANE}" \
    --top-module top_dynamic \
    "${VERILATOR_EXTRA_FLAGS[@]}" \
    "-GSA_WIDTH=${SA_WIDTH}" \
    "-GSUBTILE_M=${SUBTILE_M}" \
    "-GSUBTILE_N=${SUBTILE_N}" \
    "-GSUBTILE_K=${SUBTILE_K}" \
    "-GLANE_NUM=${LANE_NUM}" \
    "-GABUF_SIZE=${ABUF_SIZE}" \
    "-GBBUF_SIZE=${BBUF_SIZE}" \
    "-GPACC_NUM=${PACC_NUM}" \
    "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
    "-GADDR_WIDTH=${ADDR_WIDTH}" \
    "-GDIM_WIDTH=${DIM_WIDTH}" \
    "-GSTORE_ROWS_PER_CYCLE=${STORE_ROWS_PER_CYCLE}" \
    "-GLOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
    -CFLAGS "${CXX_OPT_FLAGS} -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DLANE_NUM_TEST=${LANE_NUM} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH} -DSTORE_ROWS_PER_CYCLE_TEST=${STORE_ROWS_PER_CYCLE} -DLOAD_DATA_WIDTH_TEST=${LOAD_DATA_WIDTH} -DTOP_DYNAMIC_BIG_TEST=${BIG}" \
    "${ROOT_DIR}/src/sche/uop.sv" \
    "${ROOT_DIR}/src/sche/blocksel.sv" \
    "${ROOT_DIR}/src/sche/dynamic_uopparse.sv" \
    "${ROOT_DIR}/src/sche/dynamic_rename.sv" \
    "${ROOT_DIR}/src/sche/dynamic_sche.sv" \
    "${ROOT_DIR}/src/buf/oprandbuf.sv" \
    "${ROOT_DIR}/src/sram/sram1r1w.sv" \
    "${ROOT_DIR}/src/pe/fdot8e4m3.sv" \
    "${ROOT_DIR}/src/pe/paccreg.sv" \
    "${ROOT_DIR}/src/sram/sram2r1w.sv" \
    "${ROOT_DIR}/src/pe/pe.sv" \
    "${ROOT_DIR}/src/sa/lanebuf.sv" \
    "${ROOT_DIR}/src/sa/sa.sv" \
    "${ROOT_DIR}/src/mem/loadunit.sv" \
    "${ROOT_DIR}/src/mem/storeunit.sv" \
    "${ROOT_DIR}/src/top_dynamic.sv" \
    "${SCRIPT_DIR}/top_dynamic.cpp"

  "${BUILD_DIR_LANE}/Vtop_dynamic" --seed="${SEED}"
done
