#!/usr/bin/env bash
# Copy the staged Apple Silicon build into the mounted /output directory.
set -euo pipefail

if [[ ! -d /output ]]; then
  echo "Mount a host directory at /output (./build.sh does this)." >&2
  exit 1
fi

rm -rf /output/openscad /output/bin /output/share
mkdir -p /output/bin
cp -a /opt/openscad-dist/openscad /output/openscad
cp -a /opt/openscad-dist/bin/openscad /output/bin/openscad
if [[ -d /opt/openscad-dist/share ]]; then
  cp -a /opt/openscad-dist/share /output/share
fi

file /output/openscad
