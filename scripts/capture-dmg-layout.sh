#!/usr/bin/env bash
#
# Regenerates packaging/dmg-DS_Store, the frozen Finder layout `build-dmg.sh`
# copies onto every disk image.
#
# Run this only when the window design changes, and only on a Mac with a GUI
# session — it drives Finder through AppleScript, which needs a window server
# and Automation permission for the terminal running it. That requirement is
# exactly why the layout is frozen into a file instead of being produced at
# build time: a CI runner has neither.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Rune"
APP_DIR="build/${APP_NAME}.app"
# The volume is deliberately unversioned: `.DS_Store` records item positions by
# filename, so one capture works for every release.
VOLUME_NAME="${APP_NAME}"
STAGING="build/layout-staging"
IMAGE="build/layout-rw.dmg"

if [ ! -d "${APP_DIR}" ]; then
	echo "==> ${APP_DIR} ausente; construindo primeiro"
	./scripts/build-app.sh release
fi

rm -rf "${STAGING}" "${IMAGE}"
mkdir -p "${STAGING}" packaging
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

hdiutil create -srcfolder "${STAGING}" -volname "${VOLUME_NAME}" \
	-fs HFS+ -format UDRW -size 200m -ov "${IMAGE}" >/dev/null
hdiutil attach "${IMAGE}" -readwrite -noverify -noautoopen >/dev/null
trap 'hdiutil detach "/Volumes/${VOLUME_NAME}" -force >/dev/null 2>&1 || true' EXIT

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
	tell disk "${VOLUME_NAME}"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {300, 200, 900, 620}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 96
		set text size of viewOptions to 12
		set label position of viewOptions to bottom
		set position of item "${APP_NAME}.app" of container window to {150, 170}
		set position of item "Applications" of container window to {450, 170}
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT

sleep 1
if [ ! -f "/Volumes/${VOLUME_NAME}/.DS_Store" ]; then
	echo "erro: o Finder não gravou .DS_Store." >&2
	echo "Conceda Automação › Finder ao terminal em Ajustes do Sistema › Privacidade." >&2
	exit 1
fi

cp "/Volumes/${VOLUME_NAME}/.DS_Store" packaging/dmg-DS_Store
hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null
trap - EXIT
rm -f "${IMAGE}"
rm -rf "${STAGING}"

echo "==> packaging/dmg-DS_Store atualizado ($(wc -c < packaging/dmg-DS_Store | tr -d ' ') bytes)"
echo "Commite o arquivo para que as releases usem o novo layout."
