#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x5eed1234}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-7}"
ACC_WIDTH="${ACC_WIDTH:-62}"
ACC_FRAC_BITS="${ACC_FRAC_BITS:-18}"
FDOT_CSA_WIDTH="${FDOT_CSA_WIDTH:-64}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/fdot8e4m3_verilator.XXXXXX)"
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
  --top-module fdot8e4m3 \
  "-GACC_WIDTH=${ACC_WIDTH}" \
  "-GACC_FRAC_BITS=${ACC_FRAC_BITS}" \
  "-GFDOT_CSA_WIDTH=${FDOT_CSA_WIDTH}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  -CFLAGS "-DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DACC_FRAC_BITS_TEST=${ACC_FRAC_BITS} -DFDOT_CSA_WIDTH_TEST=${FDOT_CSA_WIDTH}" \
  "${ROOT_DIR}/src/pe/fdot8e4m3.sv" \
  "${SCRIPT_DIR}/fdot8e4m3.cpp"

"${BUILD_DIR}/Vfdot8e4m3" --seed="${SEED}"
