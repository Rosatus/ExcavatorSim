#!/usr/bin/env bash
# Build the Linux gateway distribution (PyInstaller onefile ELF).
#
# Usage (from Windows):  wsl bash -c "cd /mnt/e/projects/ExcavatorSim/tools/can_gateway && ./dist_linux.sh"
# Usage (inside WSL/Linux):
#   cd tools/can_gateway && ./dist_linux.sh
#
# Output: dist/can_gateway_linux/{gateway,can0-setup-helper,install/uninstall scripts}
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$script_dir"

PY="${PYTHON:-python3}"
DIST_DIR="$repo_root/dist/can_gateway_linux"
BUILD_DIR="$script_dir/build-linux"
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "error: $PY not found; install python3 >= 3.10" >&2
    exit 1
fi
version=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
echo "using python $version ($($PY --version 2>&1))"

if command -v uv >/dev/null 2>&1; then
    echo "== building with uv =="
    export UV_PROJECT_ENVIRONMENT="$BUILD_DIR/.venv"
    uv venv --allow-existing "$UV_PROJECT_ENVIRONMENT"
    uv pip install --python "$UV_PROJECT_ENVIRONMENT/bin/python" pyinstaller
    PYEXE="$UV_PROJECT_ENVIRONMENT/bin/python"
else
    echo "== uv not found, falling back to venv+pip =="
    if [ ! -x "$BUILD_DIR/.venv/bin/python" ]; then
        "$PY" -m venv "$BUILD_DIR/.venv"
    fi
    "$BUILD_DIR/.venv/bin/pip" install --quiet --upgrade pip
    "$BUILD_DIR/.venv/bin/pip" install --quiet pyinstaller
    PYEXE="$BUILD_DIR/.venv/bin/python"
fi

"$PYEXE" -m PyInstaller \
    --onefile \
    --console \
    --name gateway \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    --specpath "$script_dir" \
    --paths "$script_dir" \
    --add-data "$script_dir/resources:resources" \
    gateway.py

"$PYEXE" -m PyInstaller \
    --onefile \
    --console \
    --name can0-setup-helper \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR/helper" \
    --specpath "$script_dir" \
    --paths "$script_dir" \
    can0_setup_helper.py

install -m 0755 "$script_dir/install_can0_helper.sh" "$DIST_DIR/install_can0_helper.sh"
install -m 0755 "$script_dir/uninstall_can0_helper.sh" "$DIST_DIR/uninstall_can0_helper.sh"
chmod +x "$DIST_DIR/gateway" "$DIST_DIR/can0-setup-helper"
rm -rf "$BUILD_DIR"

for artifact in gateway can0-setup-helper; do
    file_out=$(file "$DIST_DIR/$artifact" 2>/dev/null || true)
    echo "built: $DIST_DIR/$artifact ($file_out)"
    case "$file_out" in
        *ELF*) echo "OK: ELF executable" ;;
        *) echo "warning: $artifact does not look like an ELF binary; verify manually" ;;
    esac
done
