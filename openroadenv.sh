#!/usr/bin/env bash
# Load with: source /path/to/ooogemm/openroadenv.sh
# ORFS_ROOT can point to another compatible OpenROAD-flow-scripts checkout.

_ooogemm_openroad_env() {
    local project_root
    project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return

    export OOOGEMM_ROOT="$project_root"
    export ORFS_ROOT="${ORFS_ROOT:-/home/null/openroad/OpenROAD-flow-scripts}"
    export OPENROAD_EXE="${OPENROAD_EXE:-$ORFS_ROOT/tools/OpenROAD/build/bin/openroad}"
    export YOSYS_EXE="${YOSYS_EXE:-$ORFS_ROOT/dependencies/bin/yosys}"
    export KLAYOUT_CMD="${KLAYOUT_CMD:-/usr/bin/klayout}"
    export OPENROAD="$ORFS_ROOT/tools/OpenROAD"
    export FLOW_HOME="$ORFS_ROOT/flow"
    # The local OpenROAD build segfaulted in pin_access with 32 threads.
    # Use a serial default; callers can explicitly override NUM_CORES.
    export NUM_CORES="${NUM_CORES:-1}"

    if [[ ! -x "$OPENROAD_EXE" || ! -x "$YOSYS_EXE" || ! -f "$FLOW_HOME/Makefile" ]]; then
        printf 'OpenROAD/Yosys/ORFS not found; check ORFS_ROOT, OPENROAD_EXE and YOSYS_EXE.\n' >&2
        return 1
    fi

    export PATH="$(dirname -- "$OPENROAD_EXE"):$(dirname -- "$YOSYS_EXE"):$ORFS_ROOT/dependencies/bin:$PATH"
    export LD_LIBRARY_PATH="$ORFS_ROOT/dependencies/lib64:$ORFS_ROOT/dependencies/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

if _ooogemm_openroad_env; then
    unset -f _ooogemm_openroad_env
else
    unset -f _ooogemm_openroad_env
    return 1 2>/dev/null || exit 1
fi
