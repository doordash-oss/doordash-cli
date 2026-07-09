# DoorDash CLI

DoorDash CLI (`dd-cli`) is a terminal tool for ordering from DoorDash — search restaurants and stores, browse menus, build a cart, reorder a past order, and preview or check out — all from the command line. It's built to be driven directly by a human, or called by AI agents with shell access (Claude Code, Cursor, Codex, etc.) so they can complete ordering tasks on your behalf.

> Waitlist-only. Full functionality requires an approved account.

Currently supported: **macOS, Apple Silicon (M1/M2/M3/M4)**.

## Download

1. Go to the [Releases page](https://github.com/doordash-oss/doordash-cli/releases) and open the latest release.
2. Download the `dd-cli-v<version>-darwin-arm64.tar.gz` asset.
3. Use the SHA256 checksum published on that release to verify the download.
4. Extract the tar.gz and follow the instructions in the `quickstart.txt`.

## Security Notice

This binary is distributed as-is, without warranty of any kind. By downloading and executing it, you acknowledge that you are running third-party software obtained over the internet and assume all associated risks. We strongly recommend verifying the integrity of the downloaded file before use by comparing it against the published checksum associated with the release. Do not proceed if the computed checksum does not match.

To compute the checksum of your download:

```bash
shasum -a 256 dd-cli-v<version>-darwin-arm64.tar.gz
```

## Try it

```bash
dd-cli --help
dd-cli search --query "ramen near me"
dd-cli order history
```
