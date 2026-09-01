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

# Rectangular shapes are selected by lane count when no explicit shape is
# supplied: all three configurations keep the same 4096 physical MACs.
case "${LANE_NUM}" in
  1) DEFAULT_SUBTILE_M=32 ;;
  4) DEFAULT_SUBTILE_M=16 ;;
  16) DEFAULT_SUBTILE_M=8 ;;
  *) DEFAULT_SUBTILE_M="${SA_WIDTH}" ;;
esac
SUBTILE_M="${SUBTILE_M:-${DEFAULT_SUBTILE_M}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
SUBTILE_K="${SUBTILE_K:-32}"
LOAD_DATA_WIDTH="${LOAD_DATA_WIDTH:-1024}"
ABUF_SIZE="${ABUF_SIZE:-32}"
BBUF_SIZE="${BBUF_SIZE:-32}"
PACC_NUM="${PACC_NUM:-128}"
if [[ -z "${STORE_ROWS_PER_CYCLE:-}" ]]; then
  case "${LANE_NUM}" in
    1) STORE_ROWS_PER_CYCLE=1 ;;
    4) STORE_ROWS_PER_CYCLE=2 ;;
    16) STORE_ROWS_PER_CYCLE=4 ;;
    *)  STORE_ROWS_PER_CYCLE=1 ;;
  esac
fi
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"
GEMM_INSTID_WIDTH="${GEMM_INSTID_WIDTH:-16}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"
VERILATOR_JOBS="${VERILATOR_JOBS:-4}"
CXX_OPT_FLAGS="${CXX_OPT_FLAGS:--O3 -g0}"
VERILATOR_EXTRA_FLAGS="${VERILATOR_EXTRA_FLAGS:---hierarchical --hierarchical-threads 2}"
if [[ "${ABUF_SIZE}" == "${BBUF_SIZE}" ]]; then
  CONFIG_TAG="L${LANE_NUM}_W${SA_WIDTH}_AB${ABUF_SIZE}_ACC${PACC_NUM}"
else
  CONFIG_TAG="L${LANE_NUM}_W${SA_WIDTH}_AB${ABUF_SIZE}_BB${BBUF_SIZE}_ACC${PACC_NUM}"
fi
BUILD_ROOT="${BUILD_DIR:-/tmp/ooogemm_rect_static_lab_${CONFIG_TAG}}"
MAX_CYCLES="${MAX_CYCLES:-0}"
LOAD_RSP_DELAY="${LOAD_RSP_DELAY:-4}"

read -r -a VERILATOR_EXTRA_FLAGS_ARR <<< "${VERILATOR_EXTRA_FLAGS}"

mkdir -p "${BUILD_ROOT}" "${OUT_DIR}"

OUT_FILE="${OUT_DIR}/${CONFIG_TAG}_${M_SIZE}X${N_SIZE}X${K_SIZE}_Cnt${COUNT}.txt"
EXE="${BUILD_ROOT}/Vtop_new_static"

SOURCES=(
  "${ROOT_DIR}/src/sche/uop.sv"
  "${ROOT_DIR}/src/sche/blocksel.sv"
  "${ROOT_DIR}/src/sche/new_static_uopparse.sv"
  "${ROOT_DIR}/src/buf/oprandbuf.sv"
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv"
  "${ROOT_DIR}/src/pe/paccreg.sv"
  "${ROOT_DIR}/src/pe/pe.sv"
  "${ROOT_DIR}/src/sa/lanebuf.sv"
  "${ROOT_DIR}/src/sa/sa.sv"
  "${ROOT_DIR}/src/mem/loadunit.sv"
  "${ROOT_DIR}/src/mem/storeunit.sv"
  "${ROOT_DIR}/src/top_new_static.sv"
  "${SCRIPT_DIR}/static.cpp"
)

BUILD_STAMP="${BUILD_ROOT}/.new_static_lab_build_key"
BUILD_KEY="$({
  printf '%s\n' \
    "LANE_NUM=${LANE_NUM}" \
    "SA_WIDTH=${SA_WIDTH}" \
    "SUBTILE_M=${SUBTILE_M}" \
    "SUBTILE_N=${SUBTILE_N}" \
    "SUBTILE_K=${SUBTILE_K}" \
    "LOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
    "ABUF_SIZE=${ABUF_SIZE}" \
    "BBUF_SIZE=${BBUF_SIZE}" \
    "PACC_NUM=${PACC_NUM}" \
    "STORE_ROWS_PER_CYCLE=${STORE_ROWS_PER_CYCLE}" \
    "ADDR_WIDTH=${ADDR_WIDTH}" \
    "DIM_WIDTH=${DIM_WIDTH}" \
    "GEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
    "PACC_EXP_WIDTH=${PACC_EXP_WIDTH}" \
    "PACC_SIG_WIDTH=${PACC_SIG_WIDTH}" \
    "CXX_OPT_FLAGS=${CXX_OPT_FLAGS}" \
    "VERILATOR_EXTRA_FLAGS=${VERILATOR_EXTRA_FLAGS}"
  for src in "${SOURCES[@]}"; do
    stat -c '%n:%s:%Y' "${src}"
  done
} | sha256sum | cut -d' ' -f1)"

echo "static_lab: build/run CONFIG=${CONFIG_TAG} MNK=${M_SIZE}x${N_SIZE}x${K_SIZE} COUNT=${COUNT} LOAD_DATA_WIDTH=${LOAD_DATA_WIDTH} STORE_ROWS_PER_CYCLE=${STORE_ROWS_PER_CYCLE}"

if [[ "${REBUILD:-0}" == "1" || ! -x "${EXE}" || ! -f "${BUILD_STAMP}" || "$(cat "${BUILD_STAMP}")" != "${BUILD_KEY}" ]]; then
  echo "static_lab: compile CONFIG=${CONFIG_TAG}"
  verilator \
    --quiet \
    --sv \
    --cc \
    --exe \
    --build \
    --build-jobs "${VERILATOR_JOBS}" \
    --Mdir "${BUILD_ROOT}" \
    --top-module top_new_static \
    "${VERILATOR_EXTRA_FLAGS_ARR[@]}" \
    "-GSA_WIDTH=${SA_WIDTH}" \
    "-GSUBTILE_M=${SUBTILE_M}" \
    "-GSUBTILE_N=${SUBTILE_N}" \
    "-GSUBTILE_K=${SUBTILE_K}" \
    "-GLANE_NUM=${LANE_NUM}" \
    "-GABUF_SIZE=${ABUF_SIZE}" \
    "-GBBUF_SIZE=${BBUF_SIZE}" \
    "-GPACC_NUM=${PACC_NUM}" \
    "-GADDR_WIDTH=${ADDR_WIDTH}" \
    "-GDIM_WIDTH=${DIM_WIDTH}" \
    "-GSTORE_ROWS_PER_CYCLE=${STORE_ROWS_PER_CYCLE}" \
    "-GLOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
    "-GGEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
    -CFLAGS "${CXX_OPT_FLAGS} -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DLANE_NUM_TEST=${LANE_NUM} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH} -DSTORE_ROWS_PER_CYCLE_TEST=${STORE_ROWS_PER_CYCLE} -DLOAD_DATA_WIDTH_TEST=${LOAD_DATA_WIDTH}" \
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
