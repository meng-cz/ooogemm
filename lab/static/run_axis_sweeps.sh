#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COUNT="${COUNT:-100}"
M_DEFAULT="${M_DEFAULT:-16}"
N_DEFAULT="${N_DEFAULT:-1024}"
K_DEFAULT="${K_DEFAULT:-1024}"

M_VALUES=(${M_VALUES:-1 4 16 32 64 128 256 512})
N_VALUES=(${N_VALUES:-32 64 128 256 512})
K_VALUES=(${K_VALUES:-32 64 128 256 512})
HARDWARE_CONFIGS=(${HARDWARE_CONFIGS:-1:64 4:32 16:16})
LABM_DIR="${ROOT_DIR}/data/static/labM"
LABN_DIR="${ROOT_DIR}/data/static/labN"
LABK_DIR="${ROOT_DIR}/data/static/labK"

run_one() {
  local lane="$1"
  local width="$2"
  local m="$3"
  local n="$4"
  local k="$5"
  local out_dir="$6"
  local out_file="${out_dir}/L${lane}_W${width}_${m}X${n}X${k}_Cnt${COUNT}.txt"

  if [[ -f "${out_file}" && "${FORCE:-0}" != "1" ]]; then
    echo "static_lab: skip existing ${out_file}"
    return
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "bash ${SCRIPT_DIR}/static.sh ${lane} ${width} ${m} ${n} ${k} ${COUNT} ${out_dir}"
  else
    bash "${SCRIPT_DIR}/static.sh" "${lane}" "${width}" "${m}" "${n}" "${k}" "${COUNT}" "${out_dir}"
  fi
}

mkdir -p "${LABM_DIR}" "${LABN_DIR}" "${LABK_DIR}"

for hw in "${HARDWARE_CONFIGS[@]}"; do
  lane="${hw%%:*}"
  width="${hw##*:}"

  for m in "${M_VALUES[@]}"; do
    run_one "${lane}" "${width}" "${m}" "${N_DEFAULT}" "${K_DEFAULT}" "${LABM_DIR}"
  done

  for n in "${N_VALUES[@]}"; do
    run_one "${lane}" "${width}" "${M_DEFAULT}" "${n}" "${K_DEFAULT}" "${LABN_DIR}"
  done

  for k in "${K_VALUES[@]}"; do
    run_one "${lane}" "${width}" "${M_DEFAULT}" "${N_DEFAULT}" "${k}" "${LABK_DIR}"
  done
done
