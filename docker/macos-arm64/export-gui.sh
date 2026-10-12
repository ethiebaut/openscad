#!/usr/bin/env bash
# Copy the staged Apple Silicon application into the mounted /output directory.
set -euo pipefail

if [[ ! -d /output ]]; then
  echo "Mount a host directory at /output (./build-gui.sh does this)." >&2
  exit 1
fi

if [[ ! -d /opt/openscad-gui/OpenSCAD.app ]]; then
  echo "The image does not contain OpenSCAD.app" >&2
  exit 1
fi

rm -rf /output/OpenSCAD.app
cp -a /opt/openscad-gui/OpenSCAD.app /output/OpenSCAD.app
file /output/OpenSCAD.app/Contents/MacOS/OpenSCAD
