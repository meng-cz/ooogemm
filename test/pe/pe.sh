#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x0fee123}"
GEMM_LANE_NUM="${GEMM_LANE_NUM:-4}"
PACC_NUM="${PACC_NUM:-8}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-3}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/pe_verilator.XXXXXX)"
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
  --Mdir "${BUILD_DIR}" \
  --top-module pe \
  "-GGEMM_LANE_NUM=${GEMM_LANE_NUM}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  "-GPACC_EXP_WIDTH=${PACC_EXP_WIDTH}" \
  "-GPACC_SIG_WIDTH=${PACC_SIG_WIDTH}" \
  -CFLAGS "-DGEMM_LANE_NUM_TEST=${GEMM_LANE_NUM} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH}" \
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv" \
  "${ROOT_DIR}/src/pe/paccreg.sv" \
  "${ROOT_DIR}/src/pe/pe.sv" \
  "${SCRIPT_DIR}/pe.cpp"

"${BUILD_DIR}/Vpe" --seed="${SEED}"
