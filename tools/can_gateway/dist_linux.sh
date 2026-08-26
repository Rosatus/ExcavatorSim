#!/usr/bin/env bash
# Build the Linux gateway distribution (PyInstaller onefile ELF).
#
# Usage (from Windows):  wsl bash -c "cd /mnt/e/projects/ExcavatorSim/tools/can_gateway && ./dist_linux.sh"
# Usage (inside WSL/Linux):
#   cd tools/can_gateway && ./dist_linux.sh
#
# Output: dist/can_gateway_linux/gateway  (ELF executable)
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$script_dir"

PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "error: $PY not found; install python3 >= 3.10" >&2
    exit 1
fi
version=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
echo "using python $version ($($PY --version 2>&1))"

if command -v uv >/dev/null 2>&1; then
    echo "== building with uv =="
    export UV_PROJECT_ENVIRONMENT="$script_dir/.venv-linux"
    uv venv --allow-existing "$UV_PROJECT_ENVIRONMENT"
    uv pip install --python "$UV_PROJECT_ENVIRONMENT/bin/python" pyinstaller
    PYEXE="$UV_PROJECT_ENVIRONMENT/bin/python"
else
    echo "== uv not found, falling back to venv+pip =="
    if [ ! -x "$script_dir/.venv-linux/bin/python" ]; then
        "$PY" -m venv "$script_dir/.venv-linux"
    fi
    "$script_dir/.venv-linux/bin/pip" install --quiet --upgrade pip
    "$script_dir/.venv-linux/bin/pip" install --quiet pyinstaller
    PYEXE="$script_dir/.venv-linux/bin/python"
fi

DIST_DIR="$repo_root/dist/can_gateway_linux"
BUILD_DIR="$script_dir/build-linux"
"$PYEXE" -m PyInstaller \
    --onefile \
    --console \
    --name gateway \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    --specpath "$script_dir" \
    --paths "$script_dir" \
    gateway.py

chmod +x "$DIST_DIR/gateway"
rm -rf "$BUILD_DIR"

file_out=$(file "$DIST_DIR/gateway" 2>/dev/null || true)
echo "built: $DIST_DIR/gateway ($file_out)"
case "$file_out" in
    *ELF*) echo "OK: ELF executable" ;;
    *) echo "warning: output does not look like an ELF binary; verify manually" ;;
esac
