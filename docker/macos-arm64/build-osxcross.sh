#!/usr/bin/env bash
# Install an Apple Silicon (arm64) osxcross toolchain under /opt/osxcross.
set -euo pipefail

SDK_VERSION=15.5
SDK_SHA256=c15cf0f3f17d714d1aa5a642da8e118db53d79429eb015771ba816aa7c6c1cbd
SDK_URL="https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VERSION}/MacOSX${SDK_VERSION}.sdk.tar.xz"

mkdir -p /opt/src
cd /opt/src
git clone --depth 1 https://github.com/tpoechtrager/osxcross.git
cd osxcross
mkdir -p tarballs
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
  -o "tarballs/MacOSX${SDK_VERSION}.sdk.tar.xz" \
  "$SDK_URL"
echo "${SDK_SHA256}  tarballs/MacOSX${SDK_VERSION}.sdk.tar.xz" | sha256sum -c -

# Apple Silicon only. Deployment target matches scripts/macosx-build-dependencies.sh.
UNATTENDED=1 \
  OSX_VERSION_MIN=12.0 \
  TARGET_DIR=/opt/osxcross \
  ENABLE_ARCHS="arm64" \
  ./build.sh

if [[ -x ./build_compiler_rt.sh ]]; then
  UNATTENDED=1 TARGET_DIR=/opt/osxcross ENABLE_ARCHS="arm64" ./build_compiler_rt.sh \
    || echo "compiler-rt build did not succeed; continuing with the SDK runtime"
fi

cc=$(find /opt/osxcross/bin -name 'aarch64-apple-darwin*-clang' ! -name '*++' | sort | head -1)
if [[ -z "$cc" ]]; then
  echo "osxcross did not produce an aarch64-apple-darwin clang" >&2
  ls -la /opt/osxcross/bin >&2 || true
  exit 1
fi
cxx="${cc}++"
triple=$(basename "$cc" | sed 's/-clang$//')
sdkroot=$(find /opt/osxcross/SDK -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort | head -1)
ar="/opt/osxcross/bin/${triple}-ar"
ranlib="/opt/osxcross/bin/${triple}-ranlib"
strip="/opt/osxcross/bin/${triple}-strip"
install_name_tool="/opt/osxcross/bin/${triple}-install_name_tool"

if [[ ! -d "$sdkroot" ]]; then
  echo "macOS SDK not found under /opt/osxcross/SDK" >&2
  exit 1
fi

mkdir -p /deps/include /deps/lib /deps/lib/pkgconfig

cat > /opt/macos-arm64.env <<EOF
export PATH="/opt/osxcross/bin:\$PATH"
export CC="$cc"
export CXX="$cxx"
export AR="$ar"
export RANLIB="$ranlib"
export STRIP="$strip"
export INSTALL_NAME_TOOL="$install_name_tool"
export SDKROOT="$sdkroot"
export TRIPLE="$triple"
export MACOSX_DEPLOYMENT_TARGET=12.0
EOF

cat > /opt/macos-arm64.cmake <<EOF
# CMake toolchain: macOS Apple Silicon via osxcross.
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "" FORCE)
set(CMAKE_OSX_SYSROOT "$sdkroot" CACHE PATH "" FORCE)

set(CMAKE_C_COMPILER "$cc" CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "$cxx" CACHE FILEPATH "" FORCE)
set(CMAKE_ASM_COMPILER "$cc" CACHE FILEPATH "" FORCE)
set(CMAKE_AR "$ar" CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "$ranlib" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP "$strip" CACHE FILEPATH "" FORCE)
set(CMAKE_INSTALL_NAME_TOOL "$install_name_tool" CACHE FILEPATH "" FORCE)

set(CMAKE_FIND_ROOT_PATH "/deps" "$sdkroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_FRAMEWORK LAST)
set(CMAKE_FRAMEWORK_PATH "$sdkroot/System/Library/Frameworks")

# Link (but do not run) compiler checks. STATIC_LIBRARY checks report
# missing libc functions such as memcpy_s as present.
set(CMAKE_TRY_COMPILE_TARGET_TYPE EXECUTABLE)

set(CMAKE_C_FLAGS_INIT "-mmacosx-version-min=12.0 -I/deps/include")
set(CMAKE_CXX_FLAGS_INIT "-mmacosx-version-min=12.0 -I/deps/include")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-mmacosx-version-min=12.0 -L/deps/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-mmacosx-version-min=12.0 -L/deps/lib")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE OFF)

# Darwin.cmake overwrites CMAKE_FIND_LIBRARY_SUFFIXES after the toolchain file.
# This override is included later and prefers the static libs we install.
set(CMAKE_USER_MAKE_RULES_OVERRIDE /opt/macos-arm64-override.cmake)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(Boost_USE_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(OPENSSL_USE_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(Boost_NO_BOOST_CMAKE OFF CACHE BOOL "" FORCE)
set(PKG_CONFIG_EXECUTABLE "/usr/bin/pkg-config" CACHE FILEPATH "" FORCE)
set(PKG_CONFIG_ARGN "--static" CACHE STRING "" FORCE)

set(ENV{PKG_CONFIG_PATH} "/deps/lib/pkgconfig:/deps/share/pkgconfig")
set(ENV{PKG_CONFIG_LIBDIR} "/deps/lib/pkgconfig:/deps/share/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "")
EOF

cat > /opt/macos-arm64-override.cmake <<'EOF'
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a" ".tbd" ".dylib")
EOF

cat > /opt/meson-cross.ini <<EOF
[binaries]
c = '$cc'
cpp = '$cxx'
ar = '$ar'
strip = '$strip'
pkg-config = 'pkg-config'
pkgconfig = 'pkg-config'
python = 'python3'
gperf = 'gperf'
objc = '$cc'
objcpp = '$cxx'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-mmacosx-version-min=12.0', '-I/deps/include']
cpp_args = ['-mmacosx-version-min=12.0', '-I/deps/include']
c_link_args = ['-mmacosx-version-min=12.0', '-L/deps/lib']
cpp_link_args = ['-mmacosx-version-min=12.0', '-L/deps/lib']
default_library = 'static'
pkg_config_path = ['/deps/lib/pkgconfig', '/deps/share/pkgconfig']
EOF

# shellcheck disable=SC1091
source /opt/macos-arm64.env
echo "osxcross ready: $CC"
"$CC" --version
echo "SDK: $SDKROOT"

rm -rf /opt/src
