#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x51a5a123}"
STRESS="${STRESS:-0}"
if [[ "${STRESS}" == "1" ]]; then
  SA_WIDTH="${SA_WIDTH:-4}"
  SUBTILE_K="${SUBTILE_K:-4}"
  LANE_NUM="${LANE_NUM:-5}"
else
  SA_WIDTH="${SA_WIDTH:-2}"
  SUBTILE_K="${SUBTILE_K:-3}"
  LANE_NUM="${LANE_NUM:-2}"
fi
PACC_NUM="${PACC_NUM:-8}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-3}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"
GETACC_ROWS_PER_CYCLE="${GETACC_ROWS_PER_CYCLE:-1}"
GEMM_INSTID_WIDTH="${GEMM_INSTID_WIDTH:-16}"
CXX_OPT_FLAGS="${CXX_OPT_FLAGS:--O0 -g0}"
VERILATOR_BUILD_JOBS="${VERILATOR_BUILD_JOBS:-4}"
read -r -a VERILATOR_EXTRA_FLAGS <<< "${VERILATOR_EXTRA_FLAGS:---hierarchical --hierarchical-threads 2}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/sa_verilator.XXXXXX)"
else
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
fi

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  trap 'rm -rf "${BUILD_DIR}"' EXIT
fi

verilator \
  --sv \
  --cc \
  --exe \
  --build \
  --build-jobs "${VERILATOR_BUILD_JOBS}" \
  --Mdir "${BUILD_DIR}" \
  --top-module sa \
  "${VERILATOR_EXTRA_FLAGS[@]}" \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GLANE_NUM=${LANE_NUM}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  "-GPACC_EXP_WIDTH=${PACC_EXP_WIDTH}" \
  "-GPACC_SIG_WIDTH=${PACC_SIG_WIDTH}" \
  "-GGEMM_INSTID_WIDTH=${GEMM_INSTID_WIDTH}" \
  "-GGETACC_ROWS_PER_CYCLE=${GETACC_ROWS_PER_CYCLE}" \
  -CFLAGS "${CXX_OPT_FLAGS} -DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_K_TEST=${SUBTILE_K} -DLANE_NUM_TEST=${LANE_NUM} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH} -DGETACC_ROWS_PER_CYCLE_TEST=${GETACC_ROWS_PER_CYCLE}" \
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv" \
  "${ROOT_DIR}/src/pe/paccreg.sv" \
  "${ROOT_DIR}/src/pe/pe.sv" \
  "${ROOT_DIR}/src/sa/lanebuf.sv" \
  "${ROOT_DIR}/src/sa/sa.sv" \
  "${SCRIPT_DIR}/sa.cpp"

"${BUILD_DIR}/Vsa" --seed="${SEED}"
