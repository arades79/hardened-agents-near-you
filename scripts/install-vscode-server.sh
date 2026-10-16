#!/usr/bin/env bash
#
# Build-time installer for the VS Code Server (and optionally the standalone
# VS Code CLI) into an image's dev-container user.
#
# Produces the layout the Dev Containers / Remote development extensions expect
# inside the container:
#
#   ~/.vscode-server/
#   |-- bin/<commit>/          extracted vscode-server tarball
#   |   |-- 0                  "already installed" marker (skips the download)
#   |   |-- bin/code-server    server launcher (node out/server-main.js)
#   |   |-- node, out/, ...    server runtime + built-in extensions
#   |-- extensions/            user extensions (VSIX installs land here)
#   `-- data/Machine/settings.json   image-level settings
#
# And, unless INSTALL_WEB_SERVER=false, the browser UI flavor of the server:
#
#   /opt/vscode-server-web/bin/<commit>/   (regular tarball lacks web assets)
#
# Usage: install-vscode-server.sh <target-user>
#
# Environment (normally set from Docker build args):
#   VSCODE_COMMIT         required; 40-char commit of the release to match
#   VSCODE_ARCH           x64 | arm64                          (default: x64)
#   VSCODE_SERVER_SHA256  expected sha256 of the server tarball; empty skips
#   VSCODE_SERVER_URL     full download URL override (internal mirror)
#   VSCODE_CLI_URL        full download URL override for the CLI tarball
#   INSTALL_VSCODE_CLI    true | false                         (default: true)
#   INSTALL_WEB_SERVER    true | false                         (default: true)
#   VSCODE_WEB_SERVER_SHA256 / VSCODE_WEB_SERVER_URL
#                         same semantics as the server equivalents
#   SERVER_DATA_FOLDER    install root            (default: <home>/.vscode-server)
#
set -euo pipefail

log() { printf '\n\033[1;34m[install-vscode-server]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[install-vscode-server] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

TARGET_USER="${1:-}"
[ -n "$TARGET_USER" ] || die "usage: install-vscode-server.sh <target-user>"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "user not found: $TARGET_USER"

VSCODE_ARCH="${VSCODE_ARCH:-x64}"
case "$VSCODE_ARCH" in
	x64 | arm64) ;;
	*) die "unsupported VSCODE_ARCH '$VSCODE_ARCH' (expected x64 or arm64)" ;;
esac

VSCODE_COMMIT="${VSCODE_COMMIT:-}"
[ -n "$VSCODE_COMMIT" ] \
	|| die "VSCODE_COMMIT is required (the 40-char commit hash of the desktop release to match)"
case "$VSCODE_COMMIT" in
	*[!0-9a-f]*) die "VSCODE_COMMIT must be 40 lowercase hex chars, got '$VSCODE_COMMIT'" ;;
esac
[ "${#VSCODE_COMMIT}" -eq 40 ] \
	|| die "VSCODE_COMMIT must be 40 lowercase hex chars, got '${VSCODE_COMMIT}' (${#VSCODE_COMMIT} chars)"

SERVER_DATA_FOLDER="${SERVER_DATA_FOLDER:-$TARGET_HOME/.vscode-server}"
SERVER_DIR="$SERVER_DATA_FOLDER/bin/$VSCODE_COMMIT"

SERVER_URL="${VSCODE_SERVER_URL:-https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/server-linux-${VSCODE_ARCH}/stable}"
CLI_URL="${VSCODE_CLI_URL:-https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-${VSCODE_ARCH}}"
WEB_SERVER_URL="${VSCODE_WEB_SERVER_URL:-https://update.code.visualstudio.com/commit:${VSCODE_COMMIT}/server-linux-${VSCODE_ARCH}-web/stable}"
WEB_SERVER_DIR="/opt/vscode-server-web/bin/$VSCODE_COMMIT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

download() { # <url> <destination-file>
	local url="$1" dest="$2"
	log "downloading $url"
	curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused -o "$dest" "$url" \
		|| die "download failed: $url"
}

# ---------------------------------------------------------------------------
# VS Code Server
# ---------------------------------------------------------------------------
log "installing VS Code Server $VSCODE_COMMIT ($VSCODE_ARCH) into $SERVER_DIR"

download "$SERVER_URL" "$tmp/vscode-server.tar.gz"

if [ -n "${VSCODE_SERVER_SHA256:-}" ]; then
	log "verifying sha256"
	printf '%s  %s\n' "$VSCODE_SERVER_SHA256" "$tmp/vscode-server.tar.gz" | sha256sum -c - \
		|| die "sha256 mismatch - refusing to install. Update VSCODE_SERVER_SHA256 when changing VSCODE_COMMIT/VSCODE_ARCH."
fi

mkdir -p "$SERVER_DIR"
tar -xzf "$tmp/vscode-server.tar.gz" --strip-components=1 -C "$SERVER_DIR"

