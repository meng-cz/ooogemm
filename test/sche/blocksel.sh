#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d /tmp/blocksel_verilator.XXXXXX)}"

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
  -GSA_WIDTH=16 \
  -GLOGIC_ABUF_SIZE=12 \
  -GLOGIC_BBUF_SIZE=12 \
  -GLOGIC_ACC_NUM=16 \
  -GUNROLL_NUM=2 \
  -CFLAGS "-O2" \
  "${ROOT_DIR}/src/sche/blocksel.sv" \
  "${SCRIPT_DIR}/blocksel.cpp"

"${BUILD_DIR}/Vblocksel"
