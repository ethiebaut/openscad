#!/usr/bin/env bash
# Cross-compile OpenSCAD's C/C++ dependencies as static libraries for arm64 macOS.
set -euo pipefail

# shellcheck disable=SC1091
source /opt/macos-arm64.env

# GLib probes Objective-C on Darwin. Keep this in the [binaries] section.
if ! grep -q '^objc =' /opt/meson-cross.ini; then
  sed -i "/^\[binaries\]/a objc = '${CC}'\nobjcpp = '${CXX}'" /opt/meson-cross.ini
fi
# sys_root makes pkg-config prefix /deps with the macOS SDK path.
sed -i '/^sys_root = /d' /opt/meson-cross.ini

export CFLAGS="-mmacosx-version-min=12.0 -O2 -I/deps/include"
export CXXFLAGS="-mmacosx-version-min=12.0 -O2 -I/deps/include"
export LDFLAGS="-mmacosx-version-min=12.0 -L/deps/lib"
export PKG_CONFIG_PATH="/deps/lib/pkgconfig:/deps/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR=
export CC_FOR_BUILD=gcc
export CXX_FOR_BUILD=g++

workdir=/tmp/deps-src
mkdir -p "$workdir"
cd "$workdir"

jobs() {
  local n mem_kb by_mem
  n=$(nproc)
  mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  by_mem=$((mem_kb / 1800000))
  if ((by_mem < 1)); then by_mem=1; fi
  if ((by_mem > n)); then by_mem=$n; fi
  echo "$by_mem"
}

fetch() {
  local url=$1 out=$2
  echo "Downloading $url"
  curl -fL --retry 5 --retry-all-errors --retry-delay 2 -o "$out" "$url"
}

extract() {
  local archive=$1 dest=$2
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xf "$archive" -C "$dest" --strip-components=1
}

cmake_install() {
  local src=$1
  shift
  cmake -S "$src" -B "$src/build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/opt/macos-arm64.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/deps \
    -DCMAKE_PREFIX_PATH=/deps \
    -DBUILD_SHARED_LIBS=OFF \
    "$@"
  cmake --build "$src/build" -j "$(jobs)"
  cmake --install "$src/build"
  prune_shared
  rm -rf "$src"
}

# Drop shared libraries so later find_library() calls cannot prefer a .dylib.
prune_shared() {
  find /deps/lib /deps/lib64 -maxdepth 2 \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \) -delete 2>/dev/null || true
}

section() {
  prune_shared
  echo
  echo "======== $* ========"
}

section zlib
fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib.tar.gz
extract zlib.tar.gz zlib
cmake_install zlib -DZLIB_BUILD_EXAMPLES=OFF

section openssl
fetch https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz openssl.tar.gz
extract openssl.tar.gz openssl
pushd openssl
./Configure darwin64-arm64-cc no-shared no-tests no-module \
  --prefix=/deps --libdir=lib --openssldir=/deps/ssl \
  -mmacosx-version-min=12.0
make -j "$(jobs)"
make install_sw
popd
rm -rf openssl

section libxml2
fetch https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.8.tar.xz libxml2.tar.xz
extract libxml2.tar.xz libxml2
cmake_install libxml2 \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_ZLIB=ON \
  -DLIBXML2_WITH_ICONV=ON \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_TESTS=OFF

section libzip
fetch https://github.com/nih-at/libzip/releases/download/v1.11.4/libzip-1.11.4.tar.gz libzip.tar.gz
extract libzip.tar.gz libzip
cmake_install libzip \
  -DENABLE_GNUTLS=OFF \
  -DENABLE_MBEDTLS=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_BZIP2=OFF \
  -DENABLE_LZMA=OFF \
  -DENABLE_ZSTD=OFF \
  -DBUILD_TOOLS=OFF \
  -DBUILD_REGRESS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_DOC=OFF

