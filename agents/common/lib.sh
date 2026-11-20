#!/usr/bin/env bash
#
# Shared helpers for the agent-bundle configure scripts (agents/*/configure.sh).
#
# The bundles all point at one OpenAI-compatible endpoint and are configured
# through the same environment variables, so parsing and defaulting live here.
#
# Environment contract (read at container start, written into each agent's own
# config file by its configure script):
#
#   OPENAI_BASE_URL      endpoint, optionally with a path, e.g.
#                        https://api.openai.com/v1 or http://gateway.internal:8080/openai/v1
#                        (OPENAI_API_BASE is accepted as an alias)
#   OPENAI_API_KEY       key for that endpoint; a placeholder is used when unset
#   OPENAI_MODEL         model id served by the endpoint
#   OPENAI_MODEL_NAME    display name for the model (default: OPENAI_MODEL)
#   OPENAI_MODEL_GROUP   group name shown in pickers/UIs (default: Agent Endpoint)
#   OPENAI_API_TYPE      chat-completions | responses | messages
#
# Values can also be provided in an env file instead of the process
# environment. The default location is /etc/agent-ide/openai.env; override it
# with AI_ENV_FILE (set it to an empty string to disable).
#
set -euo pipefail

ai_log() { printf '\033[1;34m[agent-ide-configure]\033[0m %s\n' "$*"; }
ai_warn() { printf '\033[1;33m[agent-ide-configure] WARNING:\033[0m %s\n' "$*" >&2; }
ai_die() { printf '\033[1;31m[agent-ide-configure] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Optional env file. Turns something like
#
#   OPENAI_BASE_URL=http://gateway.internal:8080/v1
#   OPENAI_API_KEY=...
#   OPENAI_MODEL=qwen3-coder
#
# into container-local configuration without passing -e flags around. All
# variables from the file are exported, so tools that read them directly (for
# example goose's GOOSE_PROVIDER) see them too.
# ---------------------------------------------------------------------------
AI_ENV_FILE="${AI_ENV_FILE-/etc/agent-ide/openai.env}"
if [ -n "$AI_ENV_FILE" ] && [ -f "$AI_ENV_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$AI_ENV_FILE"
	set +a
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AI_DEFAULT_BASE_URL="${AI_DEFAULT_BASE_URL:-https://api.openai.com/v1}"
AI_DEFAULT_MODEL="${AI_DEFAULT_MODEL:-gpt-4o-mini}"

OPENAI_BASE_URL="${OPENAI_BASE_URL:-${OPENAI_API_BASE:-$AI_DEFAULT_BASE_URL}}"
OPENAI_MODEL="${OPENAI_MODEL:-$AI_DEFAULT_MODEL}"
OPENAI_MODEL_NAME="${OPENAI_MODEL_NAME:-$OPENAI_MODEL}"
OPENAI_API_TYPE="${OPENAI_API_TYPE:-chat-completions}"

AI_API_KEY_IS_PLACEHOLDER=false
if [ -z "${OPENAI_API_KEY:-}" ]; then
	# Most sandboxed gateways (llama.cpp, vLLM without --api-key, LiteLLM with a
	# fixed key) need *a* key on the wire but do not check it, and every agent
	# below refuses to start without one.
	OPENAI_API_KEY="agent-ide-placeholder"
	AI_API_KEY_IS_PLACEHOLDER=true
fi
export OPENAI_BASE_URL OPENAI_API_KEY OPENAI_MODEL OPENAI_MODEL_NAME OPENAI_API_TYPE

# ---------------------------------------------------------------------------
# Endpoint parsing.
#
# Splits the configured URL into scheme+authority (AI_ENDPOINT_ORIGIN) and the
# API root path (AI_ENDPOINT_API_ROOT, "" or "/v1" or "/openai/v1"). A trailing
# API path in the URL (…/v1/chat/completions) is accepted and stripped, so the
# same value works whether the operator pastes a base URL or a full endpoint.
# ---------------------------------------------------------------------------
ai_parse_endpoint() {
	local url="${1%/}"

	case "$url" in
		http://* | https://*) ;;
		*) ai_die "OPENAI_BASE_URL must be an http(s) URL, got '$1'" ;;
	esac

	AI_ENDPOINT_SCHEME="${url%%://*}"
	local rest="${url#*://}"
	local authority="${rest%%/*}"
	local path=""
	[ "$rest" != "$authority" ] && path="/${rest#*/}"
	[ -n "$authority" ] || ai_die "OPENAI_BASE_URL has no host: '$1'"

	case "$path" in
		*/chat/completions) path="${path%/chat/completions}" ;;
		*/responses) path="${path%/responses}" ;;
		*/messages) path="${path%/messages}" ;;
	esac

	AI_ENDPOINT_ORIGIN="$AI_ENDPOINT_SCHEME://$authority"
	AI_ENDPOINT_API_ROOT="$path"
}

# Path for an API type, always starting with "/".
ai_api_path() {
	case "$1" in
		chat-completions) printf '%s' "${AI_ENDPOINT_API_ROOT}/chat/completions" ;;
		responses) printf '%s' "${AI_ENDPOINT_API_ROOT}/responses" ;;
		messages) printf '%s' "${AI_ENDPOINT_API_ROOT}/messages" ;;
		*) ai_die "OPENAI_API_TYPE must be chat-completions, responses or messages, got '$1'" ;;
	esac
}

# Base URL without a trailing slash, as most agent configs expect it.
ai_api_root_url() { printf '%s%s' "$AI_ENDPOINT_ORIGIN" "$AI_ENDPOINT_API_ROOT"; }

# ---------------------------------------------------------------------------
# Write stdin to a file atomically, so a container that is restarted (or
# configured by hand while running) never sees a half-written config.
# ---------------------------------------------------------------------------
ai_write() { # <mode> <path>, content on stdin
	local mode="$1" path="$2" dir tmp
	dir="$(dirname "$path")"
	mkdir -p "$dir" || ai_die "cannot create $dir - run the container as the dev-container user (home must be writable)"
	tmp="$(mktemp "$dir/.agent-ide.XXXXXX")" || ai_die "cannot write to $dir"
	cat > "$tmp"
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$path"
}

# Double-quoted YAML scalar (for goose's config.yaml).
ai_yaml_string() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
}

ai_report() { # <agent name>, called after the config files are written
	ai_log "configured $1:"
	ai_log "  endpoint: $OPENAI_BASE_URL"
	ai_log "  model:    $OPENAI_MODEL ($OPENAI_MODEL_NAME)"
	[ "$AI_API_KEY_IS_PLACEHOLDER" = "true" ] &&
		ai_log "  api key:  placeholder - set OPENAI_API_KEY if the endpoint checks keys"
	ai_log "  config:   $2"
}
