#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SA_WIDTH="${SA_WIDTH:-32}"
ABUF_SIZE="${ABUF_SIZE:-4}"
BBUF_SIZE="${BBUF_SIZE:-4}"
PACC_NUM="${PACC_NUM:-4}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"

clog2_width() {
  local value="$1"
  local width=0
  local x=$((value - 1))
  while (( x > 0 )); do
    width=$((width + 1))
    x=$((x >> 1))
  done
  if (( width < 1 )); then
    width=1
  fi
  printf '%d\n' "${width}"
}

ABUF_IDX_WIDTH="${ABUF_IDX_WIDTH:-$(clog2_width "${ABUF_SIZE}")}"
BBUF_IDX_WIDTH="${BBUF_IDX_WIDTH:-$(clog2_width "${BBUF_SIZE}")}"
PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-$(clog2_width "${PACC_NUM}")}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/static_uopparse_verilator.XXXXXX)"
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
  --top-module static_uopparse \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GADDR_WIDTH=${ADDR_WIDTH}" \
  "-GDIM_WIDTH=${DIM_WIDTH}" \
  "-GABUF_IDX_WIDTH=${ABUF_IDX_WIDTH}" \
  "-GBBUF_IDX_WIDTH=${BBUF_IDX_WIDTH}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DPACC_NUM_TEST=${PACC_NUM}" \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/static_uopparse.sv" \
  "${SCRIPT_DIR}/static_uopparse.cpp"

"${BUILD_DIR}/Vstatic_uopparse"
