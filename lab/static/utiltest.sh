#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${ROOT_DIR}/data/static/smoke512"
LOG_DIR="${OUT_DIR}/logs"

mkdir -p "${LOG_DIR}"

echo "static_utiltest: running L1_W64"
env \
  REBUILD=1 \
  SUBTILE_K=32 \
  LOAD_DATA_WIDTH=256 \
  ABUF_SIZE=4 \
  BBUF_SIZE=4 \
  PACC_NUM=4 \
  bash "${SCRIPT_DIR}/static.sh" \
  1 64 512 512 512 10 \
  "${OUT_DIR}" \
  2>&1 | tee "${LOG_DIR}/L1_W64.log"

echo "static_utiltest: running L4_W32"
env \
  REBUILD=1 \
  SUBTILE_K=32 \
  LOAD_DATA_WIDTH=256 \
  ABUF_SIZE=8 \
  BBUF_SIZE=8 \
  PACC_NUM=16 \
  bash "${SCRIPT_DIR}/static.sh" \
  4 32 512 512 512 10 \
  "${OUT_DIR}" \
  2>&1 | tee "${LOG_DIR}/L4_W32.log"

echo "static_utiltest: running L16_W16"
env \
  REBUILD=1 \
  SUBTILE_K=32 \
  LOAD_DATA_WIDTH=256 \
  ABUF_SIZE=16 \
  BBUF_SIZE=16 \
  PACC_NUM=64 \
  bash "${SCRIPT_DIR}/static.sh" \
  16 16 512 512 512 10 \
  "${OUT_DIR}" \
  2>&1 | tee "${LOG_DIR}/L16_W16.log"

echo "static_utiltest: all experiments completed"
echo "static_utiltest: results are in ${OUT_DIR}"
