#!/usr/bin/env bash
#
# Packages Rune.app into a distributable .dmg.
#
# Uses only `hdiutil` and `SetFile` — both part of macOS — so there is no
# create-dmg or appdmg dependency to install or keep current.
#
# The window layout comes from a committed `.DS_Store` (packaging/dmg-DS_Store)
# rather than from AppleScript. Driving Finder needs a window server and
# automation permission, neither of which exists on a CI runner, so the old
# AppleScript path silently produced an unstyled window in every published
# release while looking fine locally. A prebuilt `.DS_Store` gives the same
# layout everywhere. Regenerate it with `scripts/capture-dmg-layout.sh`.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Rune"
VERSION="${RUNE_VERSION:-$(cat VERSION)}"
VOLUME_NAME="${APP_NAME} ${VERSION}"
APP_DIR="build/${APP_NAME}.app"
DMG_PATH="build/${APP_NAME}-${VERSION}.dmg"
STAGING="build/dmg-staging"
LAYOUT="packaging/dmg-DS_Store"

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

if [ -f "${LAYOUT}" ]; then
	cp "${LAYOUT}" "${STAGING}/.DS_Store"
else
	echo "aviso: ${LAYOUT} ausente; a janela vai abrir sem layout" >&2
fi

# No `.VolumeIcon.icns`: a custom volume icon is a file sitting in the window,
# and `.DS_Store` has no position for it, so Finder parks it below the app —
# visible to anyone browsing with hidden files shown. A generic disk icon in the
# sidebar for the few seconds an install takes is the cheaper trade.

# Straight to the final read-only compressed image, with no read/write mount in
# between. Mounting is what creates `.fseventsd`, and the OS recreates it during
# the detach flush faster than it can be deleted — which is how a stray folder
# ended up baked into 0.1.0 and 0.2.0.
echo "==> criando imagem"
hdiutil create \
	-srcfolder "${STAGING}" \
	-volname "${VOLUME_NAME}" \
	-fs HFS+ \
	-format UDZO \
	-imagekey zlib-level=9 \
	-ov \
	"${DMG_PATH}" >/dev/null

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
