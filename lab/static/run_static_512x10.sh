#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="/home/null/ooogemm/lab/static"
RESULT_DIR="${RESULT_DIR:-/tmp/static_perf_512x10}"
LOG_DIR="${LOG_DIR:-${RESULT_DIR}/logs}"
REBUILD="${REBUILD:-0}"

mkdir -p "${RESULT_DIR}" "${LOG_DIR}"

run_case() {
  local label="$1"
  local lane="$2"
  local width="$3"
  local abuf="$4"
  local bbuf="$5"
  local pacc="$6"

  echo "[$(date -u +%FT%TZ)] start ${label}" | tee "${LOG_DIR}/${label}.log"
  env \
    REBUILD="${REBUILD}" \
    ABUF_SIZE="${abuf}" \
    BBUF_SIZE="${bbuf}" \
    PACC_NUM="${pacc}" \
    bash "${SCRIPT_DIR}/static.sh" \
      "${lane}" "${width}" 512 512 512 10 "${RESULT_DIR}" \
    2>&1 | tee -a "${LOG_DIR}/${label}.log"
  echo "[$(date -u +%FT%TZ)] done ${label}" | tee -a "${LOG_DIR}/${label}.log"
}

run_case L1W64  1  64  4  4  4
run_case L4W32  4  32  8  8 16
run_case L16W16 16 16 16 16 64

echo "Results: ${RESULT_DIR}"
