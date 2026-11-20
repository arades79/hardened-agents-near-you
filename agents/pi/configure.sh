#!/usr/bin/env bash
#
# Renders pi's model configuration for the OpenAI-compatible endpoint given by
# the environment (see lib.sh for the contract).
#
# pi reads custom endpoints from `models.json` in its agent directory and the
# startup model from `settings.json` there, so both are (re)written on every
# container start. Values are written literally rather than as ${ENV}
# references: pi resolves those against the environment of the process that
# starts it, which for the VS Code extension's terminal is not necessarily the
# container environment.
#
#   PI_PROVIDER_ID                    provider id (default: agent-endpoint)
#   PI_API                            pi API kind; defaults from OPENAI_API_TYPE
#   OPENAI_MODEL_CONTEXT_WINDOW       context window in tokens (default: 128000)
#   OPENAI_MODEL_MAX_OUTPUT_TOKENS    max output tokens (default: 16384)
#   OPENAI_MODEL_VISION               true to declare image input support
#   PI_CODING_AGENT_DIR               agent directory (default: ~/.pi/agent)
#
set -euo pipefail

# shellcheck source=/usr/local/lib/agent-ide/lib.sh
. "${AGENT_IDE_LIB:-/usr/local/lib/agent-ide/lib.sh}"

command -v jq > /dev/null || ai_die "jq is required (it ships with agent-ide-base)"

PROVIDER_ID="${PI_PROVIDER_ID:-agent-endpoint}"
AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
CONTEXT_WINDOW="${OPENAI_MODEL_CONTEXT_WINDOW:-128000}"
MAX_TOKENS="${OPENAI_MODEL_MAX_OUTPUT_TOKENS:-16384}"
VISION="${OPENAI_MODEL_VISION:-false}"

if [ -z "${PI_API:-}" ]; then
	case "$OPENAI_API_TYPE" in
		chat-completions) PI_API=openai-completions ;;
		responses) PI_API=openai-responses ;;
		messages) PI_API=anthropic-messages ;;
		*) ai_die "unsupported OPENAI_API_TYPE '$OPENAI_API_TYPE'" ;;
	esac
fi

ai_parse_endpoint "$OPENAI_BASE_URL"
base_url="$(ai_api_root_url)"

case "$VISION" in
	true | 1 | yes) input='["text","image"]' ;;
	*) input='["text"]' ;;
esac

jq -n \
	--arg provider "$PROVIDER_ID" \
	--arg group "${OPENAI_MODEL_GROUP:-Agent Endpoint}" \
	--arg base "$base_url" \
	--arg api "$PI_API" \
	--arg key "$OPENAI_API_KEY" \
	--arg model "$OPENAI_MODEL" \
	--arg model_name "$OPENAI_MODEL_NAME" \
	--argjson context "$CONTEXT_WINDOW" \
	--argjson max_tokens "$MAX_TOKENS" \
	--argjson input "$input" \
	'{
		"$schema": "https://pi.dev/schemas/models.schema.json",
		providers: {
			($provider): {
				name: $group,
				baseUrl: $base,
				api: $api,
				apiKey: $key,
				models: [
					{
						id: $model,
						name: $model_name,
						input: $input,
						contextWindow: $context,
						maxTokens: $max_tokens
					}
				]
			}
		}
	}' | ai_write 0600 "$AGENT_DIR/models.json"

# Merge rather than replace: users may have tweaked other settings in here.
settings="$AGENT_DIR/settings.json"
[ -s "$settings" ] || printf '{}\n' > "$settings"
jq --arg provider "$PROVIDER_ID" --arg model "$OPENAI_MODEL" \
	'. + {defaultProvider: $provider, defaultModel: $model}' "$settings" |
	ai_write 0600 "$settings"

ai_report "pi" "$AGENT_DIR/models.json"
ai_log "  defaults: defaultProvider=$PROVIDER_ID defaultModel=$OPENAI_MODEL in $settings"
ai_log "  verify:   pi --offline --list-models $PROVIDER_ID"
