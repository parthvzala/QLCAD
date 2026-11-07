#!/usr/bin/env bash
set -euo pipefail

# Builds the minimal static OCCT that scripts/build.sh links against. Run once; takes a while.
# Graphics libraries stay in because TKXCAF needs them, but with image, font, and OpenGL support
# off. The linker then discards whatever the bridge doesn't reach.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OCCT_VERSION="8_0_1"
WORK_DIR="${ROOT_DIR}/.occt"
SRC_DIR="${WORK_DIR}/src"
OBJ_DIR="${WORK_DIR}/obj"
PREFIX="${WORK_DIR}/install"

CMAKE="$("${HOME}/.local/bin/mise" which cmake)"

if [ ! -f "${SRC_DIR}/CMakeLists.txt" ]; then
  echo "--> Downloading OCCT ${OCCT_VERSION}..."
  mkdir -p "${SRC_DIR}"
  curl -fsSL "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V${OCCT_VERSION}.tar.gz" \
    | tar -xz --strip-components=1 -C "${SRC_DIR}"
fi

# Start clean, keeping only the downloaded source
echo "--> Removing old OCCT build artifacts..."
rm -rf "${OBJ_DIR}" "${PREFIX}"

echo "--> Configuring OCCT..."
"${CMAKE}" -S "${SRC_DIR}" -B "${OBJ_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
  -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
  -DBUILD_LIBRARY_TYPE=Static \
  -DBUILD_MODULE_ApplicationFramework=ON \
  -DBUILD_MODULE_DataExchange=ON \
  -DBUILD_MODULE_Draw=OFF \
  -DBUILD_MODULE_Visualization=ON \
  -DBUILD_DOC_Overview=OFF \
  -DUSE_FREETYPE=OFF -DUSE_FREEIMAGE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF \
  -DUSE_TK=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF \
  -DUSE_XLIB=OFF -DUSE_OPENVR=OFF -DUSE_FFMPEG=OFF

echo "--> Compiling OCCT..."
# Always pass a job count: with Unix Makefiles, a bare --parallel means unlimited jobs, which
# exhausts the per-user process limit. Override with OCCT_JOBS=n.
"${CMAKE}" --build "${OBJ_DIR}" --parallel "${OCCT_JOBS:-8}"
"${CMAKE}" --install "${OBJ_DIR}"

echo "=== OCCT installed to ${PREFIX} ==="
