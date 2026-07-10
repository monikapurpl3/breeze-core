# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for the self-contained breeze-core bundle (onedir).
#
# Built inside the packaging/binary/Dockerfile.* containers with the repo
# root as cwd (launcher.py / setup_device.py / meow_ac / static all copied
# there). onedir, not onefile: faster startup, no /tmp extraction, and the
# systemd unit points at a stable path.
#
# The bundled data lands under _internal/ with the same relative layout the
# source tree uses, so the app's own Path(__file__)-based resolution of
# static/ and meow_ac/_commit.txt works unchanged when frozen.

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

hiddenimports = (
    collect_submodules("uvicorn")     # uvicorn loads loops/protocols dynamically
    + collect_submodules("msmart")    # device I/O; keep every protocol module
    + ["brotli_asgi", "brotli", "setup_device",
       "meow_ac.cli.main", "meow_ac.cli.diag", "meow_ac.cli.approve", "meow_ac.cli.client"]
)

datas = (
    [("static", "static"), ("meow_ac/_commit.txt", "meow_ac")]
    + collect_data_files("msmart")
)

a = Analysis(
    ["launcher.py"],
    pathex=["."],
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["tkinter", "test", "unittest", "pydoc_data"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="breeze-core",
    console=True,
    upx=False,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    name="breeze-core",
    upx=False,
)
