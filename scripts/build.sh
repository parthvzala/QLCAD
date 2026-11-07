#!/usr/bin/env bash
set -euo pipefail

# Workspace root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Building QLCAD: macOS High-Accuracy STEP Quick Look Extension ==="
cd "${ROOT_DIR}"

BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/QLCAD.app"
FRAMEWORKS_DIR="${APP_DIR}/Contents/Frameworks"
PLUGINS_DIR="${APP_DIR}/Contents/PlugIns"
MACOS_DIR="${APP_DIR}/Contents/MacOS"

OCCT_DIR="${ROOT_DIR}/.occt/install"
OCCT_INC="${OCCT_DIR}/include/opencascade"
OCCT_LIB="${OCCT_DIR}/lib"

if [ ! -f "${OCCT_LIB}/libTKernel.a" ]; then
  echo "Error: static OCCT not found. Please run ./scripts/build_occt.sh first."
  exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
mkdir -p "${PLUGINS_DIR}"
mkdir -p "${MACOS_DIR}"

# 1. Compile C++ Core, linked against static OCCT. Exporting only the bridge API lets the linker
# discard the OCCT code it doesn't reach, so this one library is all the app needs to bundle.
echo "--> Compiling libqlcad_core.dylib..."
clang++ -std=c++17 -O3 -shared -fPIC -mmacosx-version-min=12.0 \
  "${ROOT_DIR}/Core/src/qlcad_bridge.cpp" \
  -I"${ROOT_DIR}/Core/include" \
  -I"${OCCT_INC}" \
  -L"${OCCT_LIB}" \
  -lTKDESTEP -lTKDE -lTKXCAF -lTKVCAF -lTKV3d -lTKService -lTKHLR -lTKBO -lTKPrim -lTKLCAF -lTKCAF -lTKCDF -lTKXSBase -lTKMesh -lTKBRep -lTKTopAlgo -lTKGeomBase -lTKGeomAlgo -lTKG3d -lTKG2d -lTKMath -lTKernel -lTKShHealing \
  -Wl,-dead_strip \
  -Wl,-exported_symbol,'_qlcad_*' \
  -install_name "@rpath/libqlcad_core.dylib" \
  -o "${FRAMEWORKS_DIR}/libqlcad_core.dylib"

# 2. Build Swift Host Application
echo "--> Compiling QLCAD Host Application..."
cp "${ROOT_DIR}/App/Info.plist" "${APP_DIR}/Contents/Info.plist"

# The LGPL requires the licence and notices to ship with every copy of the app
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
mkdir -p "${RESOURCES_DIR}"
cp "${ROOT_DIR}/App/Credits.html" "${ROOT_DIR}/LICENSE" "${ROOT_DIR}/THIRD_PARTY_NOTICES.md" "${RESOURCES_DIR}/"
cp -R "${ROOT_DIR}/LICENSES" "${RESOURCES_DIR}/"

swiftc -O \
  -I "${ROOT_DIR}/Core/include" \
  -L "${FRAMEWORKS_DIR}" \
  -lqlcad_core \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  "${ROOT_DIR}/Core/Swift/QLCADSceneBuilder.swift" \
  "${ROOT_DIR}/App/main.swift" \
  -o "${MACOS_DIR}/QLCAD"

# 3. Build Quick Look Preview Extension
echo "--> Compiling QLCADPreview.appex..."
PREVIEW_APPEX="${PLUGINS_DIR}/QLCADPreview.appex"
mkdir -p "${PREVIEW_APPEX}/Contents/MacOS"
mkdir -p "${PREVIEW_APPEX}/Contents"
ln -sf "../../../Frameworks" "${PREVIEW_APPEX}/Contents/Frameworks"
cp "${ROOT_DIR}/Extensions/Preview/Info.plist" "${PREVIEW_APPEX}/Contents/Info.plist"

swiftc -O \
  -I "${ROOT_DIR}/Core/include" \
  -L "${FRAMEWORKS_DIR}" \
  -lqlcad_core \
  -Xlinker -rpath -Xlinker "@loader_path/../../../../Frameworks" \
  -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
  -Xlinker -rpath -Xlinker "@executable_path/../../../../Frameworks" \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  "${ROOT_DIR}/Core/Swift/QLCADSceneBuilder.swift" \
  "${ROOT_DIR}/Extensions/Preview/PreviewViewController.swift" \
  "${ROOT_DIR}/Extensions/Preview/main.swift" \
  -o "${PREVIEW_APPEX}/Contents/MacOS/QLCADPreview"

# 4. Build Quick Look Thumbnail Extension
echo "--> Compiling QLCADThumbnail.appex..."
THUMB_APPEX="${PLUGINS_DIR}/QLCADThumbnail.appex"
mkdir -p "${THUMB_APPEX}/Contents/MacOS"
mkdir -p "${THUMB_APPEX}/Contents"
ln -sf "../../../Frameworks" "${THUMB_APPEX}/Contents/Frameworks"
cp "${ROOT_DIR}/Extensions/Thumbnail/Info.plist" "${THUMB_APPEX}/Contents/Info.plist"

swiftc -O \
  -I "${ROOT_DIR}/Core/include" \
  -L "${FRAMEWORKS_DIR}" \
  -lqlcad_core \
  -Xlinker -rpath -Xlinker "@loader_path/../../../../Frameworks" \
  -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
  -Xlinker -rpath -Xlinker "@executable_path/../../../../Frameworks" \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  "${ROOT_DIR}/Core/Swift/QLCADSceneBuilder.swift" \
  "${ROOT_DIR}/Extensions/Thumbnail/ThumbnailProvider.swift" \
  "${ROOT_DIR}/Extensions/Thumbnail/main.swift" \
  -o "${THUMB_APPEX}/Contents/MacOS/QLCADThumbnail"

# 5. Drop local symbols from the bundled library. Signing below restores their signatures.
echo "--> Stripping bundled library..."
for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
  [ -L "$dylib" ] && continue
  strip -x "$dylib" 2>/dev/null
done

# 6. Apply proper inside-out ad-hoc codesign with sandbox entitlements
echo "--> Applying inside-out codesign with sandbox entitlements..."
for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
  [ -L "$dylib" ] && continue
  codesign --force --sign - "$dylib" 2>/dev/null || true
done

codesign --force --sign - \
  --entitlements "${ROOT_DIR}/Extensions/Preview/Preview.entitlements" \
  "${PREVIEW_APPEX}/Contents/MacOS/QLCADPreview"
codesign --force --sign - \
  --entitlements "${ROOT_DIR}/Extensions/Preview/Preview.entitlements" \
  "${PREVIEW_APPEX}"

codesign --force --sign - \
  --entitlements "${ROOT_DIR}/Extensions/Thumbnail/Thumbnail.entitlements" \
  "${THUMB_APPEX}/Contents/MacOS/QLCADThumbnail"
codesign --force --sign - \
  --entitlements "${ROOT_DIR}/Extensions/Thumbnail/Thumbnail.entitlements" \
  "${THUMB_APPEX}"

codesign --force --sign - "${MACOS_DIR}/QLCAD"
codesign --force --sign - "${APP_DIR}"

echo ""
echo "=== BUILD SUCCESSFUL ==="
echo "Application built at: ${APP_DIR}"
du -sh "${APP_DIR}"
