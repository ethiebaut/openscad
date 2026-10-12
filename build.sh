#!/usr/bin/env bash
# Build OpenSCAD for Mac (Apple Silicon / arm64) and place the binary in output/.
#
# Usage:
#   ./build.sh
#
# Requires Docker. The image cross-compiles from Linux with osxcross and the
# macOS SDK, then copies the Mach-O arm64 executable to output/openscad.
# output/bin/openscad is the same binary next to output/share/openscad, which
# is where the program looks up fonts, libraries, and color schemes.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
mkdir -p output

if docker info >/dev/null 2>&1; then
  docker_cmd=(docker)
elif sudo docker info >/dev/null 2>&1; then
  docker_cmd=(sudo docker)
else
  echo "Docker is required. Start the daemon and rerun ./build.sh." >&2
  exit 1
fi

# Docker Desktop resolves names through the LAN DNS server. That server
# returns a failure for production.cloudfront.docker.com, which is where
# Docker Hub stores image blobs, so a normal `docker build` cannot fetch
# ubuntu:24.04. A BuildKit container pointed at public resolvers can.
builder=openscad-arm64
bk_container=buildx_buildkit_openscad-arm640
bk_image=moby/buildkit:buildx-stable-1

if ! "${docker_cmd[@]}" image inspect "$bk_image" >/dev/null 2>&1; then
  echo "The local image $bk_image is required. Docker cannot pull it while its DNS resolver fails." >&2
  exit 1
fi

if ! "${docker_cmd[@]}" buildx inspect "$builder" >/dev/null 2>&1; then
  "${docker_cmd[@]}" buildx create --name "$builder" --driver docker-container \
    --driver-opt "image=$bk_image" >/dev/null
fi

bk_dns=""
if "${docker_cmd[@]}" container inspect "$bk_container" >/dev/null 2>&1; then
  bk_dns=$("${docker_cmd[@]}" inspect --format '{{join .HostConfig.Dns " "}}' "$bk_container")
fi
if [[ "$bk_dns" != *8.8.8.8* ]]; then
  if "${docker_cmd[@]}" container inspect "$bk_container" >/dev/null 2>&1; then
    "${docker_cmd[@]}" rm -f "$bk_container" >/dev/null
  fi
  "${docker_cmd[@]}" run -d --name "$bk_container" --privileged --init \
    --dns 8.8.8.8 --dns 1.1.1.1 \
    --restart unless-stopped \
    -v "${bk_container}_state:/var/lib/buildkit" \
    "$bk_image" \
    --allow-insecure-entitlement=network.host >/dev/null
fi
"${docker_cmd[@]}" buildx inspect --bootstrap "$builder" >/dev/null

echo "Building the OpenSCAD Apple Silicon image..."
"${docker_cmd[@]}" buildx build \
  --builder "$builder" \
  --progress=plain \
  --load \
  -t openscad-macos-arm64:latest \
  -f Dockerfile \
  .

echo "Copying the binary into output/..."
"${docker_cmd[@]}" run --rm -v "$root/output:/output" openscad-macos-arm64:latest

if ! file output/openscad | grep -E -q 'Mach-O 64-bit (executable arm64|arm64 executable)'; then
  echo "output/openscad is not a Mach-O arm64 executable:" >&2
  file output/openscad >&2 || true
  exit 1
fi

echo
echo "Apple Silicon binary: $root/output/openscad"
echo "With fonts and libraries: $root/output/bin/openscad"
file output/openscad
