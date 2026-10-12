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

echo "Building the OpenSCAD Apple Silicon image..."
# Classic docker build (no buildx) does not accept --progress. Use it when present.
if "${docker_cmd[@]}" build --help 2>/dev/null | grep -q -- '--progress'; then
  build_progress=(--progress=plain)
else
  build_progress=()
fi
DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}" "${docker_cmd[@]}" build \
  "${build_progress[@]}" \
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