[ -x "$SERVER_DIR/node" ] || die "unexpected server layout: $SERVER_DIR/node missing or not executable"
[ -f "$SERVER_DIR/out/server-main.js" ] || die "unexpected server layout: $SERVER_DIR/out/server-main.js missing"

# The remote development tooling treats this marker as "the server is already
# installed" and skips its own download. Without it, attaching to the container
# would try to fetch a matching server from the internet and fail.
touch "$SERVER_DIR/0"

mkdir -p "$SERVER_DATA_FOLDER/extensions" "$SERVER_DATA_FOLDER/data/Machine"

# Machine-scope (not user-scope) settings so they apply no matter which user
# profile opens the container. These keep the sandbox quiet on networks where
# every outbound request is a dead end.
cat > "$SERVER_DATA_FOLDER/data/Machine/settings.json" <<'JSON'
{
  "security.workspace.trust.enabled": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false
}
JSON

# ---------------------------------------------------------------------------
# VS Code Server, web flavor (used by `vscode-web` only)
#
# The regular server tarball does not contain the browser workbench assets, so
# the browser UI needs this second, slightly larger server build. It lives
# outside ~/.vscode-server so the desktop client's probing and management logic
# never sees it; runtime state still goes to ~/.vscode-server, which means
# extensions installed from ./vsix are available in the browser UI too.
# ---------------------------------------------------------------------------
if [ "${INSTALL_WEB_SERVER:-true}" = "true" ]; then
	log "installing VS Code web server into $WEB_SERVER_DIR"
	download "$WEB_SERVER_URL" "$tmp/vscode-web-server.tar.gz"

	if [ -n "${VSCODE_WEB_SERVER_SHA256:-}" ]; then
		log "verifying sha256 (web server)"
		printf '%s  %s\n' "$VSCODE_WEB_SERVER_SHA256" "$tmp/vscode-web-server.tar.gz" | sha256sum -c - \
			|| die "sha256 mismatch (web server) - refusing to install. Update VSCODE_WEB_SERVER_SHA256 when changing VSCODE_COMMIT/VSCODE_ARCH."
	fi

	mkdir -p "$WEB_SERVER_DIR"
	tar -xzf "$tmp/vscode-web-server.tar.gz" --strip-components=1 -C "$WEB_SERVER_DIR"

	[ -x "$WEB_SERVER_DIR/node" ] || die "unexpected web server layout: $WEB_SERVER_DIR/node missing or not executable"
	[ -f "$WEB_SERVER_DIR/out/vs/code/browser/workbench/workbench.html" ] \
		|| die "web server tarball is missing the browser workbench assets"
else
	log "skipping VS Code web server (INSTALL_WEB_SERVER=${INSTALL_WEB_SERVER})"
fi

# ---------------------------------------------------------------------------
# Standalone VS Code CLI (optional)
#
# Used for `code tunnel` / `code serve-web` on connected networks. The
# air-gapped attach flow does not need it.
# ---------------------------------------------------------------------------
if [ "${INSTALL_VSCODE_CLI:-true}" = "true" ]; then
	log "installing standalone VS Code CLI to /usr/local/bin/code"
	download "$CLI_URL" "$tmp/vscode-cli.tar.gz"
	mkdir -p "$tmp/cli"
	tar -xzf "$tmp/vscode-cli.tar.gz" -C "$tmp/cli"
	cli_bin="$(find "$tmp/cli" -maxdepth 3 -type f -name code -print -quit)"
	[ -n "$cli_bin" ] || die "could not find the 'code' binary inside the CLI tarball"
	install -m 0755 "$cli_bin" /usr/local/bin/code
else
	log "skipping standalone VS Code CLI (INSTALL_VSCODE_CLI=${INSTALL_VSCODE_CLI})"
fi

# ---------------------------------------------------------------------------
# Ownership and smoke tests
# ---------------------------------------------------------------------------
log "setting ownership of $SERVER_DATA_FOLDER to $TARGET_USER"
chown -R "$TARGET_USER:$TARGET_USER" "$SERVER_DATA_FOLDER"

log "smoke test: server --version"
su -s /bin/bash -c "\"$SERVER_DIR/bin/code-server\" --version" "$TARGET_USER" \
	|| die "the pre-installed server failed to run (--version)"

if [ -x /usr/local/bin/code ]; then
	log "smoke test: code --version"
	/usr/local/bin/code --version
fi

if [ -d "$WEB_SERVER_DIR" ]; then
	log "smoke test: web server --version"
	su -s /bin/bash -c "\"$WEB_SERVER_DIR/bin/code-server\" --version" "$TARGET_USER" \
		|| die "the pre-installed web server failed to run (--version)"
fi

log "done: server at $SERVER_DIR"
if [ -d "$WEB_SERVER_DIR" ]; then
	log "done: web server at $WEB_SERVER_DIR"
fi
