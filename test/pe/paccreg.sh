#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0xacc123}"
PACC_NUM="${PACC_NUM:-8}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-3}"
PACC_EXP_WIDTH="${PACC_EXP_WIDTH:-10}"
PACC_SIG_WIDTH="${PACC_SIG_WIDTH:-40}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/paccreg_verilator.XXXXXX)"
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
  --top-module paccreg \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  "-GPACC_EXP_WIDTH=${PACC_EXP_WIDTH}" \
  "-GPACC_SIG_WIDTH=${PACC_SIG_WIDTH}" \
  -CFLAGS "-DPACC_NUM_TEST=${PACC_NUM} -DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DPACC_EXP_WIDTH_TEST=${PACC_EXP_WIDTH} -DPACC_SIG_WIDTH_TEST=${PACC_SIG_WIDTH}" \
  "${ROOT_DIR}/src/pe/paccreg.sv" \
  "${SCRIPT_DIR}/paccreg.cpp"

"${BUILD_DIR}/Vpaccreg" --seed="${SEED}"
