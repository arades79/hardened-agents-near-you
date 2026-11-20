#!/usr/bin/env bash
#
# Renders the BYOK ("bring your own key") model configuration for VS Code's
# built-in agent, for the OpenAI-compatible endpoint given by the environment
# (see lib.sh for the contract).
#
# VS Code reads BYOK models from the profile-level chatLanguageModels.json.
# Inside a dev container that file lives in the server's user data folder, next
# to extensions.json and mcp.json:
#
#   ~/.vscode-server/data/User/chatLanguageModels.json
#
# The provider is the "Custom Endpoint" provider (vendor `customendpoint`),
# which upstream supports for self-hosted models and enterprise gateways and
# explicitly documents as usable without a GitHub account and without a Copilot
# plan. Per the configuration reference, model URLs are written as full
# endpoint URLs including the API path.
#
#   VSCODE_USER_DATA_DIR      user data directory (default: ~/.vscode-server/data)
#   OPENAI_MODEL_GROUP        group name in the model picker (default: Agent Endpoint)
#   OPENAI_MODEL_TOOL_CALLING whether the model supports tools (default: true)
#   OPENAI_MODEL_VISION       whether the model accepts images (default: false)
#
set -euo pipefail

# shellcheck source=/usr/local/lib/agent-ide/lib.sh
. "${AGENT_IDE_LIB:-/usr/local/lib/agent-ide/lib.sh}"

command -v jq > /dev/null || ai_die "jq is required (it ships with agent-ide-base)"

USER_DATA_DIR="${VSCODE_USER_DATA_DIR:-$HOME/.vscode-server/data}"
MODELS_FILE="$USER_DATA_DIR/User/chatLanguageModels.json"
TOOL_CALLING="${OPENAI_MODEL_TOOL_CALLING:-true}"
VISION="${OPENAI_MODEL_VISION:-false}"

ai_parse_endpoint "$OPENAI_BASE_URL"
model_url="${AI_ENDPOINT_ORIGIN}$(ai_api_path "$OPENAI_API_TYPE")"

ai_bool() {
	case "${1,,}" in
		true | 1 | yes) printf 'true' ;;
		*) printf 'false' ;;
	esac
}

jq -n \
	--arg group "${OPENAI_MODEL_GROUP:-Agent Endpoint}" \
	--arg key "$OPENAI_API_KEY" \
	--arg api_type "$OPENAI_API_TYPE" \
	--arg model "$OPENAI_MODEL" \
	--arg model_name "$OPENAI_MODEL_NAME" \
	--arg url "$model_url" \
	--argjson tool_calling "$(ai_bool "$TOOL_CALLING")" \
	--argjson vision "$(ai_bool "$VISION")" \
	--argjson max_input "${OPENAI_MODEL_MAX_INPUT_TOKENS:-120000}" \
	--argjson max_output "${OPENAI_MODEL_MAX_OUTPUT_TOKENS:-16000}" \
	'[
		{
			name: $group,
			vendor: "customendpoint",
			apiKey: $key,
			apiType: $api_type,
			models: [
				{
					id: $model,
					name: $model_name,
					url: $url,
					apiType: $api_type,
					toolCalling: $tool_calling,
					vision: $vision,
					maxInputTokens: $max_input,
					maxOutputTokens: $max_output
				}
			]
		}
	]' | ai_write 0600 "$MODELS_FILE"

ai_report "VS Code built-in agent" "$MODELS_FILE"
ai_log "  model:    $OPENAI_MODEL_NAME <$model_url>"
ai_log "  picker:   open Chat, then Manage Language Models (or the model picker) and group '${OPENAI_MODEL_GROUP:-Agent Endpoint}'"
[ "${OPENAI_MODEL_TOOL_CALLING:-true}" = "true" ] ||
	ai_warn "OPENAI_MODEL_TOOL_CALLING is not true - agent mode needs a model that supports tool calling"
