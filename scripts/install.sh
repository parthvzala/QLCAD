#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_APP="${ROOT_DIR}/build/QLCAD.app"

if [ ! -d "${BUILD_APP}" ]; then
  echo "Error: ${BUILD_APP} not found. Please run ./scripts/build.sh first."
  exit 1
fi

DEST_DIR="${HOME}/Applications"
mkdir -p "${DEST_DIR}"
DEST_APP="${DEST_DIR}/QLCAD.app"

echo "=== Installing QLCAD to ${DEST_APP} ==="
rm -rf "${DEST_APP}"
cp -R "${BUILD_APP}" "${DEST_APP}"

# Register App Extensions with macOS pluginkit
PREVIEW_APPEX="${DEST_APP}/Contents/PlugIns/QLCADPreview.appex"
THUMB_APPEX="${DEST_APP}/Contents/PlugIns/QLCADThumbnail.appex"

echo "--> Registering Quick Look Preview extension..."
pluginkit -a "${PREVIEW_APPEX}" 2>/dev/null || true
pluginkit -e use -i com.qlcad.viewer.preview 2>/dev/null || true

echo "--> Registering Quick Look Thumbnail extension..."
pluginkit -a "${THUMB_APPEX}" 2>/dev/null || true
pluginkit -e use -i com.qlcad.viewer.thumbnail 2>/dev/null || true

# Reset LaunchServices and Quick Look generator cache
echo "--> Refreshing macOS Quick Look cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DEST_APP}" 2>/dev/null || true
qlmanage -r 2>/dev/null || true
qlmanage -r cache 2>/dev/null || true

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "QLCAD is installed in ${DEST_APP}"
echo "You can now press SPACEBAR on any .step / .stp file in Finder to preview it!"
