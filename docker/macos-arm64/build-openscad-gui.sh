#!/usr/bin/env bash
# Configure, build, and bundle the Apple Silicon OpenSCAD Qt application.
set -euo pipefail

# shellcheck disable=SC1091
source /opt/macos-arm64.env

export PKG_CONFIG_PATH="/deps/lib/pkgconfig:/deps/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR=
export MACOSX_DEPLOYMENT_TARGET=12.0

sed -i 's/set(Boost_NO_BOOST_CMAKE ON CACHE BOOL "" FORCE)/set(Boost_NO_BOOST_CMAKE OFF CACHE BOOL "" FORCE)/' /opt/macos-arm64.cmake

jobs() {
  local n mem_kb by_mem
  n=$(nproc)
  mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
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

std_libs="${extra_libs[*]} -liconv -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework Foundation -framework CoreServices"

cmake -S /src/openscad -B /tmp/openscad-gui-build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/opt/macos-arm64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/opt/openscad-gui \
  -DCMAKE_PREFIX_PATH=/deps \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$std_libs" \
  -DCMAKE_INSTALL_RPATH="@executable_path/../Frameworks" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DHEADLESS=OFF \
  -DNULLGL=OFF \
  -DUSE_QT6=ON \
  -DUSE_BUILTIN_OPENCSG=ON \
  -DENABLE_QTDBUS=OFF \
  -DENABLE_GAMEPAD=OFF \
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

cmake --build /tmp/openscad-gui-build -j "$(jobs)"
cmake --install /tmp/openscad-gui-build --prefix /opt/openscad-gui

app=""
if [[ -d /opt/openscad-gui/bin/OpenSCAD.app ]]; then
  app=/opt/openscad-gui/bin/OpenSCAD.app
elif [[ -d /tmp/openscad-gui-build/OpenSCAD.app ]]; then
  app=/tmp/openscad-gui-build/OpenSCAD.app
else
  app=$(find /opt/openscad-gui /tmp/openscad-gui-build -type d -name 'OpenSCAD.app' | head -1)
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "Could not find OpenSCAD.app" >&2
  exit 1
fi

if [[ ! -d "$app/Contents/Resources/color-schemes" ]]; then
  res=/tmp/openscad-gui-build/OpenSCAD.app/Contents/Resources
  if [[ -d "$res/color-schemes" ]]; then
    mkdir -p "$app/Contents/Resources"
    cp -a "$res/." "$app/Contents/Resources/"
  fi
fi

otool="${INSTALL_NAME_TOOL%-install_name_tool}-otool"
python3 /tmp/bundle-mac-app.py "$app" \
  --qt-lib /deps/lib \
  --otool "$otool" \
  --install-name-tool "$INSTALL_NAME_TOOL"

rm -rf /opt/openscad-gui/OpenSCAD.app
mv "$app" /opt/openscad-gui/OpenSCAD.app

binary=/opt/openscad-gui/OpenSCAD.app/Contents/MacOS/OpenSCAD
echo "Built application:"
file "$binary"
if ! file "$binary" | grep -E -q 'Mach-O 64-bit (executable arm64|arm64 executable)'; then
  echo "OpenSCAD.app did not contain a Mach-O arm64 executable" >&2
  exit 1
fi
