#!/usr/bin/env bash
# Remove only the ExcavatorSim helper authorization; leave can0 and drivers intact.
set -euo pipefail

helper_target="/usr/local/libexec/excavatorsim/can0-setup-helper"
helper_dir="/usr/local/libexec/excavatorsim"
sudoers_target="/etc/sudoers.d/excavatorsim-can0"

if [[ $EUID -ne 0 ]]; then
    echo "error: run this uninstaller with sudo" >&2
    exit 1
fi

rm -f -- "$sudoers_target" "$helper_target"
rmdir --ignore-fail-on-non-empty "$helper_dir" 2>/dev/null || true
echo "removed ExcavatorSim can0 helper authorization; can0 and its driver were not changed"