section double-conversion
fetch https://github.com/google/double-conversion/archive/refs/tags/v3.3.1.tar.gz double-conversion.tar.gz
extract double-conversion.tar.gz double-conversion
cmake_install double-conversion -DBUILD_TESTING=OFF

section eigen
fetch https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.bz2 eigen.tar.bz2
extract eigen.tar.bz2 eigen
cmake_install eigen -DBUILD_TESTING=OFF

section gmp
fetch https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz gmp.tar.xz
extract gmp.tar.xz gmp
pushd gmp
if ! ./configure --host="$TRIPLE" --prefix=/deps --disable-shared --enable-static --enable-cxx; then
  echo "GMP configure with assembly failed; retrying without assembly"
  make distclean || true
  ./configure --host="$TRIPLE" --prefix=/deps --disable-shared --enable-static --enable-cxx --disable-assembly
fi
make -j "$(jobs)"
make install
popd
rm -rf gmp

section mpfr
fetch https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz mpfr.tar.xz
extract mpfr.tar.xz mpfr
pushd mpfr
./configure --host="$TRIPLE" --prefix=/deps --disable-shared --enable-static --with-gmp=/deps
make -j "$(jobs)"
make install
popd
rm -rf mpfr

section boost
fetch https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.xz boost.tar.xz
extract boost.tar.xz boost
# CMake, not b2: b2's clang-linux toolset adds -m64, which osxcross reads as x86_64.
# Build the compiled libraries OpenSCAD links, then install every Boost header.
# Limiting BOOST_INCLUDE_LIBRARIES skips headers such as boost/format.hpp.
cmake -S boost -B boost/build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/opt/macos-arm64.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/deps \
  -DCMAKE_PREFIX_PATH=/deps \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DBOOST_INCLUDE_LIBRARIES="regex;program_options;container;serialization"
cmake --build boost/build -j "$(jobs)"
cmake --install boost/build
mkdir -p /deps/include/boost
while IFS= read -r dir; do
  cp -a "$dir/." /deps/include/boost/
done < <(find boost -type d -path '*/include/boost')
prune_shared
rm -rf boost

section expat
fetch https://github.com/libexpat/libexpat/releases/download/R_2_7_1/expat-2.7.1.tar.xz expat.tar.xz
extract expat.tar.xz expat
cmake_install expat \
  -DEXPAT_BUILD_TOOLS=OFF \
  -DEXPAT_BUILD_EXAMPLES=OFF \
  -DEXPAT_BUILD_TESTS=OFF \
  -DEXPAT_SHARED_LIBS=OFF

section freetype
fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz freetype.tar.xz
extract freetype.tar.xz freetype
cmake_install freetype \
  -DFT_DISABLE_HARFBUZZ=ON \
  -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_BZIP2=ON \
  -DFT_DISABLE_BROTLI=ON \
  -DFT_DISABLE_ZLIB=ON

section libffi
fetch https://github.com/libffi/libffi/releases/download/v3.4.8/libffi-3.4.8.tar.gz libffi.tar.gz
extract libffi.tar.gz libffi
pushd libffi
./configure --host="$TRIPLE" --prefix=/deps --disable-shared --enable-static --disable-docs
make -j "$(jobs)"
make install
popd
rm -rf libffi

section pcre2
fetch https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.bz2 pcre2.tar.bz2
extract pcre2.tar.bz2 pcre2
cmake_install pcre2 \
  -DPCRE2_BUILD_PCRE2GREP=OFF \
  -DPCRE2_BUILD_TESTS=OFF \
  -DPCRE2_SUPPORT_JIT=OFF \
  -DPCRE2_STATIC_PIC=ON

section gettext
fetch https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz gettext.tar.xz
extract gettext.tar.xz gettext
pushd gettext
am_cv_func_iconv_works=yes ./configure \
  --host="$TRIPLE" \
  --prefix=/deps \
  --disable-shared \
  --enable-static \
  --with-included-glib \
  --with-included-gettext \
  --with-included-libunistring \
  --disable-java \
  --disable-csharp \
  --disable-curses
