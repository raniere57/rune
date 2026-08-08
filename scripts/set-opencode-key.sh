#!/usr/bin/env bash
#
# Stores the OpenCode Zen API key in the login keychain.
#
# The key is read without echoing, passed to `security` via stdin, and never
# written to disk, a dotfile, or the shell history.
set -euo pipefail

SERVICE="dev.raniere.Rune"
ACCOUNT="opencode-api-key"

printf 'Chave do OpenCode Zen (OPENCODE_API_KEY): '
stty -echo
trap 'stty echo; printf "\n"' EXIT INT TERM
IFS= read -r API_KEY
stty echo
trap - EXIT INT TERM
printf '\n'

if [ -z "${API_KEY}" ]; then
	echo "Nenhuma chave informada. Nada foi alterado." >&2
	exit 1
fi

# `-U` updates in place when the item already exists; `-w` reads the secret
# from the argument, so it is passed as a single exec argument rather than
# through a shell pipeline that could be observed.
#
# `-T ""` trusts no application, so every read asks for the login password.
# That is deliberate here, but it is also why `/key` inside the app is the
# better path: an item created by the app itself trusts the app, and macOS stops
# asking. Prefer `/key sk-…` unless you specifically want the prompt.
security add-generic-password \
	-a "${ACCOUNT}" \
	-s "${SERVICE}" \
	-w "${API_KEY}" \
	-T "" \
	-U

unset API_KEY

echo "Chave gravada no Keychain (serviço: ${SERVICE}, conta: ${ACCOUNT})."
echo "Para remover:  security delete-generic-password -a ${ACCOUNT} -s ${SERVICE}"
