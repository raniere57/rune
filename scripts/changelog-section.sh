#!/usr/bin/env bash
#
# Prints the CHANGELOG body for one version, without its heading.
#
# Shared by `scripts/release.sh` (which uses it to refuse a tag with no entry)
# and the release workflow (which uses it as the GitHub release notes), so the
# published notes can never drift from the changelog.
#
# Usage: scripts/changelog-section.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?uso: changelog-section.sh <versão>}"
VERSION="${VERSION#v}"

awk -v target="[${VERSION}]" '
	# Section starts at "## [x.y.z]" and ends at the next "## " heading.
	/^## / {
		if (found) exit
		# $2 is the bracketed version; a date suffix may follow.
		if ($2 == target) { found = 1; next }
	}
	found { print }
' CHANGELOG.md | sed -e '/./,$!d' | awk 'BEGIN{ n=0 } { lines[n++] = $0 } END { while (n > 0 && lines[n-1] ~ /^[[:space:]]*$/) n--; for (i = 0; i < n; i++) print lines[i] }'
