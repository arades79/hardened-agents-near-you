# =============================================================================
# agent-ide-pi - agent bundle: pi coding agent CLI + VS Code extension
# =============================================================================
#
# Layered on `agent-ide-base:rocky9`. Adds:
#
# * Node.js (needed by pi; taken from the official nodejs.org tarball, checksum
#   verified - no repository access),
# * the pi coding agent CLI (npm package @earendil-works/pi-coding-agent,
#   version pinned, installed with --ignore-scripts),
# * the "Pi Coding Agent" VS Code extension (pi0.pi-vscode), installed from a
#   checksum-pinned VSIX, wired to the CLI through `pi-vscode.path`,
# * an OpenAI-compatible provider entry pre-configured from environment
#   variables at container start (OPENAI_BASE_URL / OPENAI_API_KEY /
#   OPENAI_MODEL), written to ~/.pi/agent/models.json plus the matching
#   defaultProvider/defaultModel in ~/.pi/agent/settings.json.
#
# Build (context is the repository root):
#
#   podman build -f agents/pi/Dockerfile -t agent-ide-pi:rocky9 .
#
# Run:
#
#   podman run -d --name pi-devbox \
#     -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \
#     -e OPENAI_API_KEY=sk-... \
#     -e OPENAI_MODEL=qwen3-coder \
#     agent-ide-pi:rocky9 sleep infinity
#
# See agents/README.md for the environment contract and air-gap notes.
# =============================================================================

ARG BASE_IMAGE=agent-ide-base:rocky9
FROM ${BASE_IMAGE}

# Re-declared because ARGs do not survive a FROM.
ARG USERNAME=vscode

# -----------------------------------------------------------------------------
# Node.js (pi requires Node 22.19+, and the tarball is the only dependency-free
# way to get it on an air-gapped build host). For arm64, override NODE_ARCH and
# NODE_DIST_SHA256 (the checksum is per-architecture).
# -----------------------------------------------------------------------------
ARG NODE_VERSION=22.23.3
ARG NODE_ARCH=x64
ARG NODE_DIST_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
ARG NODE_URL=

# -----------------------------------------------------------------------------
# pi coding agent
#
# PI_TARBALL_URL + PI_TARBALL_SHA256 install from a mirrored npm tarball
# instead of talking to the registry; the package's dependencies still come
# from PI_NPM_REGISTRY, so point both at your internal mirror for a fully
# local build. The version that ships here is the one the repository pins.
# -----------------------------------------------------------------------------
ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG PI_VERSION=1.3.0
ARG PI_TARBALL_URL=
ARG PI_TARBALL_SHA256=ae2785e870b81a8c8e1d44510a57b5ee0bfc9e974679ac2faaada4aabee3d3c0
ARG PI_NPM_REGISTRY=https://registry.npmjs.org
ARG PI_EXT_PUBLISHER=pi0
ARG PI_EXT_NAME=pi-vscode
ARG PI_EXT_VERSION=0.0.9
ARG PI_EXT_SHA256=d5a5283c1136d4a3120d2626de875d5fc8cf1625c609c5dcc85f2097a909dd47
ARG PI_EXT_URL=

USER root

RUN set -eux; \
    url="${NODE_URL:-https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz}"; \
    curl -fsSL --retry 5 --retry-delay 2 -o /tmp/node.tar.xz "$url"; \
    echo "${NODE_DIST_SHA256}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f /tmp/node.tar.xz; \
    node --version; \
    npm --version

RUN set -eux; \
    export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false; \
    if [ -n "${PI_TARBALL_URL}" ]; then \
        curl -fsSL --retry 5 --retry-delay 2 -o /tmp/pi.tgz "${PI_TARBALL_URL}"; \
        echo "${PI_TARBALL_SHA256}  /tmp/pi.tgz" | sha256sum -c -; \
        npm install -g --ignore-scripts --registry "${PI_NPM_REGISTRY}" /tmp/pi.tgz; \
        rm -f /tmp/pi.tgz; \
    else \
        npm install -g --ignore-scripts --registry "${PI_NPM_REGISTRY}" "${PI_PACKAGE}@${PI_VERSION}"; \
    fi; \
    npm cache clean --force; \
    rm -rf /root/.npm; \
    command -v pi; \
    pi --version

