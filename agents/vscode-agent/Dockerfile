# =============================================================================
# agent-ide-vscode-agent - agent bundle: VS Code's built-in agent
# =============================================================================
#
# Layered on `agent-ide-base:rocky9`. There is no separate agent CLI to
# install here: VS Code 1.1xx ships the agent as a built-in extension
# (GitHub.copilot-chat, visible in the server under extensions/copilot), and
# the base image already contains the server and the standalone `code` CLI.
# This bundle therefore makes sure the built-in extension is present, and
# pre-configures it to run against the OpenAI-compatible endpoint given by the
# environment - the "bring your own key" (BYOK) path, which upstream documents
# as working without a GitHub account and without a Copilot plan.
#
# What is configured:
#
# * ~/.vscode-server/data/User/chatLanguageModels.json - a "Custom Endpoint"
#   provider (vendor `customendpoint`) with the endpoint URL, API key and model
#   from OPENAI_BASE_URL / OPENAI_API_KEY / OPENAI_MODEL. This is the
#   profile-level file VS Code reads for BYOK models; it is written on container
#   start, so the endpoint can be changed without rebuilding.
# * machine settings (build time): utility flows reuse the main BYOK model
#   instead of reaching for GitHub Copilot, and BYOK models are enabled in the
#   agent host, which is what the agent sessions in the Chat view run on.
#
# Build (context is the repository root):
#
#   podman build -f agents/vscode-agent/Dockerfile -t agent-ide-vscode-agent:rocky9 .
#
# Run:
#
#   podman run -d --name vscode-agent-devbox \
#     -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \
#     -e OPENAI_API_KEY=sk-... \
#     -e OPENAI_MODEL=qwen3-coder \
#     agent-ide-vscode-agent:rocky9 sleep infinity
#
# ... then attach VS Code and pick the model from the model picker. See
# agents/README.md for the environment contract and air-gap notes.
# =============================================================================

ARG BASE_IMAGE=agent-ide-base:rocky9
FROM ${BASE_IMAGE}

# Re-declared because ARGs do not survive a FROM.
ARG USERNAME=vscode

# -----------------------------------------------------------------------------
# The agent is a built-in extension of the server. Assert that instead of
# installing anything: the marketplace copy of Copilot Chat is versioned
# independently of the server and may refuse to run against it, whereas the
# bundled one is the version this server was tested with.
# -----------------------------------------------------------------------------
USER root

RUN set -eux; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    pkg="$(find "$target_home/.vscode-server/bin" -maxdepth 4 -path '*/extensions/copilot/package.json' -print -quit)"; \
    [ -n "$pkg" ] || { \
        echo "the built-in GitHub Copilot Chat extension is missing from this base image" >&2; \
        echo "build agent-ide-base from a VS Code Server release that ships it, or stage GitHub.copilot-chat as a VSIX in ./vsix" >&2; \
        exit 1; \
    }; \
    jq -r '"built-in agent extension: " + .publisher + "." + .name + " " + .version' "$pkg"

# -----------------------------------------------------------------------------
# Machine settings for BYOK:
#
# * chat.byokUtilityModelDefault=mainAgent - every utility flow (titles, commit
#   messages, intent detection) reuses the selected BYOK model, so nothing
#   tries to reach GitHub Copilot for them.
# * chat.agentHost.byokModels.enabled - upstream asks for this to use BYOK
#   models in agent-host sessions. Marked experimental upstream; harmless when
#   the setting disappears again.
# -----------------------------------------------------------------------------
RUN set -eux; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    settings="$target_home/.vscode-server/data/Machine/settings.json"; \
    tmp="$(mktemp)"; \
    jq '. + { \
        "chat.byokUtilityModelDefault": "mainAgent", \
        "chat.agentHost.byokModels.enabled": true \
    }' "$settings" > "$tmp"; \
    mv "$tmp" "$settings"; \
    chown "$USERNAME:$USERNAME" "$settings"; \
    chmod 0644 "$settings"; \
    jq -e '."chat.byokUtilityModelDefault", ."chat.agentHost.byokModels.enabled"' "$settings" > /dev/null

# -----------------------------------------------------------------------------
# Endpoint configuration
# -----------------------------------------------------------------------------
COPY agents/common/lib.sh /usr/local/lib/agent-ide/lib.sh
COPY agents/common/openai.env.example /etc/agent-ide/openai.env.example
COPY agents/common/entrypoint.sh /usr/local/bin/agent-ide-entrypoint
COPY agents/vscode-agent/configure.sh /usr/local/bin/agent-ide-configure

RUN set -eux; \
    chmod 0755 /usr/local/bin/agent-ide-entrypoint /usr/local/bin/agent-ide-configure; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    models="$target_home/.vscode-server/data/User/chatLanguageModels.json"; \
    test_env="OPENAI_BASE_URL=http://agent-ide-config-test.invalid:8080/v1 OPENAI_MODEL=agent-ide-smoke-test"; \
    su -s /bin/bash -c "HOME=${target_home} ${test_env} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    jq -e '.[0].models[0] | .id == "agent-ide-smoke-test" and (.url | contains("agent-ide-config-test.invalid"))' "$models" > /dev/null; \
    su -s /bin/bash -c "HOME=${target_home} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    jq -e . "$models" > /dev/null; \
    chown -R "$USERNAME:$USERNAME" "$target_home/.vscode-server/data/User"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Same default port as the base image (`vscode-web`).
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/agent-ide-entrypoint"]
CMD ["/bin/bash"]
