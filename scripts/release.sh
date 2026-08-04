#!/usr/bin/env bash
#
# Cuts a release: bumps VERSION, tags, and pushes.
#
# The build and the GitHub release itself happen in CI
# (.github/workflows/release.yml) so the published .dmg is always the one built
# from the tagged commit, never a local artefact that happens to be lying in
# build/.
#
# Usage: scripts/release.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?uso: release.sh <versão>   (ex.: 0.2.0)}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	echo "erro: '${VERSION}' não é uma versão semântica válida" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "erro: há alterações não commitadas" >&2
	git status --short >&2
	exit 1
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
	echo "erro: a tag ${TAG} já existe" >&2
	exit 1
fi

# The changelog entry is a precondition, not an afterthought: without it the
# release would ship with empty notes.
NOTES="$(./scripts/changelog-section.sh "${VERSION}")"
if [ -z "${NOTES}" ]; then
	echo "erro: CHANGELOG.md não tem a seção '## [${VERSION}]'" >&2
	echo "Adicione a seção antes de marcar a release." >&2
	exit 1
fi

echo "==> testes"
swift test >/dev/null

echo "${VERSION}" > VERSION
git add VERSION CHANGELOG.md
git commit -m "chore: release ${TAG}"
git tag -a "${TAG}" -m "${TAG}"

echo "==> enviando"
git push origin HEAD
git push origin "${TAG}"

echo
echo "Tag ${TAG} enviada. O workflow de release constrói o .dmg e publica."
echo "Acompanhe:  gh run watch"
