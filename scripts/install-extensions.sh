#!/usr/bin/env bash
#
# Build-time installer for .vsix extensions into a pre-installed VS Code Server.
#
# Uses the server's own extension management CLI, which installs directly from
# a local file and never contacts the marketplace - the only viable path when
# the image must work on air-gapped networks.
#
# Usage: install-extensions.sh <target-user> <vsix-dir>
#
set -euo pipefail

log() { printf '\n\033[1;34m[install-extensions]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[install-extensions] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

TARGET_USER="${1:-}"
VSIX_DIR="${2:-}"
if [ -z "$TARGET_USER" ] || [ -z "$VSIX_DIR" ]; then
	die "usage: install-extensions.sh <target-user> <vsix-dir>"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "user not found: $TARGET_USER"

SERVER_DATA_FOLDER="${SERVER_DATA_FOLDER:-$TARGET_HOME/.vscode-server}"

shopt -s nullglob
vsix_files=("$VSIX_DIR"/*.vsix)
shopt -u nullglob

if [ "${#vsix_files[@]}" -eq 0 ]; then
	log "no .vsix files found in $VSIX_DIR - nothing to install"
	exit 0
fi

server_bin="$(find "$SERVER_DATA_FOLDER/bin" -mindepth 3 -maxdepth 3 -name code-server -type f -print -quit)"
[ -n "$server_bin" ] || die "no VS Code Server found under $SERVER_DATA_FOLDER/bin - run install-vscode-server.sh first"

log "installing ${#vsix_files[@]} extension(s) into $SERVER_DATA_FOLDER/extensions"

for vsix in "${vsix_files[@]}"; do
	log "  $(basename "$vsix")"
	su -s /bin/bash -c "\"$server_bin\" --extensions-dir \"$SERVER_DATA_FOLDER/extensions\" --install-extension \"$vsix\" --force" "$TARGET_USER" \
		|| die "failed to install $(basename "$vsix")"
done

log "extensions now present in the image:"
su -s /bin/bash -c "\"$server_bin\" --server-data-dir \"$SERVER_DATA_FOLDER\" --list-extensions --show-versions" "$TARGET_USER" || true
