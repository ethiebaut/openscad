#!/usr/bin/env python3
"""Copy Qt into an OpenSCAD.app bundle and point the binary at those copies.

Official Qt macOS libraries already use @rpath. The bundle layout is:

  OpenSCAD.app/Contents/MacOS/OpenSCAD
  OpenSCAD.app/Contents/Frameworks/QtCore.framework
  OpenSCAD.app/Contents/PlugIns/platforms/libqcocoa.dylib
  OpenSCAD.app/Contents/Resources/qt.conf
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(cmd):
    return subprocess.check_output(cmd, text=True, errors="replace")


def is_macho(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        desc = run(["file", "-b", os.path.realpath(path)])
    except (subprocess.CalledProcessError, OSError):
        return False
    return "Mach-O" in desc


def otool_deps(otool: str, path: Path):
    text = run([otool, "-L", str(path)])
    own = ""
    try:
        ident = run([otool, "-D", str(path)]).splitlines()
        if len(ident) >= 2:
            own = ident[1].strip()
    except subprocess.CalledProcessError:
        own = ""
    deps = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.endswith(":"):
            continue
        dep = line.split(" (compatibility", 1)[0].strip()
        if not dep or dep == own:
            continue
        deps.append(dep)
    return deps


def framework_root(path: Path):
    for candidate in (path, *path.parents):
        if candidate.name.endswith(".framework"):
            return candidate
    return None


class Bundler:
    def __init__(self, app: Path, qt_lib: Path, otool: str, install_name_tool: str):
        self.app = app
        self.qt_lib = qt_lib
        self.otool = otool
        self.install_name_tool = install_name_tool
        self.frameworks = app / "Contents" / "Frameworks"
        self.plugins = app / "Contents" / "PlugIns"
        self.copied = set()
        self.queued = set()
        self.queue = []

    def copy_plugins(self):
        src = self.qt_lib.parent / "plugins"
        if not src.is_dir():
            raise SystemExit(f"Qt plugins not found at {src}")
        for group in sorted(p for p in src.iterdir() if p.is_dir()):
            if group.name in {"sqldrivers"} or group.name.endswith(".dSYM"):
                continue
            dest_dir = self.plugins / group.name
            dest_dir.mkdir(parents=True, exist_ok=True)
            for item in group.iterdir():
                if item.name.endswith(".dSYM") or "ffmpeg" in item.name.lower():
                    continue
                if not item.is_file():
                    continue
                dest = dest_dir / item.name
                shutil.copy2(item, dest, follow_symlinks=True)
                self.schedule(dest)

    def schedule(self, binary: Path):
        real = Path(os.path.realpath(binary))
        key = str(real)
        if key in self.queued or not is_macho(real):
            return
        self.queued.add(key)
        self.queue.append(real)

    def take_framework(self, root: Path):
        dest = self.frameworks / root.name
        key = str(dest)
        if key in self.copied:
            return
        self.copied.add(key)
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(root, dest, symlinks=True)
        binary_name = root.name[: -len(".framework")]
        binary = dest / "Versions" / "A" / binary_name
        if not binary.exists():
            current = dest / "Versions" / "Current" / binary_name
            binary = current if current.exists() else dest / binary_name
        self.schedule(binary)

    def take_dylib(self, src: Path):
        if not src.exists():
            return
        dest = self.frameworks / src.name
        key = str(dest)
        if key in self.copied:
            return
        self.copied.add(key)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest, follow_symlinks=True)
        self.schedule(dest)

    def absorb(self, dep: str, owner: Path):
        if dep.startswith(SYSTEM_PREFIXES) or dep.startswith("@executable_path/"):
            return
        if dep.startswith("@rpath/"):
            rel = dep[len("@rpath/") :]
            src = self.qt_lib / rel
        elif dep.startswith("@loader_path/"):
            src = owner.parent / dep[len("@loader_path/") :]
            rel = str(src)
        elif dep.startswith("/"):
            src = Path(dep)
            rel = dep
        else:
            return
        if ".framework/" in rel or ".framework/" in str(src):
            root = framework_root(src)
            if root is not None and root.exists():
                self.take_framework(root)
            return
        if rel.endswith(".dylib") or src.suffix == ".dylib":
            self.take_dylib(src if src.exists() else self.qt_lib / Path(rel).name)

    def add_rpath(self, binary: Path, fatal: bool):
        rel = os.path.relpath(self.frameworks, binary.parent)
        wanted = [f"@loader_path/{rel}", "@executable_path/../Frameworks"]
        for candidate in wanted:
            proc = subprocess.run(
                [self.install_name_tool, "-add_rpath", candidate, str(binary)],
                text=True,
                capture_output=True,
            )
            if proc.returncode == 0 or "would duplicate path" in (proc.stderr or ""):
                continue
            if fatal:
                raise SystemExit(
                    f"install_name_tool failed for {binary}:\n{proc.stderr}"
                )

    def write_qt_conf(self):
        resources = self.app / "Contents" / "Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / "qt.conf").write_text(
            "[Paths]\nPlugins = PlugIns\nFrameworks = Frameworks\n"
        )

    def run(self):
        exe = self.app / "Contents" / "MacOS" / "OpenSCAD"
        if not exe.is_file():
            raise SystemExit(f"Bundle executable not found: {exe}")
        self.frameworks.mkdir(parents=True, exist_ok=True)
        self.copy_plugins()
        self.schedule(exe)
        while self.queue:
            binary = self.queue.pop(0)
            for dep in otool_deps(self.otool, binary):
                self.absorb(dep, binary)
        self.add_rpath(exe, fatal=True)
        for binary in list(self.plugins.rglob("*")) + list(self.frameworks.rglob("*")):
            if binary.is_file() and not binary.is_symlink() and is_macho(binary):
                self.add_rpath(binary, fatal=False)
        self.write_qt_conf()
        cocoa = self.plugins / "platforms" / "libqcocoa.dylib"
        core = self.frameworks / "QtCore.framework"
        if not cocoa.is_file() or not core.is_dir():
            raise SystemExit("The app bundle is missing QtCore or the Cocoa platform plugin")
        leftover = [
            dep
            for dep in otool_deps(self.otool, exe)
            if dep.startswith(("/deps/", "/opt/", "/lib/", "/tmp/"))
        ]
        if leftover:
            raise SystemExit(
                "OpenSCAD still links libraries outside the app bundle:\n"
                + "\n".join(leftover)
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--qt-lib", type=Path, required=True)
    parser.add_argument("--otool", required=True)
    parser.add_argument("--install-name-tool", required=True)
    args = parser.parse_args()
    Bundler(args.app, args.qt_lib, args.otool, args.install_name_tool).run()


if __name__ == "__main__":
    main()
