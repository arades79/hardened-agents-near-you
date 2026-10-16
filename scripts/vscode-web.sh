#!/usr/bin/env bash
#
# Serve the browser UI from the pre-installed VS Code web server, fully
# offline. This talks straight to the baked-in web server binary and never
# goes through `code serve-web`, which would try to download server assets on
# first run and fail on an air-gapped network.
#
# Usage:
#   vscode-web                                  http://0.0.0.0:8000/ (no token)
#   VSCODE_WEB_PORT=9000 vscode-web             different port
#   VSCODE_WEB_HOST=127.0.0.1 vscode-web        loopback only
#   VSCODE_WEB_TOKEN=secret vscode-web          require ?tkn=secret to connect
#   vscode-web --help                           server options
#
set -euo pipefail

web_root="${VSCODE_WEB_SERVER_ROOT:-/opt/vscode-server-web}"
host="${VSCODE_WEB_HOST:-0.0.0.0}"
port="${VSCODE_WEB_PORT:-8000}"

server_bin="$(find "$web_root/bin" -mindepth 3 -maxdepth 3 -name code-server -type f 2>/dev/null | sort | tail -n 1)"
if [ -z "$server_bin" ]; then
	echo "vscode-web: no web server found under '$web_root/bin'" >&2
	echo "vscode-web: the browser UI server is baked in at build time - rebuild the" >&2
	echo "vscode-web: image with INSTALL_WEB_SERVER=true (the default) if it is missing" >&2
	exit 1
fi

if [ -n "${VSCODE_WEB_TOKEN:-}" ]; then
	token_args=(--connection-token "$VSCODE_WEB_TOKEN")
else
	# No token: intended for trusted, air-gapped networks only. Anyone who can
	# reach this port gets a shell in the container.
	token_args=(--without-connection-token)
fi

echo "vscode-web: server   $server_bin"
echo "vscode-web: address  http://${host}:${port}/"
exec "$server_bin" --host "$host" --port "$port" "${token_args[@]}" --accept-server-license-terms "$@"
