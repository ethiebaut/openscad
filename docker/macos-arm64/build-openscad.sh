#!/usr/bin/env bash
# Configure, build, and install the Apple Silicon OpenSCAD command-line binary.
set -euo pipefail

# shellcheck disable=SC1091
source /opt/macos-arm64.env

export PKG_CONFIG_PATH="/deps/lib/pkgconfig:/deps/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR=
export MACOSX_DEPLOYMENT_TARGET=12.0

# Boost 1.92 ships a CMake package. Boost.Regex is header-only there, so the
# legacy FindBoost module (which expects libboost_regex.a) must not be used.
sed -i 's/set(Boost_NO_BOOST_CMAKE ON CACHE BOOL "" FORCE)/set(Boost_NO_BOOST_CMAKE OFF CACHE BOOL "" FORCE)/' /opt/macos-arm64.cmake

jobs() {
  local n mem_kb by_mem
  n=$(nproc)
  mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  # CGAL translation units are large; keep a wide margin.
  by_mem=$((mem_kb / 2500000))
  if ((by_mem < 1)); then by_mem=1; fi
  if ((by_mem > n)); then by_mem=$n; fi
  if ((by_mem > 3)); then by_mem=3; fi
  echo "$by_mem"
}

extra_libs=()
for lib in intl expat pcre2-8 ffi z crypto gmp; do
  if [[ -f "/deps/lib/lib${lib}.a" ]]; then
    extra_libs+=("/deps/lib/lib${lib}.a")
  fi
done

# libiconv is a separate macOS dylib. Static libintl/glib/libxml2 reference it.
std_libs="${extra_libs[*]} -liconv -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework Foundation -framework CoreServices"

cmake -S /src/openscad -B /tmp/openscad-build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/opt/macos-arm64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/openscad-dist \
  -DCMAKE_PREFIX_PATH=/deps \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$std_libs" \
  -DHEADLESS=ON \
  -DNULLGL=ON \
  -DAPPLE_UNIX=ON \
  -DENABLE_TESTS=OFF \
  -DUSE_CCACHE=OFF \
  -DEXPERIMENTAL=ON \
  -DMANIFOLD_PAR=OFF \
  -DENABLE_CAIRO=OFF \
  -DENABLE_HIDAPI=OFF \
  -DENABLE_SPNAV=OFF \
  -DENABLE_PYTHON=OFF \
  -DOFFLINE_DOCS=OFF \
  -DCMAKE_REQUIRE_FIND_PACKAGE_Lib3MF=OFF \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DBoost_USE_STATIC_LIBS=ON \
  -DBoost_NO_BOOST_CMAKE=OFF

cmake --build /tmp/openscad-build -j "$(jobs)"
cmake --install /tmp/openscad-build --prefix /opt/openscad-dist

bin=""
if [[ -x /opt/openscad-dist/bin/openscad ]]; then
  bin=/opt/openscad-dist/bin/openscad
elif [[ -x /opt/openscad-dist/bin/OpenSCAD.app/Contents/MacOS/OpenSCAD ]]; then
  bin=/opt/openscad-dist/bin/OpenSCAD.app/Contents/MacOS/OpenSCAD
else
  bin=$(find /tmp/openscad-build -type f -path '*/MacOS/OpenSCAD' | head -1)
fi
if [[ -z "$bin" || ! -f "$bin" ]]; then
  echo "Could not find the linked OpenSCAD executable" >&2
  exit 1
fi
install -m 0755 "$bin" /opt/openscad-dist/openscad
mkdir -p /opt/openscad-dist/bin
install -m 0755 "$bin" /opt/openscad-dist/bin/openscad

if [[ ! -d /opt/openscad-dist/share/openscad/color-schemes ]]; then
  res=""
  if [[ -d /opt/openscad-dist/bin/OpenSCAD.app/Contents/Resources/color-schemes ]]; then
    res=/opt/openscad-dist/bin/OpenSCAD.app/Contents/Resources
  elif [[ -d /tmp/openscad-build/OpenSCAD.app/Contents/Resources/color-schemes ]]; then
    res=/tmp/openscad-build/OpenSCAD.app/Contents/Resources
  fi
  if [[ -n "$res" ]]; then
    mkdir -p /opt/openscad-dist/share/openscad
    cp -a "$res/." /opt/openscad-dist/share/openscad/
  fi
fi

echo "Built binary:"
file /opt/openscad-dist/openscad
if ! file /opt/openscad-dist/openscad | grep -E -q 'Mach-O 64-bit (executable arm64|arm64 executable)'; then
  echo "OpenSCAD did not link as a Mach-O arm64 executable" >&2
  exit 1
fi
