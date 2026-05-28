#!/bin/bash
# shellcheck shell=bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: common.sh
# Description: Common
# License: MIT
# ==============================================================================

# Resolve the directory where this library lives
readonly _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper to source a sibling library by name
lib_source() {
    local lib_name="$1"
    local lib_path="${_LIB_DIR}/${lib_name}"
    if [[ -f "$lib_path" ]]; then
        # shellcheck source=/dev/null
        source "$lib_path"
    else
        echo "[ERROR] Missing library: ${lib_path}" >&2
        exit 1
    fi
}
