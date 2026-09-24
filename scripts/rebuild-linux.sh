#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
requested_version="${1:-latest}"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Error: this script builds a Linux executable and must run on Linux." >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64) linux_arch="x86_64" ;;
    aarch64|arm64) linux_arch="aarch64" ;;
    *)
        echo "Error: unsupported build architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

for command in curl file objdump sha256sum tar python3; do
    command -v "$command" >/dev/null || {
        echo "Error: required command is missing: $command" >&2
        exit 1
    }
done

mkdir -p "$repo_root/build" "$repo_root/dist"
work_dir="$(mktemp -d "$repo_root/build/rebuild-linux.XXXXXX")"
if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
    trap 'rm -rf "$work_dir"' EXIT
else
    echo "Keeping build workspace: $work_dir"
fi

release_json="$work_dir/releases.json"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api 'repos/doordash-oss/doordash-cli/releases?per_page=100' >"$release_json"
else
    curl --fail --location --retry 3 \
        --header 'Accept: application/vnd.github+json' \
        --header 'User-Agent: doordash-cli-linux-rebuilder' \
        'https://api.github.com/repos/doordash-oss/doordash-cli/releases?per_page=100' \
        --output "$release_json"
fi

mapfile -t release_fields < <(python3 - "$release_json" "$requested_version" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)

requested = sys.argv[2].removeprefix("v")
pattern = re.compile(r"^dd-cli-v(?P<version>[^-]+)-darwin-arm64\.tar\.gz$")
selected = None
for release in releases:
    for asset in release.get("assets", []):
        match = pattern.match(asset.get("name", ""))
        if not match:
            continue
        if requested == "latest" or match.group("version") == requested:
            selected = (release, asset, match.group("version"))
            break
    if selected:
        break

if selected is None:
    raise SystemExit(f"No official darwin-arm64 release asset found for {sys.argv[2]!r}")

release, asset, version = selected
digest = asset.get("digest") or ""
if digest.startswith("sha256:"):
    digest = digest.removeprefix("sha256:")
if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
    body = release.get("body") or ""
    found = re.search(r"SHA256:\s*([0-9a-fA-F]{64})", body, re.IGNORECASE)
    if not found:
        raise SystemExit("The release does not publish a usable SHA256 digest")
    digest = found.group(1)

print(version)
print(asset["name"])
print(asset["browser_download_url"])
print(digest.lower())
PY
)

