#!/usr/bin/env bash
#
# Renders goose's config for the OpenAI-compatible endpoint given by the
# environment (see lib.sh for the contract).
#
# goose reads provider and model from ~/.config/goose/config.yaml - the same
# file the VS Code Goose extension relies on - and expects the endpoint split
# into a host plus a base path ("v1/chat/completions" by default). The API key
# deliberately does *not* go into this file: goose ignores keys there and
# reports "No api key passed in". The key is read from the OPENAI_API_KEY
# environment variable (which is also what the container was started with), or
# from ~/.config/goose/secrets.yaml when the keyring is disabled.
#
#   GOOSE_CONFIG_DIR   config directory (default: ~/.config/goose)
#   OPENAI_BASE_PATH   override the request path (default: derived from
#                      OPENAI_BASE_URL, falling back to v1/chat/completions)
#
set -euo pipefail

# shellcheck source=/usr/local/lib/agent-ide/lib.sh
. "${AGENT_IDE_LIB:-/usr/local/lib/agent-ide/lib.sh}"

CONFIG_DIR="${GOOSE_CONFIG_DIR:-$HOME/.config/goose}"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

ai_parse_endpoint "$OPENAI_BASE_URL"

# OPENAI_HOST is the origin only; everything else is OPENAI_BASE_PATH.
if [ -n "${OPENAI_BASE_PATH:-}" ]; then
	base_path="$OPENAI_BASE_PATH"
else
	base_path="${AI_ENDPOINT_API_ROOT#/}/chat/completions"
	[ "$base_path" = "chat/completions" ] && base_path="v1/chat/completions"
fi

{
	cat <<'YAML'
# Written by agent-ide-configure on container start - manual edits are lost.
# Endpoint and model come from OPENAI_BASE_URL / OPENAI_MODEL; the API key is
# read from the OPENAI_API_KEY environment variable (goose ignores keys in this
# file on purpose).
YAML
	printf 'active_provider: openai\n'
	printf 'providers:\n'
	printf '  openai:\n'
	printf '    enabled: true\n'
	printf '    configured: true\n'
	printf '    model: %s\n' "$(ai_yaml_string "$OPENAI_MODEL")"
	printf 'OPENAI_HOST: %s\n' "$(ai_yaml_string "$AI_ENDPOINT_ORIGIN")"
	printf 'OPENAI_BASE_PATH: %s\n' "$(ai_yaml_string "$base_path")"
} | ai_write 0600 "$CONFIG_FILE"

ai_report "goose" "$CONFIG_FILE"
ai_log "  endpoint: host $AI_ENDPOINT_ORIGIN, base path $base_path"
ai_log "  verify:   goose info -v"
