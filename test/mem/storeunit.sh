#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x5700e123}"

SA_WIDTH="${SA_WIDTH:-2}"
PACC_NUM="${PACC_NUM:-8}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
ROW_WRITE_BEATS="${ROW_WRITE_BEATS:-2}"

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

PACC_IDX_WIDTH="${PACC_IDX_WIDTH:-$(clog2_width "${PACC_NUM}")}"
MEM_DATA_WIDTH="${MEM_DATA_WIDTH:-$(((SA_WIDTH * 32) / ROW_WRITE_BEATS))}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/storeunit_verilator.XXXXXX)"
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
  --top-module storeunit \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GADDR_WIDTH=${ADDR_WIDTH}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  "-GROW_WRITE_BEATS=${ROW_WRITE_BEATS}" \
  "-GMEM_DATA_WIDTH=${MEM_DATA_WIDTH}" \
  -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DROW_WRITE_BEATS_TEST=${ROW_WRITE_BEATS} -DMEM_DATA_WIDTH_TEST=${MEM_DATA_WIDTH}" \
  "${ROOT_DIR}/src/mem/storeunit.sv" \
  "${SCRIPT_DIR}/storeunit.cpp"

"${BUILD_DIR}/Vstoreunit" --seed="${SEED}"
