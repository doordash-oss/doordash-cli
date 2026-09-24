# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller recipe for rebuilding the packaged dd_cli bytecode on Linux."""

import os

from PyInstaller.utils.hooks import collect_submodules


app_path = os.environ["DD_CLI_APP_PATH"]
metadata_path = os.environ["DD_CLI_METADATA_PATH"]
metadata_dirname = os.path.basename(metadata_path)
runner_path = os.environ["DD_CLI_RUNNER_PATH"]

a = Analysis(
    [runner_path],
    pathex=[app_path],
    binaries=[],
    datas=[(metadata_path, metadata_dirname)],
    hiddenimports=collect_submodules("keyring.backends"),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)

# Native manylinux wheels intentionally depend on the target system's libgcc.
# PyInstaller otherwise copies the build host's libgcc, silently raising the
# resulting binary's glibc floor to the build host's version.
a.binaries = [entry for entry in a.binaries if entry[0] != "libgcc_s.so.1"]

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="dd-cli",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
)
