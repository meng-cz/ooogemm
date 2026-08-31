#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SEED="${SEED:-0x5eed1234}"

SA_WIDTH="${SA_WIDTH:-32}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
SUBTILE_K="${SUBTILE_K:-32}"
ABUF_SIZE="${ABUF_SIZE:-2}"
BBUF_SIZE="${BBUF_SIZE:-2}"
PACC_NUM="${PACC_NUM:-2}"
ABUF_LOGIC_SIZE="${ABUF_LOGIC_SIZE:-4}"
BBUF_LOGIC_SIZE="${BBUF_LOGIC_SIZE:-4}"
PACC_LOGIC_SIZE="${PACC_LOGIC_SIZE:-16}"
ADDR_WIDTH="${ADDR_WIDTH:-32}"
DIM_WIDTH="${DIM_WIDTH:-16}"

if [[ -z "${BUILD_DIR:-}" ]]; then
  BUILD_DIR="$(mktemp -d /tmp/dynamic_uopparse_verilator.XXXXXX)"
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
  --top-module dynamic_uopparse \
  --prefix Vuopparse \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GSUBTILE_K=${SUBTILE_K}" \
  "-GABUF_SIZE=${ABUF_SIZE}" \
  "-GBBUF_SIZE=${BBUF_SIZE}" \
  "-GPACC_NUM=${PACC_NUM}" \
  "-GABUF_LOGIC_SIZE=${ABUF_LOGIC_SIZE}" \
  "-GBBUF_LOGIC_SIZE=${BBUF_LOGIC_SIZE}" \
  "-GPACC_LOGIC_SIZE=${PACC_LOGIC_SIZE}" \
  "-GADDR_WIDTH=${ADDR_WIDTH}" \
  "-GDIM_WIDTH=${DIM_WIDTH}" \
  -CFLAGS "-DSA_WIDTH_TEST=${SA_WIDTH} -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DSUBTILE_K_TEST=${SUBTILE_K} -DABUF_SIZE_TEST=${ABUF_LOGIC_SIZE} -DBBUF_SIZE_TEST=${BBUF_LOGIC_SIZE} -DPACC_NUM_TEST=${PACC_LOGIC_SIZE}" \
  "${ROOT_DIR}/src/sche/uop.sv" \
  "${ROOT_DIR}/src/sche/dynamic_uopparse.sv" \
  "${SCRIPT_DIR}/dynamic_uopparse.cpp"

"${BUILD_DIR}/Vuopparse" --seed="${SEED}"
