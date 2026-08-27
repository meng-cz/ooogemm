#!/usr/bin/env bash
set -euo pipefail

# Run the small, single-lane static configuration.  The production
# parameterized RTL and lab/static.cpp are used so this test follows the
# same scheduling and bus model as the full experiments.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${ROOT_DIR}/debug/data"
LOG_DIR="${OUT_DIR}/logs"
BUILD_DIR="${BUILD_DIR:-/tmp/ooogemm_debug_static_L1_W8}"

mkdir -p "${LOG_DIR}"

echo "static_debug: configuration L1_W8 SUBTILE_K=16 LOAD_DATA_WIDTH=1024"
echo "static_debug: command B=1 M=64 N=64 K=64 Count=1"

env \
  REBUILD="${REBUILD:-1}" \
  SUBTILE_K=16 \
  LOAD_DATA_WIDTH=1024 \
  ABUF_SIZE=4 \
  BBUF_SIZE=4 \
  PACC_NUM=4 \
  STORE_ROWS_PER_CYCLE=1 \
  BUILD_DIR="${BUILD_DIR}" \
  VERILATOR_JOBS="${VERILATOR_JOBS:-1}" \
  bash "${ROOT_DIR}/lab/static/static.sh" \
  1 8 64 64 64 1 \
  "${OUT_DIR}" \
  2>&1 | tee "${LOG_DIR}/static_debug.log"

echo "static_debug: result: ${OUT_DIR}/L1_W8_64X64X64_Cnt1.txt"

# Export the exact parser stream used by this parameter configuration for
# cycle-by-cycle inspection.  OUTPUT should appear only after all K-waves of
# each PACC block have completed.
bash "${SCRIPT_DIR}/export_uops.sh" \
  "${OUT_DIR}/static_uops_64x64x64.txt"
