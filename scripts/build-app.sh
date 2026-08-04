#!/usr/bin/env bash
#
# Builds MenuAgent.app from the SwiftPM executable.
#
# SwiftPM emits a bare binary; this wraps it in the minimal bundle macOS needs
# for a menu bar app (LSUIElement, bundle identifier, icon slot). The app also
# calls `NSApp.setActivationPolicy(.accessory)` at launch, so the raw binary
# behaves identically — the bundle exists so it can be moved to /Applications
# and launched from Finder.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="MenuAgent"
BUNDLE_ID="dev.raniere.MenuAgent"
VERSION="$(cat VERSION)"

echo "==> swift build -c ${CONFIGURATION}"
swift build -c "${CONFIGURATION}"

BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
APP_DIR="build/${APP_NAME}.app"

echo "==> icon"
swift scripts/make-icon.swift "build/${APP_NAME}.icns" >/dev/null

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "build/${APP_NAME}.icns" "${APP_DIR}/Contents/Resources/${APP_NAME}.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleIconFile</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local launch and for the keychain item to keep a
# stable owning identity across rebuilds. Replace with a Developer ID identity
# before distributing.
codesign --force --sign - --timestamp=none "${APP_DIR}" >/dev/null 2>&1 || {
	echo "aviso: codesign ad-hoc falhou; o app ainda executa localmente" >&2
}

echo "==> ${APP_DIR}"
du -sh "${APP_DIR}" | sed 's/^/    /'
echo
echo "Executar:  open ${APP_DIR}"
echo "Instalar:  cp -R ${APP_DIR} /Applications/"