# -----------------------------------------------------------------------------
# VS Code extension (see the opencode bundle for notes on the checksum).
# -----------------------------------------------------------------------------
COPY scripts/install-extensions.sh /tmp/install-extensions.sh

RUN set -eux; \
    url="${PI_EXT_URL:-https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${PI_EXT_PUBLISHER}/vsextensions/${PI_EXT_NAME}/${PI_EXT_VERSION}/vspackage}"; \
    tmp="$(mktemp -d)"; \
    # the extension CLI runs as the target user, so the payload has to be readable by it
    chmod 0755 "$tmp"; \
    curl -fsSL --compressed --retry 5 --retry-delay 2 -o "$tmp/${PI_EXT_PUBLISHER}.${PI_EXT_NAME}.vsix" "$url"; \
    chmod 0644 "$tmp/${PI_EXT_PUBLISHER}.${PI_EXT_NAME}.vsix"; \
    echo "${PI_EXT_SHA256}  $tmp/${PI_EXT_PUBLISHER}.${PI_EXT_NAME}.vsix" | sha256sum -c -; \
    /bin/bash /tmp/install-extensions.sh "$USERNAME" "$tmp"; \
    rm -rf "$tmp" /tmp/install-extensions.sh

# The extension finds the CLI by itself in the usual locations, but pinning the
# path keeps it working when the server is started with a minimal PATH.
RUN set -eux; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    settings="$target_home/.vscode-server/data/Machine/settings.json"; \
    pi_bin="$(command -v pi)"; \
    tmp="$(mktemp)"; \
    jq --arg bin "$pi_bin" '. + {"pi-vscode.path": $bin}' "$settings" > "$tmp"; \
    mv "$tmp" "$settings"; \
    chown "$USERNAME:$USERNAME" "$settings"; \
    chmod 0644 "$settings"; \
    jq -e '."pi-vscode.path"' "$settings" > /dev/null

# -----------------------------------------------------------------------------
# Endpoint configuration
#
# The build renders the config twice: once with throwaway values to prove the
# agent really consumes it, then again with the environment defaults that ship
# in the image. The entrypoint re-renders it on every container start.
# -----------------------------------------------------------------------------
COPY agents/common/lib.sh /usr/local/lib/agent-ide/lib.sh
COPY agents/common/openai.env.example /etc/agent-ide/openai.env.example
COPY agents/common/entrypoint.sh /usr/local/bin/agent-ide-entrypoint
COPY agents/pi/configure.sh /usr/local/bin/agent-ide-configure

RUN set -eux; \
    chmod 0755 /usr/local/bin/agent-ide-entrypoint /usr/local/bin/agent-ide-configure; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    test_env="OPENAI_BASE_URL=http://agent-ide-config-test.invalid:8080/v1 OPENAI_MODEL=agent-ide-smoke-test"; \
    su -s /bin/bash -c "HOME=${target_home} ${test_env} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    su -s /bin/bash -c "HOME=${target_home} PI_OFFLINE=1 pi --offline --list-models agent-endpoint" "$USERNAME" \
        | grep -q 'agent-ide-smoke-test'; \
    su -s /bin/bash -c "HOME=${target_home} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    jq -e . "$target_home/.pi/agent/models.json" > /dev/null; \
    jq -e . "$target_home/.pi/agent/settings.json" > /dev/null; \
    chown -R "$USERNAME:$USERNAME" "$target_home/.pi"

# Quiet by default inside a sandbox: no pi.dev version check, no telemetry, and
# no automatic model-catalog refresh (which a disconnected network would only
# turn into timeouts). Unset PI_OFFLINE when the container can reach the
# internet and you want catalog updates: `-e PI_OFFLINE=`.
ENV PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0 \
    PI_OFFLINE=1

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Same default port as the base image (`vscode-web`).
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/agent-ide-entrypoint"]
CMD ["/bin/bash"]
