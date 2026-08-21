#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SEED="${SEED:-0x7057a71c}"
BIG="${BIG:-0}"

if [[ "${BIG}" == "1" ]]; then
  SA_WIDTH="${SA_WIDTH:-32}"
  LANE_NUMS="${LANE_NUMS:-1 2 3 4}"
  ABUF_SIZE="${ABUF_SIZE:-64}"
  BBUF_SIZE="${BBUF_SIZE:-64}"
  PACC_NUM="${PACC_NUM:-16}"
  PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-4}"
  UOP_FIFO_DEPTH="${UOP_FIFO_DEPTH:-32}"
  STORE_ROW_WRITE_BEATS="${STORE_ROW_WRITE_BEATS:-32}"
  GEMM_TRACK_DEPTH="${GEMM_TRACK_DEPTH:-256}"
  OUTPUT_TRACK_DEPTH="${OUTPUT_TRACK_DEPTH:-32}"
else
  SA_WIDTH="${SA_WIDTH:-2}"
  LANE_NUMS="${LANE_NUMS:-${LANE_NUM:-2}}"
  ABUF_SIZE="${ABUF_SIZE:-4}"
  BBUF_SIZE="${BBUF_SIZE:-4}"
  PACC_NUM="${PACC_NUM:-4}"
  PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-2}"
  UOP_FIFO_DEPTH="${UOP_FIFO_DEPTH:-16}"
  STORE_ROW_WRITE_BEATS="${STORE_ROW_WRITE_BEATS:-2}"
  GEMM_TRACK_DEPTH="${GEMM_TRACK_DEPTH:-32}"
  OUTPUT_TRACK_DEPTH="${OUTPUT_TRACK_DEPTH:-8}"
fi

PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"
GEMM_INSTID_WIDTH="${GEMM_INSTID_WIDTH:-16}"
VERILATOR_JOBS="${VERILATOR_JOBS:-$([[ "${BIG}" == "1" ]] && echo 4 || echo 1)}"

BUILD_ROOT="${BUILD_DIR:-$(mktemp -d /tmp/top_static_verilator.XXXXXX)}"

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  trap 'rm -rf "${BUILD_ROOT}"' EXIT
fi

mkdir -p "${BUILD_ROOT}"

for LANE_NUM in ${LANE_NUMS}; do
  BUILD_DIR_LANE="${BUILD_ROOT}/lane${LANE_NUM}"
  rm -rf "${BUILD_DIR_LANE}"
  mkdir -p "${BUILD_DIR_LANE}"

  echo "top_static: build/run SA_WIDTH=${SA_WIDTH} LANE_NUM=${LANE_NUM} BIG=${BIG} SEED=${SEED}"

  verilator \
    --quiet \
    --sv \
    --cc \
    --exe \
    --build \
    --build-jobs "${VERILATOR_JOBS}" \
    --Mdir "${BUILD_DIR_LANE}" \
    --top-module top_static \
    "-GSA_WIDTH=${SA_WIDTH}" \
    "-GLANE_NUM=${LANE_NUM}" \
    "-GABUF_SIZE=${ABUF_SIZE}" \
    "-GBBUF_SIZE=${BBUF_SIZE}" \
    "-GPACC_NUM=${PACC_NUM}" \
    "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
    "-GADDR_WIDTH=${ADDR_WIDTH}" \
    "-GDIM_WIDTH=${DIM_WIDTH}" \
    "-GUOP_FIFO_DEPTH=${UOP_FIFO_DEPTH}" \
    "-GSTORE_ROW_WRITE_BEATS=${STORE_ROW_WRITE_BEATS}" \
    "-GGEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
    "-GGEMM_TRACK_DEPTH=${GEMM_TRACK_DEPTH}" \
    "-GOUTPUT_TRACK_DEPTH=${OUTPUT_TRACK_DEPTH}" \
    -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DLANE_NUM_TEST=${LANE_NUM} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH} -DSTORE_ROW_WRITE_BEATS_TEST=${STORE_ROW_WRITE_BEATS} -DTOP_STATIC_BIG_TEST=${BIG}" \
    "${ROOT_DIR}/src/sche/uop.sv" \
    "${ROOT_DIR}/src/sche/static_uopparse.sv" \
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

  "${BUILD_DIR_LANE}/Vtop_static" --seed="${SEED}"
done