make -C gettext-runtime -j "$(jobs)"
make -C gettext-runtime install
popd
rm -rf gettext

section glib
fetch https://download.gnome.org/sources/glib/2.84/glib-2.84.4.tar.xz glib.tar.xz
extract glib.tar.xz glib
pushd glib
meson setup build \
  --cross-file /opt/meson-cross.ini \
  --prefix=/deps \
  --default-library=static \
  --wrap-mode=nofallback \
  -Dtests=false \
  -Dselinux=disabled \
  -Dlibmount=disabled \
  -Dxattr=false \
  -Dnls=disabled \
  -Ddtrace=disabled \
  -Dglib_debug=disabled \
  -Dsysprof=disabled \
  -Dintrospection=disabled \
  -Dman-pages=disabled \
  -Ddocumentation=false \
  -Dlibelf=disabled \
  -Dinstalled_tests=false
meson compile -C build -j "$(jobs)"
meson install -C build
popd
rm -rf glib

section harfbuzz
fetch https://github.com/harfbuzz/harfbuzz/releases/download/11.4.1/harfbuzz-11.4.1.tar.xz harfbuzz.tar.xz
extract harfbuzz.tar.xz harfbuzz
pushd harfbuzz
meson setup build \
  --cross-file /opt/meson-cross.ini \
  --prefix=/deps \
  --default-library=static \
  --wrap-mode=nofallback \
  -Dtests=disabled \
  -Ddocs=disabled \
  -Dintrospection=disabled \
  -Dglib=disabled \
  -Dgobject=disabled \
  -Dcairo=disabled \
  -Dicu=disabled \
  -Dgraphite2=disabled \
  -Dcoretext=disabled \
  -Dfreetype=enabled \
  -Dutilities=disabled
meson compile -C build -j "$(jobs)"
meson install -C build
popd
rm -rf harfbuzz

section fontconfig
fetch https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.16.0.tar.xz fontconfig.tar.xz
extract fontconfig.tar.xz fontconfig
pushd fontconfig
meson setup build \
  --cross-file /opt/meson-cross.ini \
  --prefix=/deps \
  --default-library=static \
  --wrap-mode=nofallback \
  -Dtests=disabled \
  -Ddoc=disabled \
  -Dtools=disabled \
  -Dcache-build=disabled \
  -Dnls=disabled
meson compile -C build -j "$(jobs)"
meson install -C build
popd
rm -rf fontconfig

section cgal
fetch https://github.com/CGAL/cgal/releases/download/v6.2/CGAL-6.2-library.tar.xz cgal.tar.xz
extract cgal.tar.xz cgal
cmake_install cgal \
  -DWITH_CGAL_Qt6=OFF \
  -DWITH_CGAL_ImageIO=OFF \
  -DGMP_INCLUDE_DIR=/deps/include \
  -DGMP_LIBRARIES=/deps/lib/libgmp.a \
  -DGMPXX_INCLUDE_DIR=/deps/include \
  -DGMPXX_LIBRARIES=/deps/lib/libgmpxx.a \
  -DMPFR_INCLUDE_DIR=/deps/include \
  -DMPFR_LIBRARIES=/deps/lib/libmpfr.a

section lib3mf
fetch https://github.com/3MFConsortium/lib3mf/archive/refs/tags/v2.4.1.tar.gz lib3mf.tar.gz
extract lib3mf.tar.gz lib3mf
cmake_install lib3mf \
  -DLIB3MF_TESTS=OFF \
  -DUSE_INCLUDED_ZLIB=OFF \
  -DUSE_INCLUDED_LIBZIP=OFF \
  -DUSE_INCLUDED_SSL=OFF

prune_shared
echo
echo "Dependency prefix /deps is ready"
ls /deps/lib/*.a
rm -rf "$workdir"
