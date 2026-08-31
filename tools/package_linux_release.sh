#!/usr/bin/env bash
# Create a Linux release archive with explicit portable POSIX permissions.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SOURCE_DIR OUTPUT_TAR_GZ" >&2
    exit 2
fi

source_dir=$(realpath "$1")
output_path=$(realpath -m "$2")
if [ ! -d "$source_dir" ]; then
    echo "error: Linux release directory does not exist: $source_dir" >&2
    exit 1
fi

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
package_dir="$temporary/ExcavatorSim"
mkdir -p "$package_dir" "$(dirname "$output_path")"
cp -a "$source_dir/." "$package_dir/"

find "$package_dir" -type d -exec chmod 0755 {} +
find "$package_dir" -type f -exec chmod 0644 {} +
chmod 0755 \
    "$package_dir/ExcavatorSim.sh" \
    "$package_dir/ExcavatorSim.x86_64" \
    "$package_dir/can_gateway/gateway" \
    "$package_dir/can_gateway/can0-setup-helper" \
    "$package_dir/can_gateway/install_can0_helper.sh" \
    "$package_dir/can_gateway/uninstall_can0_helper.sh"

tar --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$output_path" -C "$temporary" ExcavatorSim
tar -tzf "$output_path" >/dev/null
echo "built: $output_path"
