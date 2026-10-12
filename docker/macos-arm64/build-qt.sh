#!/usr/bin/env bash
# Install the macOS Qt 6 SDK used by the GUI build, plus a static QScintilla.
# Qt's own macOS binaries are universal (x86_64 + arm64). Host tools (moc, uic,
# rcc) are the Linux build of the same Qt version, because the macOS ones
# cannot run inside this container.
set -euo pipefail

# shellcheck disable=SC1091
source /opt/macos-arm64.env

QT_VERSION=6.8.3
AQT_VERSION=3.2.1

case "$(uname -m)" in
  x86_64|amd64)
    aqt_host=linux
    aqt_arch=linux_gcc_64
    ;;
  aarch64|arm64)
    aqt_host=linux_arm64
    aqt_arch=linux_gcc_arm64
    ;;
  *)
    echo "No Qt host tools are published for $(uname -m)" >&2
    exit 1
    ;;
esac

echo "Installing Qt ${QT_VERSION} (macOS arm64 libraries, ${aqt_arch} host tools)..."
pip3 install --break-system-packages "aqtinstall==${AQT_VERSION}"

aqt install-qt --timeout 180 -O /tmp/qt-mac \
  mac desktop "$QT_VERSION" clang_64 \
  --archives qtbase qtsvg \
  -m qt5compat qtmultimedia qtimageformats
aqt install-qt --timeout 180 -O /tmp/qt-host \
  "$aqt_host" desktop "$QT_VERSION" "$aqt_arch" \
  --archives qtbase icu

mac_prefix=$(find /tmp/qt-mac -mindepth 2 -maxdepth 2 -type d -name macos | head -1)
host_prefix=$(find /tmp/qt-host -mindepth 2 -maxdepth 2 -type d -name 'gcc_*' | head -1)
if [[ -z "$mac_prefix" || -z "$host_prefix" ]]; then
  echo "aqt did not produce the expected Qt directories" >&2
  find /tmp/qt-mac /tmp/qt-host -maxdepth 3 -type d >&2 || true
  exit 1
fi

rm -rf /opt/qt-host
mv "$host_prefix" /opt/qt-host
rm -rf /tmp/qt-host
# Merge the macOS prefix into /deps. The headless toolchain already searches
# /deps, so the GUI build finds this Qt without a second sysroot.
tar -C "$mac_prefix" --exclude='*.dSYM' -cf - . | tar -C /deps -xf -
rm -rf /tmp/qt-mac

# CMake runs these by absolute path. Point the macOS copies at the Linux tools.
host_tools=(
  libexec/moc
  libexec/rcc
  libexec/uic
  libexec/cmake_automoc_parser
)
for rel in "${host_tools[@]}"; do
  if [[ ! -x "/opt/qt-host/$rel" ]]; then
    echo "Linux Qt is missing $rel" >&2
    exit 1
  fi
  rm -f "/deps/$rel"
  cat > "/deps/$rel" <<EOF
#!/bin/sh
exec "/opt/qt-host/$rel" "\$@"
EOF
  chmod 0755 "/deps/$rel"
done

echo "Building static QScintilla ${QT_VERSION} companion 2.14.1..."
workdir=/tmp/qscintilla-src
rm -rf "$workdir"
mkdir -p "$workdir"
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
  -o "$workdir/qscintilla.tar.gz" \
  https://www.riverbankcomputing.com/static/Downloads/QScintilla/2.14.1/QScintilla_src-2.14.1.tar.gz
tar -xzf "$workdir/qscintilla.tar.gz" -C "$workdir"
src="$workdir/QScintilla_src-2.14.1"
patch -p1 -d "$src" < /tmp/qscintilla.patch

python3 - "$src/src" <<'PY'
import pathlib
import sys
src = pathlib.Path(sys.argv[1])
text = (src / "qscintilla.pro").read_text()

def block(name):
    items = []
    capture = False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not capture:
            if line.startswith(name + " ") or line.startswith(name + "=") or line.startswith(name + "+="):
                capture = True
                line = line.split("=", 1)[1].strip()
            else:
                continue
        if not line:
            continue
        cont = line.endswith("\\")
        line = line.rstrip("\\").strip()
        if line:
            items.extend(line.split())
        if not cont:
            break
    return items

sources = [p for p in block("SOURCES") if p.endswith(".cpp")]
# qsciprinter.cpp is listed behind a qmake scope. The pro file adds it for every
# platform except iOS, which is this build.
printer = "qsciprinter.cpp"
if printer not in sources and (src / printer).is_file():
    sources.append(printer)
headers = [path.relative_to(src).as_posix() for path in src.rglob("*.h")]

def cmake_list(items):
    return "\n".join(f"  {item}" for item in items)

(src / "CMakeLists.txt").write_text(f"""cmake_minimum_required(VERSION 3.16)
project(qscintilla LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets PrintSupport)
add_library(qscintilla2_qt6 STATIC
{cmake_list(sources)}
{cmake_list(headers)}
)
target_include_directories(qscintilla2_qt6
  PUBLIC ${{CMAKE_CURRENT_SOURCE_DIR}}
  PRIVATE
    ${{CMAKE_CURRENT_SOURCE_DIR}}/../scintilla/include
    ${{CMAKE_CURRENT_SOURCE_DIR}}/../scintilla/lexlib
    ${{CMAKE_CURRENT_SOURCE_DIR}}/../scintilla/src
)
target_compile_definitions(qscintilla2_qt6 PUBLIC
  SCINTILLA_QT
  SCI_LEXER
  INCLUDE_DEPRECATED_FEATURES
)
target_link_libraries(qscintilla2_qt6 PUBLIC Qt6::Widgets Qt6::PrintSupport)
install(TARGETS qscintilla2_qt6 ARCHIVE DESTINATION lib)
install(DIRECTORY Qsci DESTINATION include)
""")
PY

jobs() {
  local n mem_kb by_mem
  n=$(nproc)
  mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  by_mem=$((mem_kb / 1800000))
  if ((by_mem < 1)); then by_mem=1; fi
  if ((by_mem > n)); then by_mem=$n; fi
  if ((by_mem > 3)); then by_mem=3; fi
  echo "$by_mem"
}

cmake -S "$src/src" -B "$src/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/opt/macos-arm64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/deps \
  -DCMAKE_PREFIX_PATH=/deps
cmake --build "$src/build" -j "$(jobs)"
cmake --install "$src/build"

if [[ ! -f /deps/lib/libqscintilla2_qt6.a || ! -f /deps/include/Qsci/qsciscintilla.h ]]; then
  echo "QScintilla did not install the static library and headers" >&2
  exit 1
fi

rm -rf "$workdir"

echo "Qt ${QT_VERSION} and QScintilla are installed under /deps"
/deps/libexec/moc -v
