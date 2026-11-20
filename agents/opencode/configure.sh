#!/usr/bin/env bash
#
# Renders the opencode global config for the OpenAI-compatible endpoint given
# by the environment (see lib.sh for the contract).
#
# The provider is declared as an OpenAI-compatible custom provider - the same
# pattern as the "local models" examples in the opencode docs - and the file is
# rewritten from scratch on every container start, so changing the environment
# is enough to re-point opencode. Keys are written literally rather than as
# {env:...} placeholders because the VS Code extension launches opencode from a
# terminal whose environment is not guaranteed to match the container's.
#
#   OPENCODE_PROVIDER_ID   provider id (default: agent-endpoint)
#   OPENCODE_CONFIG        target file (default: $XDG_CONFIG_HOME/opencode/opencode.json)
#
set -euo pipefail

# shellcheck source=/usr/local/lib/agent-ide/lib.sh
. "${AGENT_IDE_LIB:-/usr/local/lib/agent-ide/lib.sh}"

command -v jq > /dev/null || ai_die "jq is required (it ships with agent-ide-base)"

PROVIDER_ID="${OPENCODE_PROVIDER_ID:-agent-endpoint}"
CONFIG_FILE="${OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}"

ai_parse_endpoint "$OPENAI_BASE_URL"

jq -n \
	--arg provider "$PROVIDER_ID" \
	--arg group "${OPENAI_MODEL_GROUP:-Agent Endpoint}" \
	--arg base "$OPENAI_BASE_URL" \
	--arg key "$OPENAI_API_KEY" \
	--arg model "$OPENAI_MODEL" \
	--arg model_name "$OPENAI_MODEL_NAME" \
	'{
		"$schema": "https://opencode.ai/config.json",
		autoupdate: false,
		model: ($provider + "/" + $model),
		provider: {
			($provider): {
				npm: "@ai-sdk/openai-compatible",
				name: $group,
				options: {
					baseURL: $base,
					apiKey: $key
				},
				models: {
					($model): { name: $model_name }
				}
			}
		}
	}' | ai_write 0600 "$CONFIG_FILE"

ai_report "opencode" "$CONFIG_FILE"
ai_log "  providers: opencode reads \`provider\` from this file; /models lists '$PROVIDER_ID/$OPENAI_MODEL'"
