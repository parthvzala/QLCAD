#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${ROOT_DIR}/build"
APP_PATH="${BUILD_DIR}/QLCAD.app"
DMG_PATH="${BUILD_DIR}/QLCAD.dmg"
STAGE_DIR="${BUILD_DIR}/dmg_stage"
OCCT_SOURCE_PATH="${BUILD_DIR}/OCCT-source.tar.gz"

if [ ! -d "${APP_PATH}" ]; then
  echo "Error: ${APP_PATH} does not exist. Please run ./scripts/build.sh first."
  exit 1
fi

if [ ! -f "${ROOT_DIR}/.occt/src/CMakeLists.txt" ]; then
  echo "Error: OCCT source not found. Please run ./scripts/build_occt.sh first."
  exit 1
fi

echo "=== Creating QLCAD.dmg ==="
rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${STAGE_DIR}"

# Copy QLCAD.app
echo "--> Copying QLCAD.app to DMG staging area..."
cp -R "${APP_PATH}" "${STAGE_DIR}/"

# Add Applications symlink for classic Drag-and-Drop installation
ln -s /Applications "${STAGE_DIR}/Applications"

# Add licences
cp "${ROOT_DIR}/LICENSE" "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${STAGE_DIR}/"
cp -R "${ROOT_DIR}/LICENSES" "${STAGE_DIR}/"

# Add instructions
cat << 'EOF' > "${STAGE_DIR}/README.txt"
QLCAD — High-Accuracy macOS STEP 3D CAD Quick Look Extension & Viewer
====================================================================

Quick Look vs. Preview.app:
---------------------------
• QUICK LOOK (Spacebar in Finder):
  Select any .step / .stp file in Finder and tap SPACEBAR.
  An interactive 3D viewer will appear immediately, allowing you to rotate,
  pan, and inspect the CAD model directly inside Finder!

• PREVIEW.APP NOTE:
  Apple's built-in Preview.app is strictly a 2D image and PDF viewer.
  Right-clicking and choosing "Open With -> Preview" does not work for CAD files.
  To open and inspect files in a full window, use QLCAD.app!

Installation:
-------------
1. If you previously installed the old "QuickLookStep" app, remove it first:
   rm -rf /Applications/QuickLookStep.app
   (or: brew uninstall --cask quicklookstep)

2. Drag QLCAD.app into the Applications folder shortcut.

3. Open QLCAD from /Applications once (right-click -> Open if prompted).

4. Enable Quick Look extensions (if not automatically enabled):
   Open System Settings -> General -> Login Items & Extensions
   Click the (i) info button next to "Quick Look"
   Ensure "QLCADPreview" and "QLCADThumbnail" are turned ON.

5. Refresh Quick Look cache (run in Terminal if Finder already had files open):
   qlmanage -r && qlmanage -r cache

Default STEP App:
-----------------
To make QLCAD the default app when double-clicking STEP files:
Right-click any .step / .stp file -> Get Info -> Open with: QLCAD -> Click "Change All...".

Licence:
--------
QLCAD is free software under the MIT License (see LICENSE).

QLCAD uses Open CASCADE Technology 8.0.1, statically linked into the app. Open CASCADE Technology
and its use in QLCAD are covered by the GNU Lesser General Public License version 2.1, with the
Open CASCADE exception (see the LICENSES folder).

See THIRD_PARTY_NOTICES.md for all notices, where to get the source, and how to relink the app
against a modified Open CASCADE Technology.
EOF

# Build compressed UDZO disk image
echo "--> Generating QLCAD.dmg with hdiutil..."
hdiutil create -volname "QLCAD" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGE_DIR}"

# The LGPL requires OCCT's source to be offered from the same place as the DMG
echo "--> Packing OCCT source for the release page..."
tar -czf "${OCCT_SOURCE_PATH}" -C "${ROOT_DIR}/.occt" src

echo ""
echo "=== DMG CREATED SUCCESSFULLY ==="
echo "Attach both files to the GitHub release:"
ls -lh "${DMG_PATH}" "${OCCT_SOURCE_PATH}"
