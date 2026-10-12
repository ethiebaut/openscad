# Cross-compile OpenSCAD into a macOS Apple Silicon (arm64) binary.
#
# ./build.sh builds the headless target "export" and writes the Mach-O
# executable to output/openscad.
# ./build-gui.sh builds the Qt GUI target "gui-export". That target starts
# from the same "deps" stage as the headless build, so the osxcross toolchain
# and static libraries are shared layers.
# The macOS 15.5 SDK is downloaded during the image build for osxcross. Using it
# is subject to Apple's Xcode license terms.

FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bison \
        build-essential \
        bzip2 \
        ca-certificates \
        clang \
        cmake \
        cpio \
        curl \
        file \
        flex \
        gettext \
        git \
        gperf \
        help2man \
        libssl-dev \
        libtool \
        libxml2-dev \
        lld \
        llvm \
        m4 \
        make \
        ninja-build \
        patch \
        pkg-config \
        python3 \
        python3-packaging \
        python3-pip \
        python3-setuptools \
        texinfo \
        uuid-dev \
        wget \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages 'meson>=1.7.0'

FROM base AS toolchain
COPY docker/macos-arm64/build-osxcross.sh /tmp/build-osxcross.sh
RUN chmod +x /tmp/build-osxcross.sh && /tmp/build-osxcross.sh

FROM toolchain AS deps
COPY docker/macos-arm64/build-deps.sh /tmp/build-deps.sh
RUN chmod +x /tmp/build-deps.sh && /tmp/build-deps.sh

FROM deps AS build
COPY . /src/openscad
COPY docker/macos-arm64/build-openscad.sh /tmp/build-openscad.sh
RUN chmod +x /tmp/build-openscad.sh && /tmp/build-openscad.sh

FROM base AS export
COPY --from=build /opt/openscad-dist /opt/openscad-dist
COPY docker/macos-arm64/export-output.sh /usr/local/bin/export-output.sh
RUN chmod +x /usr/local/bin/export-output.sh
ENTRYPOINT ["/usr/local/bin/export-output.sh"]

# Qt and the GUI application extend the headless dependency stage.
FROM deps AS qt
COPY patches/qscintilla-2.14.1-a11y-textrange-crash.patch /tmp/qscintilla.patch
COPY docker/macos-arm64/build-qt.sh /tmp/build-qt.sh
RUN chmod +x /tmp/build-qt.sh && /tmp/build-qt.sh

FROM qt AS gui-build
COPY . /src/openscad
COPY docker/macos-arm64/build-openscad-gui.sh /tmp/build-openscad-gui.sh
COPY docker/macos-arm64/bundle-mac-app.py /tmp/bundle-mac-app.py
RUN chmod +x /tmp/build-openscad-gui.sh /tmp/bundle-mac-app.py \
    && /tmp/build-openscad-gui.sh

FROM base AS gui-export
COPY --from=gui-build /opt/openscad-gui/OpenSCAD.app /opt/openscad-gui/OpenSCAD.app
COPY docker/macos-arm64/export-gui.sh /usr/local/bin/export-gui.sh
RUN chmod +x /usr/local/bin/export-gui.sh
ENTRYPOINT ["/usr/local/bin/export-gui.sh"]
