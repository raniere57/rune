#!/usr/bin/env bash
#
# Packages MenuAgent.app into a distributable .dmg.
#
# Uses only `hdiutil`, `osascript`, and `SetFile` — all part of macOS — so there
# is no create-dmg or appdmg dependency to install or keep current.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MenuAgent"
VERSION="${MENUAGENT_VERSION:-$(cat VERSION)}"
VOLUME_NAME="${APP_NAME} ${VERSION}"
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
STAGING="build/dmg-staging"

if [ ! -d "${APP_DIR}" ]; then
	echo "==> ${APP_DIR} ausente; construindo primeiro"
	./scripts/build-app.sh release
fi

echo "==> preparando conteúdo"
rm -rf "${STAGING}" "${DMG_PATH}" "build/${APP_NAME}-rw.dmg"
mkdir -p "${STAGING}"
cp -R "${APP_DIR}" "${STAGING}/"
# The /Applications alias is what makes the window a drag-to-install target.
ln -s /Applications "${STAGING}/Applications"

# A read/write image is needed first: Finder cannot set window geometry or an
# icon layout on a compressed, read-only image.
echo "==> criando imagem temporária"
hdiutil create \
	-srcfolder "${STAGING}" \
	-volname "${VOLUME_NAME}" \
	-fs HFS+ \
	-format UDRW \
	-ov \
	"build/${APP_NAME}-rw.dmg" >/dev/null

echo "==> montando"
MOUNT_OUTPUT="$(hdiutil attach "build/${APP_NAME}-rw.dmg" -readwrite -noverify -noautoopen)"
DEVICE="$(echo "${MOUNT_OUTPUT}" | grep -Eo '^/dev/disk[0-9]+' | head -1)"
MOUNT_POINT="/Volumes/${VOLUME_NAME}"
# Any early failure must still detach the image, or the device leaks.
trap 'hdiutil detach "${DEVICE}" -force >/dev/null 2>&1 || true' EXIT

# The volume icon comes from the app's own icns, so the mounted disk carries
# the product's identity instead of a generic drive.
if [ -f "build/${APP_NAME}.icns" ]; then
	cp "build/${APP_NAME}.icns" "${MOUNT_POINT}/.VolumeIcon.icns"
	SetFile -a C "${MOUNT_POINT}" 2>/dev/null || true
fi

echo "==> ajustando janela"
osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "aviso: layout do Finder não aplicado (sem sessão gráfica?)"
tell application "Finder"
	tell disk "${VOLUME_NAME}"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 160, 800, 560}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 128
		set position of item "${APP_NAME}.app" of container window to {150, 190}
		set position of item "Applications" of container window to {450, 190}
		close
		open
		update without registering applications
		delay 1
	end tell
end tell
APPLESCRIPT

sync
hdiutil detach "${DEVICE}" >/dev/null
trap - EXIT

echo "==> comprimindo"
hdiutil convert "build/${APP_NAME}-rw.dmg" \
	-format UDZO \
	-imagekey zlib-level=9 \
	-o "${DMG_PATH}" >/dev/null

rm -f "build/${APP_NAME}-rw.dmg"
rm -rf "${STAGING}"

echo "==> ${DMG_PATH}"
du -h "${DMG_PATH}" | sed 's/^/    /'
echo
echo "O app é assinado ad-hoc, então no primeiro uso o Gatekeeper vai bloquear."
echo "Abrir mesmo assim:  Ajustes do Sistema › Privacidade e Segurança › Abrir Assim Mesmo"
echo "Ou pela linha de comando, depois de copiar para /Applications:"
echo "    xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app"
echo
echo "Para distribuir sem esse atrito é preciso Developer ID + notarização."
