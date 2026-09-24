#!/usr/bin/env bash
# Install a rebuilt Linux dd-cli binary to ~/.local/bin/dd-cli.
set -euo pipefail

install_dir="${DD_CLI_INSTALL_DIR:-$HOME/.local/bin}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

mapfile -t candidates < <(find "$script_dir" -maxdepth 1 -type f \
    \( -name 'dd-cli-v*-linux-x86_64' -o -name 'dd-cli-v*-linux-aarch64' \) \
    -print)

if [[ ${#candidates[@]} -ne 1 ]]; then
    echo "Error: expected exactly one Linux dd-cli binary beside install.sh" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64) expected_suffix="linux-x86_64" ;;
    aarch64|arm64) expected_suffix="linux-aarch64" ;;
    *)
        echo "Error: unsupported Linux architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

binary="${candidates[0]}"
if [[ "$binary" != *"-$expected_suffix" ]]; then
    echo "Error: $(basename "$binary") does not match this machine ($expected_suffix)" >&2
    exit 1
fi

mkdir -p "$install_dir"
install -m 0755 "$binary" "$install_dir/dd-cli"

echo "Installed dd-cli to $install_dir/dd-cli"
if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    echo "Add $install_dir to PATH, then open a new shell."
fi
echo "Run: dd-cli --version"
echo "Then: dd-cli login"