if [[ ${#release_fields[@]} -ne 4 ]]; then
    echo "Error: could not resolve the requested official release." >&2
    exit 1
fi

version="${release_fields[0]}"
source_asset="${release_fields[1]}"
source_url="${release_fields[2]}"
source_sha256="${release_fields[3]}"
source_archive="$work_dir/$source_asset"

echo "Downloading official dd-cli v$version release..."
curl --fail --location --retry 3 "$source_url" --output "$source_archive"
echo "$source_sha256  $source_archive" | sha256sum --check --status || {
    echo "Error: official release checksum verification failed." >&2
    exit 1
}

mkdir -p "$work_dir/source"
tar -xzf "$source_archive" -C "$work_dir/source"
source_binary="$(find "$work_dir/source" -type f -name "dd-cli-v$version-darwin-arm64" -print -quit)"
[[ -n "$source_binary" ]] || { echo "Error: release binary not found after extraction." >&2; exit 1; }
file "$source_binary" | grep -q 'Mach-O 64-bit arm64' || {
    echo "Error: release input is not the expected macOS ARM64 executable." >&2
    exit 1
}

echo "Extracting architecture-neutral Python package..."
python3 -m venv "$work_dir/bootstrap-venv"
"$work_dir/bootstrap-venv/bin/pip" --quiet --disable-pip-version-check install \
    'uv==0.12.1' 'pyinstxtractor-ng==2026.7.3'
archive_info="$("$work_dir/bootstrap-venv/bin/pyinstxtractor-ng" --info "$source_binary")"
release_python="$(awk '/^\[\+\] Python version: / { print $4; exit }' <<<"$archive_info")"
if [[ ! "$release_python" =~ ^3\.[0-9]+$ ]]; then
    echo "Error: could not determine the release's Python version." >&2
    exit 1
fi
mkdir -p "$work_dir/extracted"
(
    cd "$work_dir/extracted"
    "$work_dir/bootstrap-venv/bin/pyinstxtractor-ng" "$source_binary"
)

extracted_root="$work_dir/extracted/$(basename "$source_binary")_extracted"
app_source="$extracted_root/PYZ.pyz_extracted/dd_cli"
metadata_source="$extracted_root/dd_cli-$version.dist-info"
[[ -f "$app_source/cli.pyc" && -f "$metadata_source/METADATA" ]] || {
    echo "Error: expected dd_cli package or metadata is absent from the release." >&2
    exit 1
}

mkdir -p "$work_dir/app"
cp -R "$app_source" "$work_dir/app/dd_cli"
cp -R "$metadata_source" "$work_dir/app/dd_cli-$version.dist-info"

release_root="$(dirname "$source_binary")"
mapfile -t release_requirements < <(python3 - "$release_root/THIRD_PARTY_NOTICES.txt" <<'PY'
import re
import sys

pattern = re.compile(r"^ (?P<name>[A-Za-z0-9_.-]+)  (?P<version>[^ ]+)$")
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        match = pattern.match(line.rstrip("\n"))
        if match:
            print(f"{match.group('name')}=={match.group('version')}")
PY
)
if [[ ${#release_requirements[@]} -eq 0 ]]; then
    echo "Error: no dependency versions found in THIRD_PARTY_NOTICES.txt." >&2
    exit 1
fi

echo "Building Linux Python $release_python executable..."
export UV_CACHE_DIR="$work_dir/uv-cache"
export UV_PYTHON_INSTALL_DIR="$work_dir/python"
export UV_PYTHON_BIN_DIR="$work_dir/python-bin"
uv_bin="$work_dir/bootstrap-venv/bin/uv"
wheel_platform="${linux_arch}-manylinux_2_17"
"$uv_bin" python install "$release_python"
"$uv_bin" venv --managed-python --python "$release_python" "$work_dir/build-venv"
"$uv_bin" pip install --python "$work_dir/build-venv/bin/python" \
    --python-platform "$wheel_platform" \
    'pyinstaller==6.21.0' \
    'pyinstaller-hooks-contrib==2026.6' \
    "${release_requirements[@]}" \
    'secretstorage==3.5.0' \
    'jeepney==0.9.0' \
    'cryptography==50.0.0' \
    'cffi==2.1.0' \
    'pycparser==3.0'

echo "Testing Linux credential and headless-login adapters..."
PYTHONPATH="$repo_root/linux" "$work_dir/build-venv/bin/python" \
    -m unittest discover -s "$repo_root/tests" -p 'test_*.py'

export DD_CLI_APP_PATH="$work_dir/app"
export DD_CLI_METADATA_PATH="$metadata_source"
export DD_CLI_RUNNER_PATH="$repo_root/linux/runner.py"
"$work_dir/build-venv/bin/pyinstaller" \
    --noconfirm \
    --clean \
    --distpath "$work_dir/pyinstaller-dist" \
    --workpath "$work_dir/pyinstaller-build" \
    "$repo_root/linux/dd-cli.spec"

built_binary="$work_dir/pyinstaller-dist/dd-cli"

echo "Auditing bundled ELF compatibility..."
mkdir -p "$work_dir/artifact-audit"
(
    cd "$work_dir/artifact-audit"
    "$work_dir/bootstrap-venv/bin/pyinstxtractor-ng" "$built_binary" >/dev/null
)
audit_root="$work_dir/artifact-audit/dd-cli_extracted"
if find "$audit_root" -type f -name 'libgcc_s.so*' -print -quit | grep -q .; then
    echo "Error: the build bundled its host libgcc instead of using the target system's." >&2
    exit 1
fi
while IFS= read -r elf_file; do
    required_glibc="$(objdump -T "$elf_file" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu | tail -1 || true)"
    [[ -z "$required_glibc" ]] && continue
    highest="$(printf '%s\n' '2.17' "$required_glibc" | sort -V | tail -1)"
    if [[ "$highest" != "2.17" ]]; then
        echo "Error: $(basename "$elf_file") requires glibc $required_glibc (maximum: 2.17)." >&2
        exit 1
    fi
done < <(find "$audit_root" -type f \( -name '*.so' -o -name '*.so.*' \) -print)

KEYRING_PYTHON="$work_dir/build-venv/bin/python" \
    "$repo_root/scripts/smoke-test-linux.sh" "$built_binary" "$version"

artifact_stem="dd-cli-v$version-linux-$linux_arch"
package_root="$work_dir/package/$artifact_stem"
mkdir -p "$package_root/skills/dd-cli-usage"
install -m 0755 "$built_binary" "$package_root/$artifact_stem"
install -m 0755 "$repo_root/linux/install.sh" "$package_root/install.sh"
install -m 0644 "$repo_root/linux/quickstart.txt" "$package_root/quickstart.txt"
install -m 0644 "$repo_root/linux/LINUX_PORT_NOTES.txt" "$package_root/LINUX_PORT_NOTES.txt"

install -m 0644 "$release_root/LICENSE.txt" "$package_root/LICENSE.txt"
install -m 0644 "$release_root/THIRD_PARTY_NOTICES.txt" "$package_root/THIRD_PARTY_NOTICES.txt"
if [[ -f "$release_root/skills/dd-cli-usage/SKILL.md" ]]; then
    install -m 0644 "$release_root/skills/dd-cli-usage/SKILL.md" \
        "$package_root/skills/dd-cli-usage/SKILL.md"
fi

cat >"$package_root/SOURCE_RELEASE.txt" <<EOF
Official source release: dd-cli v$version
Official asset: $source_asset
Official asset SHA256: $source_sha256
Official asset URL: $source_url
Linux rebuild architecture: $linux_arch
Linux Python runtime: $("$work_dir/build-venv/bin/python" --version 2>&1)
EOF

output_binary="$repo_root/dist/$artifact_stem"
output_archive="$repo_root/dist/$artifact_stem.tar.gz"
install -m 0755 "$built_binary" "$output_binary"
tar --create --gzip --file "$output_archive" --directory "$work_dir/package" "$artifact_stem"
(
    cd "$repo_root/dist"
    sha256sum "$artifact_stem" >"$artifact_stem.sha256"
    sha256sum "$artifact_stem.tar.gz" >"$artifact_stem.tar.gz.sha256"
)

echo
echo "Linux rebuild complete:"
echo "  $output_binary"
echo "  $output_archive"
echo "  $output_archive.sha256"
