#!/usr/bin/env bash
#
# Entrypoint wrapper for the agent-bundle images.
#
# The bundle images need two run-time steps that the base image does not have:
# materializing the OpenAI endpoint from the environment into each agent's own
# config file (opencode.json, models.json, config.yaml, chatLanguageModels.json),
# and applying the container-side egress sandbox (default-deny to public IP
# space, LAN allowed - see sandbox/README.md). Doing it here means
# `docker run -e OPENAI_BASE_URL=... <bundle> <anything>` works, including the
# usual `docker run -d <bundle> sleep infinity` attach flow. Both are redone on
# every container start, so changing the environment (or
# /etc/agent-ide/openai.env) is enough to re-point the agents.
#
# Escape hatches:
#   AGENT_IDE_SKIP_CONFIGURE=1   do not touch the config files at all
#   AGENT_IDE_STRICT=1          fail the container if configuration fails
#                                 (default: warn and continue with the config
#                                 baked into the image)
#   AGENT_IDE_SANDBOX=apply|require|off
#                               egress sandbox policy: apply it if possible and
#                               warn if not (default), refuse to start if it
#                               cannot be applied, or skip it entirely
#   AGENT_IDE_SANDBOX_ALLOW     extra destination ranges, e.g. "10.20.0.0/16"
#
set -euo pipefail

sandbox=/usr/local/bin/agent-ide-sandbox
configure=/usr/local/bin/agent-ide-configure

# The egress sandbox goes first: in AGENT_IDE_SANDBOX=require mode the container
# must not start at all when the rules cannot be installed.
if [ -x "$sandbox" ]; then
	if ! "$sandbox" apply; then
		printf '\033[1;31m[agent-ide-entrypoint] refusing to start: the container egress sandbox could not be applied\033[0m\n' >&2
		exit 1
	fi
fi

if [ "${AGENT_IDE_SKIP_CONFIGURE:-0}" != "1" ] && [ -x "$configure" ]; then
	if ! "$configure"; then
		if [ "${AGENT_IDE_STRICT:-0}" = "1" ]; then
			exit 1
		fi
		printf '\033[1;33m[agent-ide-entrypoint] WARNING:\033[0m %s\n' \
			"configuration failed; keeping the config baked into the image" >&2
	fi
fi

exec "$@"
