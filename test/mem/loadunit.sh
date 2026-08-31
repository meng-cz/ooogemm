#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x10ad1234}"

SA_WIDTH="${SA_WIDTH:-4}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
SUBTILE_K="${SUBTILE_K:-4}"
ABUF_SIZE="${ABUF_SIZE:-8}"
BBUF_SIZE="${BBUF_SIZE:-8}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
BUS_ID_WIDTH="${BUS_ID_WIDTH:-3}"
LOAD_DATA_WIDTH="${LOAD_DATA_WIDTH:-1024}"

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

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/loadunit_verilator.XXXXXX)"
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
  --top-module loadunit \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GADDR_WIDTH=${ADDR_WIDTH}" \
  "-GABUF_IDX_WIDTH=${ABUF_IDX_WIDTH}" \
  "-GBBUF_IDX_WIDTH=${BBUF_IDX_WIDTH}" \
  "-GBUS_ID_WIDTH=${BUS_ID_WIDTH}" \
  "-GLOAD_DATA_WIDTH=${LOAD_DATA_WIDTH}" \
  -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DABUF_SIZE_TEST=${ABUF_SIZE} -DBBUF_SIZE_TEST=${BBUF_SIZE} -DBUS_ID_WIDTH_TEST=${BUS_ID_WIDTH} -DLOAD_DATA_WIDTH_TEST=${LOAD_DATA_WIDTH}" \
  "${ROOT_DIR}/src/mem/loadunit.sv" \
  "${SCRIPT_DIR}/loadunit.cpp"

"${BUILD_DIR}/Vloadunit" --seed="${SEED}"
