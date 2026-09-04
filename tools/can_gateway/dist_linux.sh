#!/usr/bin/env bash
# Build the Linux gateway distribution (PyInstaller onefile ELF).
#
# Usage (from Windows):  wsl bash -c "cd /mnt/e/projects/ExcavatorSim/tools/can_gateway && ./dist_linux.sh"
# Usage (inside WSL/Linux):
#   cd tools/can_gateway && ./dist_linux.sh
# Optimized wrapper use:
#   ./dist_linux.sh --skip-web-build --dist-dir /path/to/staging \
#       --build-dir "$HOME/.cache/excavatorsim/can-gateway-build" --keep-build-dir
#
# Output: dist/can_gateway_linux/{gateway,can0-setup-helper,install/uninstall scripts}
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
cd "$script_dir"

PY="${PYTHON:-python3}"
DIST_DIR="${CAN_GATEWAY_DIST_DIR:-$repo_root/dist/can_gateway_linux}"
DEFAULT_BUILD_DIR="$script_dir/build-linux"
BUILD_DIR="${CAN_GATEWAY_BUILD_DIR:-$DEFAULT_BUILD_DIR}"
KEEP_BUILD_DIR="${CAN_GATEWAY_KEEP_BUILD_DIR:-0}"
SKIP_WEB_BUILD=0

usage() {
    cat <<'EOF'
Usage: ./dist_linux.sh [options]

Options:
  --skip-web-build       Reuse the validated resources/web production bundle.
  --dist-dir PATH        Write the Linux package to PATH.
  --build-dir PATH       Use PATH for PyInstaller caches (requires --keep-build-dir).
  --keep-build-dir       Preserve the build directory for faster later builds.
  -h, --help             Show this help.
EOF
}

while (($#)); do
    case "$1" in
        --skip-web-build)
            SKIP_WEB_BUILD=1
            shift
            ;;
        --dist-dir|--build-dir)
            if (($# < 2)) || [[ -z "$2" ]]; then
                echo "error: $1 requires a non-empty path" >&2
                exit 2
            fi
            if [[ "$1" == "--dist-dir" ]]; then
                DIST_DIR="$2"
            else
                BUILD_DIR="$2"
            fi
            shift 2
            ;;
        --keep-build-dir)
            KEEP_BUILD_DIR=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

canonical_build_dir=$(realpath -m -- "$BUILD_DIR")
canonical_default_build_dir=$(realpath -m -- "$DEFAULT_BUILD_DIR")
if [[ "$KEEP_BUILD_DIR" != "1" && "$canonical_build_dir" != "$canonical_default_build_dir" ]]; then
    echo "error: a custom --build-dir requires --keep-build-dir; refusing unsafe recursive cleanup: $canonical_build_dir" >&2
    exit 2
fi
BUILD_DIR="$canonical_build_dir"

SPEC_DIR="$BUILD_DIR/specs"
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "error: $PY not found; install python3 >= 3.10" >&2
    exit 1
fi
version=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
echo "using python $version ($($PY --version 2>&1))"

if ((SKIP_WEB_BUILD == 0)); then
    if ! command -v npm >/dev/null 2>&1; then
        echo "error: Node.js/npm is required on the build machine" >&2
        exit 1
    fi
    (
        cd "$script_dir/web"
        npm ci
        npm run build
    )
fi
if [ ! -f "$script_dir/resources/web/index.html" ] || \
   ! compgen -G "$script_dir/resources/web/assets/index-*.js" >/dev/null; then
    echo "error: Gateway Web production bundle is missing" >&2
    exit 1
fi

if command -v uv >/dev/null 2>&1; then
    echo "== building with uv =="
    export UV_PROJECT_ENVIRONMENT="$BUILD_DIR/.venv"
    uv venv --allow-existing "$UV_PROJECT_ENVIRONMENT"
    uv pip install --python "$UV_PROJECT_ENVIRONMENT/bin/python" \
        pyinstaller aiohttp 'cantools>=40,<41' platformdirs
    PYEXE="$UV_PROJECT_ENVIRONMENT/bin/python"
else
    echo "== uv not found, falling back to venv+pip =="
    if [ ! -x "$BUILD_DIR/.venv/bin/python" ]; then
        "$PY" -m venv "$BUILD_DIR/.venv"
    fi
    "$BUILD_DIR/.venv/bin/pip" install --quiet --upgrade pip
    "$BUILD_DIR/.venv/bin/pip" install --quiet \
        pyinstaller aiohttp 'cantools>=40,<41' platformdirs
    PYEXE="$BUILD_DIR/.venv/bin/python"
fi

mkdir -p "$SPEC_DIR"

"$PYEXE" -m PyInstaller \
    --onefile \
    --console \
    --name gateway \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    --specpath "$SPEC_DIR" \
    --paths "$script_dir" \
    --add-data "$script_dir/resources:resources" \
    --collect-all cantools \
    gateway.py

"$PYEXE" -m PyInstaller \
    --onefile \
    --console \
    --name can0-setup-helper \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR/helper" \
    --specpath "$SPEC_DIR" \
    --paths "$script_dir" \
    can0_setup_helper.py

install -m 0755 "$script_dir/install_can0_helper.sh" "$DIST_DIR/install_can0_helper.sh"
install -m 0755 "$script_dir/uninstall_can0_helper.sh" "$DIST_DIR/uninstall_can0_helper.sh"
mkdir -p "$DIST_DIR/dbc"
install -m 0644 "$script_dir"/resources/dbc/*.dbc "$DIST_DIR/dbc/"
chmod +x "$DIST_DIR/gateway" "$DIST_DIR/can0-setup-helper"
if [[ "$KEEP_BUILD_DIR" != "1" ]]; then
    rm -rf "$BUILD_DIR"
fi

for artifact in gateway can0-setup-helper; do
    file_out=$(file "$DIST_DIR/$artifact" 2>/dev/null || true)
    echo "built: $DIST_DIR/$artifact ($file_out)"
    case "$file_out" in
        *ELF*) echo "OK: ELF executable" ;;
        *) echo "warning: $artifact does not look like an ELF binary; verify manually" ;;
    esac
done
