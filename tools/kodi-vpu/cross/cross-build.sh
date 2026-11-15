#!/usr/bin/env bash
# Host side: build the image and run build-in-container.sh.
# Usage: cross-build.sh <workdir> [ffmpeg|tools|kodi|debs|all]
# <workdir>/src must hold ffmpeg-9.0.2.tar.xz, 0001-v4l2-request.patch,
# xbmc-22.0rc2-Piers.tar.gz (see ../README.md, section 2).
# Result: <workdir>/out/opt/{kodi-ffmpeg,kodi-22}, <workdir>/out/debs/*.deb
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(realpath "${1:?workdir missing}")"
STEP="${2:-all}"
IMAGE=kodi-cross-arm64:trixie

docker build -t "${IMAGE}" "${HERE}"
mkdir -p "${WORK}/out/opt"
docker run --rm -u "$(id -u):$(id -g)" \
	-v "${WORK}:/work" -v "${WORK}/out/opt:/opt" -v "${HERE}/..:/scripts:ro" \
	"${IMAGE}" bash /scripts/cross/build-in-container.sh "${STEP}"
