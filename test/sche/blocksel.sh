#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/blocksel_verilator.XXXXXX)}"
SA_WIDTH="${SA_WIDTH:-16}"
SUBTILE_M="${SUBTILE_M:-${SA_WIDTH}}"
SUBTILE_N="${SUBTILE_N:-${SA_WIDTH}}"
LOGIC_ABUF_SIZE="${LOGIC_ABUF_SIZE:-12}"
LOGIC_BBUF_SIZE="${LOGIC_BBUF_SIZE:-12}"
LOGIC_ACC_NUM="${LOGIC_ACC_NUM:-16}"
UNROLL_NUM="${UNROLL_NUM:-2}"

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
  trap 'rm -rf "${BUILD_DIR}"' EXIT
else
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
fi

verilator \
  --quiet \
  --sv \
  --cc \
  --exe \
  --build \
  --Mdir "${BUILD_DIR}" \
  --top-module blocksel \
  "-GSA_WIDTH=${SA_WIDTH}" \
  "-GSUBTILE_M=${SUBTILE_M}" \
  "-GSUBTILE_N=${SUBTILE_N}" \
  "-GLOGIC_ABUF_SIZE=${LOGIC_ABUF_SIZE}" \
  "-GLOGIC_BBUF_SIZE=${LOGIC_BBUF_SIZE}" \
  "-GLOGIC_ACC_NUM=${LOGIC_ACC_NUM}" \
  "-GUNROLL_NUM=${UNROLL_NUM}" \
  -CFLAGS "-O2 -DSUBTILE_M_TEST=${SUBTILE_M} -DSUBTILE_N_TEST=${SUBTILE_N} -DLOGIC_ABUF_SIZE_TEST=${LOGIC_ABUF_SIZE} -DLOGIC_BBUF_SIZE_TEST=${LOGIC_BBUF_SIZE} -DLOGIC_ACC_NUM_TEST=${LOGIC_ACC_NUM}" \
  "${ROOT_DIR}/src/sche/blocksel.sv" \
  "${SCRIPT_DIR}/blocksel.cpp"

"${BUILD_DIR}/Vblocksel"
