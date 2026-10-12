#!/usr/bin/env bash
# Build the OpenSCAD Qt application for Mac (Apple Silicon / arm64).
#
# Usage:
#   ./build-gui.sh
#
# Requires Docker. This uses the same image stages as ./build.sh through the
# osxcross toolchain and static libraries, then adds Qt and links the GUI.
# The headless binary in output/ is left in place.
# The application is written to output/OpenSCAD.app.

set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
mkdir -p output

if docker info >/dev/null 2>&1; then
  docker_cmd=(docker)
elif sudo docker info >/dev/null 2>&1; then
  docker_cmd=(sudo docker)
else
  echo "Docker is required. Start the daemon and rerun ./build-gui.sh." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$root/docker/macos-arm64/ensure-builder.sh"
ensure_buildx_builder

echo "Building the OpenSCAD Apple Silicon Qt application..."
"${docker_cmd[@]}" buildx build \
  --builder "$openscad_builder" \
  --target gui-export \
  --progress=plain \
  --load \
  -t openscad-macos-arm64-gui:latest \
  -f Dockerfile \
  .

echo "Copying OpenSCAD.app into output/..."
"${docker_cmd[@]}" run --rm -v "$root/output:/output" openscad-macos-arm64-gui:latest

binary=output/OpenSCAD.app/Contents/MacOS/OpenSCAD
if ! file "$binary" | grep -E -q 'Mach-O 64-bit (executable arm64|arm64 executable)'; then
  echo "$binary is not a Mach-O arm64 executable:" >&2
  file "$binary" >&2 || true
  exit 1
fi

echo
echo "Apple Silicon application: $root/output/OpenSCAD.app"
file "$binary"
