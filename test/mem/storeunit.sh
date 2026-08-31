#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x5700e123}"

SA_WIDTH="${SA_WIDTH:-2}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
PACC_NUM="${PACC_NUM:-8}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
ROWS_PER_CYCLE="${ROWS_PER_CYCLE:-1}"

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
MEM_DATA_WIDTH="${MEM_DATA_WIDTH:-$((SUBTILE_N * 32 * ROWS_PER_CYCLE))}"

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
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GADDR_WIDTH=${ADDR_WIDTH}" \
  "-GPACC_IDX_WIDTH=${PACC_IDX_WIDTH}" \
  "-GROWS_PER_CYCLE=${ROWS_PER_CYCLE}" \
  "-GMEM_DATA_WIDTH=${MEM_DATA_WIDTH}" \
  -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DPACC_NUM_TEST=${PACC_NUM} -DPACC_IDX_WIDTH_TEST=${PACC_IDX_WIDTH} -DROWS_PER_CYCLE_TEST=${ROWS_PER_CYCLE} -DMEM_DATA_WIDTH_TEST=${MEM_DATA_WIDTH}" \
  "${ROOT_DIR}/src/mem/storeunit.sv" \
  "${SCRIPT_DIR}/storeunit.cpp"

"${BUILD_DIR}/Vstoreunit" --seed="${SEED}"
