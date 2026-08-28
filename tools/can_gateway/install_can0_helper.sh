#!/usr/bin/env bash
# Install the fixed can0 preparation helper and one exact-command sudo rule.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
helper_source="$script_dir/can0-setup-helper"
helper_dir="/usr/local/libexec/excavatorsim"
helper_target="$helper_dir/can0-setup-helper"
sudoers_target="/etc/sudoers.d/excavatorsim-can0"
runtime_user=${1:-${SUDO_USER:-}}

if [[ $EUID -ne 0 ]]; then
    echo "error: run this installer with sudo and optionally pass the runtime username" >&2
    exit 1
fi
if [[ -z $runtime_user || ! $runtime_user =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
    echo "error: runtime username is required and must be a local Unix account name" >&2
    exit 1
fi
if ! id "$runtime_user" >/dev/null 2>&1; then
    echo "error: runtime user '$runtime_user' does not exist" >&2
    exit 1
fi
if [[ ! -f $helper_source ]]; then
    echo "error: packaged helper missing: $helper_source" >&2
    exit 1
fi
if ! command -v visudo >/dev/null 2>&1; then
    echo "error: visudo is required to validate the scoped authorization" >&2
    exit 1
fi

install -d -o root -g root -m 0755 "$helper_dir"
helper_staged=$(mktemp "$helper_dir/.can0-setup-helper.XXXXXX")
sudoers_staged=$(mktemp /etc/sudoers.d/.excavatorsim-can0.XXXXXX)
cleanup() {
    rm -f -- "$helper_staged" "$sudoers_staged"
}
trap cleanup EXIT

install -o root -g root -m 0755 "$helper_source" "$helper_staged"
printf '%s ALL=(root) NOPASSWD: %s\n' "$runtime_user" "$helper_target" >"$sudoers_staged"
chown root:root "$sudoers_staged"
chmod 0440 "$sudoers_staged"
visudo -cf "$sudoers_staged"

# Both staged files live beside their targets, so rename never exposes a
# partially copied executable or sudoers fragment to a running Gateway.
mv -f -- "$helper_staged" "$helper_target"
mv -f -- "$sudoers_staged" "$sudoers_target"
visudo -cf "$sudoers_target"

echo "installed fixed can0 helper for runtime user: $runtime_user"
echo "Gateway may now run: sudo -n $helper_target"
