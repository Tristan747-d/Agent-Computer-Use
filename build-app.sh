#!/bin/bash
# Build dsh-cua into a signed .app bundle.
#
# Why a .app and a real certificate (not ad-hoc): TCC records the code-signing
# requirement. Ad-hoc binds the CDHash, so every rebuild invalidates the
# Accessibility / Screen Recording grant. An Apple Development certificate
# binds bundle id + cert CN, which survives rebuilds.
#
# Usage: ./build-app.sh [--install]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="dsh-cua"
BUNDLE_ID="com.tristan.dsh.computeruse"
# Assemble OFF iCloud Drive. This project lives under a fileprovider-managed
# path, and iCloud re-applies com.apple.FinderInfo to items it indexes —
# reattaching the "detritus" xattr between `xattr -cr` and `codesign`, which
# makes signing fail every time. /tmp is not fileprovider-managed.
STAGE_DIR="$(mktemp -d /tmp/dsh-cua-build.XXXXXX)"
BUNDLE="${STAGE_DIR}/${APP_NAME}.app"
INSTALL_DIR="${HOME}/Applications"
SIGN_ID="${DSH_CUA_SIGN_ID:-127DF7DB6EF964270A527F4E9B0A2CAD32EBD2A5}"
trap 'rm -rf "${STAGE_DIR}"' EXIT

echo "==> Building release binaries"
cd "${PROJECT_DIR}"
swift build -c release

echo "==> Assembling ${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${PROJECT_DIR}/.build/release/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${BUNDLE}/Contents/MacOS/${APP_NAME}"

# Info.plist MUST be XML (a JSON plist makes codesign report a misleading
# "does not satisfy its Designated Requirement", and the app dies at launch).
cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>DSH Computer Use</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>3.0.0</string>
	<key>CFBundleVersion</key>
	<string>300</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>DSH Computer Use reads and operates app interfaces on your behalf.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>DSH Computer Use captures app windows so the model can see the interface.</string>
	<key>NSAccessibilityUsageDescription</key>
	<string>DSH Computer Use reads and controls app interfaces on your behalf.</string>
</dict>
</plist>
PLIST

echo "==> Validating plist"
plutil -lint "${BUNDLE}/Contents/Info.plist"

# Finder copies xattrs (FinderInfo, resource forks) onto files it has touched.
# codesign refuses to seal a bundle carrying them, and the failure reads
# "resource fork, Finder information, or similar detritus not allowed".
echo "==> Stripping extended attributes"
xattr -cr "${BUNDLE}"

echo "==> Signing with Apple Development identity ${SIGN_ID:0:16}…"
codesign --force --deep --sign "${SIGN_ID}" \
         --options runtime --timestamp=none \
         "${BUNDLE}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"
echo "--- entitlements / identity ---"
codesign -dv --verbose=4 "${BUNDLE}" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature|Authority" | head -5

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to ${INSTALL_DIR}/${APP_NAME}.app"
  mkdir -p "${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
  cp -R "${BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"

  # Exactly ONE copy of this bundle id may exist. LaunchServices and TCC
  # resolve a bundle id to a single registered location; leftover build copies
  # under the project directory make that resolution ambiguous and a Screen
  # Recording grant then silently fails to attach. (The staged copy below is
  # under /tmp and removed by the EXIT trap, so it never competes.)
  echo "==> Removing competing copies of ${BUNDLE_ID}"
  for stray in \
      "${PROJECT_DIR}/build/${APP_NAME}.app" \
      "${HOME}/Desktop/${APP_NAME}.app"; do
    if [[ -e "${stray}" ]]; then
      echo "    removing ${stray}"
      rm -rf "${stray}"
    fi
  done

  echo "==> Re-registering with LaunchServices"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "${INSTALL_DIR}/${APP_NAME}.app" 2>/dev/null || true

  echo "Installed. Verify with:"
  echo "  ${INSTALL_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME} doctor"
fi

echo
echo "Done: ${BUNDLE}"
echo "Run doctor: ${BUNDLE}/Contents/MacOS/${APP_NAME} doctor"
