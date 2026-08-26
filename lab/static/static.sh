#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 6 && "$#" -ne 7 ]]; then
  echo "usage: $0 Lane Width M N K Count [OutDir]" >&2
  exit 2
fi

LANE_NUM="$1"
SA_WIDTH="$2"
M_SIZE="$3"
N_SIZE="$4"
K_SIZE="$5"
COUNT="$6"
OUT_DIR="${7:-${OUT_DIR:-./data}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SUBTILE_K="${SUBTILE_K:-32}"
LOAD_DATA_WIDTH="${LOAD_DATA_WIDTH:-256}"
ABUF_SIZE="${ABUF_SIZE:-16}"
BBUF_SIZE="${BBUF_SIZE:-16}"
PACC_NUM="${PACC_NUM:-16}"
STORE_ROW_WRITE_BEATS="${STORE_ROW_WRITE_BEATS:-${SA_WIDTH}}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"
UOP_FIFO_DEPTH="${UOP_FIFO_DEPTH:-32}"
GEMM_INSTID_WIDTH="${GEMM_INSTID_WIDTH:-16}"
GEMM_TRACK_DEPTH="${GEMM_TRACK_DEPTH:-256}"
OUTPUT_TRACK_DEPTH="${OUTPUT_TRACK_DEPTH:-32}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"
VERILATOR_JOBS="${VERILATOR_JOBS:-4}"
CXX_OPT_FLAGS="${CXX_OPT_FLAGS:--O3 -g0}"
VERILATOR_EXTRA_FLAGS="${VERILATOR_EXTRA_FLAGS:---hierarchical --hierarchical-threads 2}"
BUILD_ROOT="${BUILD_DIR:-/tmp/ooogemm_static_lab_L${LANE_NUM}_W${SA_WIDTH}}"
MAX_CYCLES="${MAX_CYCLES:-0}"
LOAD_RSP_DELAY="${LOAD_RSP_DELAY:-4}"

read -r -a VERILATOR_EXTRA_FLAGS_ARR <<< "${VERILATOR_EXTRA_FLAGS}"

mkdir -p "${BUILD_ROOT}" "${OUT_DIR}"

OUT_FILE="${OUT_DIR}/L${LANE_NUM}_W${SA_WIDTH}_${M_SIZE}X${N_SIZE}X${K_SIZE}_Cnt${COUNT}.txt"
EXE="${BUILD_ROOT}/Vtop_static"

SOURCES=(
  "${ROOT_DIR}/src/sche/uop.sv"
  "${ROOT_DIR}/src/sche/static_uopparse.sv"
  "${ROOT_DIR}/src/buf/oprandbuf.sv"
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv"
  "${ROOT_DIR}/src/pe/paccreg.sv"
  "${ROOT_DIR}/src/pe/pe.sv"
  "${ROOT_DIR}/src/sa/lanebuf.sv"
  "${ROOT_DIR}/src/sa/sa.sv"
  "${ROOT_DIR}/src/mem/loadunit.sv"
  "${ROOT_DIR}/src/mem/storeunit.sv"
  "${ROOT_DIR}/src/top_static.sv"
  "${SCRIPT_DIR}/static.cpp"
)

BUILD_STAMP="${BUILD_ROOT}/.static_lab_build_key"
BUILD_KEY="$({
  printf '%s\n' \
    "LANE_NUM=${LANE_NUM}" \
    "SA_WIDTH=${SA_WIDTH}" \
    "SUBTILE_K=${SUBTILE_K}" \
    "LOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
    "ABUF_SIZE=${ABUF_SIZE}" \
    "BBUF_SIZE=${BBUF_SIZE}" \
    "PACC_NUM=${PACC_NUM}" \
    "STORE_ROW_WRITE_BEATS=${STORE_ROW_WRITE_BEATS}" \
    "ADDR_WIDTH=${ADDR_WIDTH}" \
    "DIM_WIDTH=${DIM_WIDTH}" \
    "UOP_FIFO_DEPTH=${UOP_FIFO_DEPTH}" \
    "GEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
    "GEMM_TRACK_DEPTH=${GEMM_TRACK_DEPTH}" \
    "OUTPUT_TRACK_DEPTH=${OUTPUT_TRACK_DEPTH}" \
    "PACC_EXP_WIDTH=${PACC_EXP_WIDTH}" \
    "PACC_SIG_WIDTH=${PACC_SIG_WIDTH}" \
    "CXX_OPT_FLAGS=${CXX_OPT_FLAGS}" \
    "VERILATOR_EXTRA_FLAGS=${VERILATOR_EXTRA_FLAGS}"
  for src in "${SOURCES[@]}"; do
    stat -c '%n:%s:%Y' "${src}"
  done
} | sha256sum | cut -d' ' -f1)"

echo "static_lab: build/run LANE=${LANE_NUM} WIDTH=${SA_WIDTH} MNK=${M_SIZE}x${N_SIZE}x${K_SIZE} COUNT=${COUNT}"

if [[ "${REBUILD:-0}" == "1" || ! -x "${EXE}" || ! -f "${BUILD_STAMP}" || "$(cat "${BUILD_STAMP}")" != "${BUILD_KEY}" ]]; then
  echo "static_lab: compile LANE=${LANE_NUM} WIDTH=${SA_WIDTH}"
  verilator \
    --quiet \
    --sv \
    --cc \
    --exe \
    --build \
    --build-jobs "${VERILATOR_JOBS}" \
    --Mdir "${BUILD_ROOT}" \
    --top-module top_static \
    "${VERILATOR_EXTRA_FLAGS_ARR[@]}" \
    "-GSA_WIDTH=${SA_WIDTH}" \
    "-GSUBTILE_K=${SUBTILE_K}" \
    "-GLANE_NUM=${LANE_NUM}" \
    "-GABUF_SIZE=${ABUF_SIZE}" \
    "-GBBUF_SIZE=${BBUF_SIZE}" \
    "-GPACC_NUM=${PACC_NUM}" \
    "-GADDR_WIDTH=${ADDR_WIDTH}" \
    "-GDIM_WIDTH=${DIM_WIDTH}" \
    "-GUOP_FIFO_DEPTH=${UOP_FIFO_DEPTH}" \
    "-GSTORE_ROW_WRITE_BEATS=${STORE_ROW_WRITE_BEATS}" \
    "-GLOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
    "-GGEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
    "-GGEMM_TRACK_DEPTH=${GEMM_TRACK_DEPTH}" \
    "-GOUTPUT_TRACK_DEPTH=${OUTPUT_TRACK_DEPTH}" \
    -CFLAGS "${CXX_OPT_FLAGS} -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_K_TEST=${SUBTILE_K} -DLANE_NUM_TEST=${LANE_NUM} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH} -DSTORE_ROW_WRITE_BEATS_TEST=${STORE_ROW_WRITE_BEATS} -DLOAD_DATA_WIDTH_TEST=${LOAD_DATA_WIDTH}" \
    "${SOURCES[@]}"
  printf '%s\n' "${BUILD_KEY}" > "${BUILD_STAMP}"
else
  echo "static_lab: reuse ${EXE}"
fi

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  echo "static_lab: build-only done ${EXE}"
  exit 0
fi

"${EXE}" \
  "--m=${M_SIZE}" \
  "--n=${N_SIZE}" \
  "--k=${K_SIZE}" \
  "--count=${COUNT}" \
  "--out-dir=${OUT_DIR}" \
  "--max-cycles=${MAX_CYCLES}" \
  "--load-rsp-delay=${LOAD_RSP_DELAY}"

echo "static_lab: wrote ${OUT_FILE}"
