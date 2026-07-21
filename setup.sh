#!/usr/bin/env bash
# setup.sh -- One-command installer for DoorDash CLI.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/doordash-oss/doordash-cli/main/setup.sh | bash
#
# What it does:
#   1. Detects your OS and architecture
#   2. Fetches the latest release from GitHub
#   3. Downloads the matching tarball
#   4. Verifies the SHA256 checksum published in the release notes
#   5. Extracts and runs the bundled install.sh
#   6. Cleans up temporary files
set -euo pipefail

REPO="doordash-oss/doordash-cli"
API="https://api.github.com/repos/$REPO/releases/latest"

# -- Detect OS and architecture -----------------------------------------------

detect_platform() {
  local os arch

  case "$(uname -s)" in
    Darwin)  os="darwin"  ;;
    Linux)   os="linux"   ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *)
      echo "Error: unsupported operating system '$(uname -s)'." >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    arm64|aarch64)  arch="arm64"  ;;
    x86_64|amd64)   arch="amd64"  ;;
    *)
      echo "Error: unsupported architecture '$(uname -m)'." >&2
      exit 1
      ;;
  esac

  echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
echo "Detected platform: $PLATFORM"

# -- Preflight ----------------------------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not found." >&2
  exit 1
fi

# -- Fetch latest release metadata --------------------------------------------

echo "Fetching latest release info..."
RELEASE_JSON=$(curl -fsSL "$API")

TAG=$(printf '%s' "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name" *: *"\([^"]*\)".*/\1/')
VERSION="${TAG#v}"

if [ -z "$VERSION" ]; then
  echo "Error: could not determine latest version." >&2
  exit 1
fi

ASSET_NAME="dd-cli-v${VERSION}-${PLATFORM}.tar.gz"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET_NAME"

echo "Latest release: $TAG"

# -- Check that an asset exists for this platform -----------------------------

if ! printf '%s' "$RELEASE_JSON" | grep -q "$ASSET_NAME"; then
  echo "Error: no release asset found for your platform ($PLATFORM)." >&2
  echo "       Available assets can be viewed at:" >&2
  echo "       https://github.com/$REPO/releases/tag/$TAG" >&2
  exit 1
fi

# -- Extract expected checksum from release body ------------------------------

EXPECTED_SHA=$(printf '%s' "$RELEASE_JSON" \
  | grep -i "SHA256" \
  | grep -oE '[0-9a-f]{64}' \
  | head -1)

if [ -z "$EXPECTED_SHA" ]; then
  echo "Warning: could not extract SHA256 checksum from release notes."
  echo "         The download will proceed but cannot be verified."
fi

# -- Download -----------------------------------------------------------------

TMPDIR_SETUP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SETUP"' EXIT

TARBALL="$TMPDIR_SETUP/$ASSET_NAME"

echo "Downloading $ASSET_NAME..."
curl -fSL --progress-bar -o "$TARBALL" "$DOWNLOAD_URL"

# -- Verify checksum ----------------------------------------------------------

if [ -n "${EXPECTED_SHA:-}" ]; then
  if command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA=$(sha256sum "$TARBALL" | awk '{print $1}')
  else
    echo "Warning: neither shasum nor sha256sum found; skipping checksum verification."
    ACTUAL_SHA=""
  fi

  if [ -n "$ACTUAL_SHA" ] && [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "Error: checksum mismatch!" >&2
    echo "  Expected: $EXPECTED_SHA" >&2
    echo "  Got:      $ACTUAL_SHA" >&2
    echo "The downloaded file may be corrupt or tampered with. Aborting." >&2
    exit 1
  fi

  [ -n "$ACTUAL_SHA" ] && echo "Checksum verified."
fi

# -- Extract & install --------------------------------------------------------

echo "Extracting..."
tar -xzf "$TARBALL" -C "$TMPDIR_SETUP"

EXTRACTED="$TMPDIR_SETUP/dd-cli-v${VERSION}-${PLATFORM}"

if [ ! -f "$EXTRACTED/install.sh" ]; then
  echo "Error: install.sh not found in extracted archive." >&2
  exit 1
fi

bash "$EXTRACTED/install.sh" <<< "6"

# -- PATH hint ----------------------------------------------------------------

if ! command -v dd-cli >/dev/null 2>&1; then
  SHELL_NAME=$(basename "$SHELL")
  case "$SHELL_NAME" in
    zsh)  RC_FILE=".zshrc"    ;;
    bash) RC_FILE=".bashrc"   ;;
    *)    RC_FILE=".profile"  ;;
  esac

  echo ""
  echo "Note: ~/.local/bin is not on your PATH."
  echo "Add it by running:"
  echo ""
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/$RC_FILE && source ~/$RC_FILE"
  echo ""
fi

echo ""
echo "Setup complete! Run 'dd-cli login' to sign in, then 'dd-cli --help' to explore."
