# Cross-compile OpenSCAD into a macOS Apple Silicon (arm64) command-line binary.
#
# ./build.sh builds this image and writes the Mach-O executable to output/openscad.
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

FROM ubuntu:24.04 AS export
RUN apt-get update && apt-get install -y --no-install-recommends file \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/openscad-dist /opt/openscad-dist
COPY docker/macos-arm64/export-output.sh /usr/local/bin/export-output.sh
RUN chmod +x /usr/local/bin/export-output.sh
ENTRYPOINT ["/usr/local/bin/export-output.sh"]
