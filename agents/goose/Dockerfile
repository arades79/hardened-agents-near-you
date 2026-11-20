# =============================================================================
# agent-ide-goose - agent bundle: goose CLI + VS Code extension
# =============================================================================
#
# Layered on `agent-ide-base:rocky9`. Adds:
#
# * the goose CLI (static release binary, checksum verified),
# * the "VS Code Goose" extension (block.vscode-goose), installed from a
#   checksum-pinned VSIX and wired to the CLI through `goose.binaryPath`,
# * an OpenAI-compatible provider pre-configured from environment variables at
#   container start (OPENAI_BASE_URL / OPENAI_API_KEY / OPENAI_MODEL), written
#   to ~/.config/goose/config.yaml - the same file the VS Code extension reads.
#
# Goose does not accept API keys in config.yaml, so the key has to reach goose
# as OPENAI_API_KEY in the process environment. The entrypoint keeps the
# container's own environment as-is (that is what `docker run -e` and a
# devcontainer's `containerEnv` set), and lib.sh also reads the optional
# /etc/agent-ide/openai.env file for fleets that mount settings instead of
# passing flags. `GOOSE_DISABLE_KEYRING=1` is set below so goose uses
# file-based secrets (~/.config/goose/secrets.yaml) rather than looking for a
# desktop keyring that a headless container does not have.
#
# Build (context is the repository root):
#
#   podman build -f agents/goose/Dockerfile -t agent-ide-goose:rocky9 .
#
# Run:
#
#   podman run -d --name goose-devbox \
#     -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \
#     -e OPENAI_API_KEY=sk-... \
#     -e OPENAI_MODEL=qwen3-coder \
#     agent-ide-goose:rocky9 sleep infinity
#
# See agents/README.md for the environment contract and air-gap notes.
# =============================================================================

ARG BASE_IMAGE=agent-ide-base:rocky9
FROM ${BASE_IMAGE}

# Re-declared because ARGs do not survive a FROM.
ARG USERNAME=vscode

# -----------------------------------------------------------------------------
# goose CLI
#
# GOOSE_ASSET selects the release build. The musl build is static and the safe
# choice for mixed fleets; the gnu build is the upstream default for glibc
# distributions and is what the checksum below belongs to. Use the vulkan
# variants only for local GPU inference (they pull in a larger runtime).
# -----------------------------------------------------------------------------
ARG GOOSE_VERSION=1.55.0
ARG GOOSE_ASSET=goose-x86_64-unknown-linux-gnu.tar.gz
ARG GOOSE_SHA256=fd3932908328fac850ca7ad2a8289c744e0c2ddaf4c5a2338709fb17a00b3a4c
ARG GOOSE_URL=
ARG GOOSE_EXT_PUBLISHER=block
ARG GOOSE_EXT_NAME=vscode-goose
ARG GOOSE_EXT_VERSION=0.2.3
ARG GOOSE_EXT_SHA256=a7a569543bba5592c628638c0925ad68e15f87bb3deabf9cc9de53234b590376
ARG GOOSE_EXT_URL=
# The extension needs a goose CLI it understands; fail the build early if the
# pinned pair drifts apart.
ARG GOOSE_EXT_MIN_CLI_VERSION=1.16.0

USER root

RUN set -eux; \
    version="${GOOSE_VERSION#v}"; \
    url="${GOOSE_URL:-https://github.com/aaif-goose/goose/releases/download/v${version}/${GOOSE_ASSET}}"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/goose.tgz" "$url"; \
    echo "${GOOSE_SHA256}  $tmp/goose.tgz" | sha256sum -c -; \
    tar -xf "$tmp/goose.tgz" -C "$tmp"; \
    bin="$(find "$tmp" -type f -name goose -perm -u+x -print -quit)"; \
    [ -n "$bin" ] || { echo "goose binary not found in $url" >&2; exit 1; }; \
    install -m 0755 "$bin" /usr/local/bin/goose; \
    rm -rf "$tmp"; \
    /usr/local/bin/goose --version

# -----------------------------------------------------------------------------
# VS Code extension (see the opencode bundle for notes on the checksum).
# -----------------------------------------------------------------------------
COPY scripts/install-extensions.sh /tmp/install-extensions.sh

RUN set -eux; \
    url="${GOOSE_EXT_URL:-https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${GOOSE_EXT_PUBLISHER}/vsextensions/${GOOSE_EXT_NAME}/${GOOSE_EXT_VERSION}/vspackage}"; \
    tmp="$(mktemp -d)"; \
    # the extension CLI runs as the target user, so the payload has to be readable by it
    chmod 0755 "$tmp"; \
    curl -fsSL --compressed --retry 5 --retry-delay 2 -o "$tmp/${GOOSE_EXT_PUBLISHER}.${GOOSE_EXT_NAME}.vsix" "$url"; \
    chmod 0644 "$tmp/${GOOSE_EXT_PUBLISHER}.${GOOSE_EXT_NAME}.vsix"; \
    echo "${GOOSE_EXT_SHA256}  $tmp/${GOOSE_EXT_PUBLISHER}.${GOOSE_EXT_NAME}.vsix" | sha256sum -c -; \
    /bin/bash /tmp/install-extensions.sh "$USERNAME" "$tmp"; \
    rm -rf "$tmp" /tmp/install-extensions.sh

RUN set -eux; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    settings="$target_home/.vscode-server/data/Machine/settings.json"; \
    goose_bin="$(command -v goose)"; \
    tmp="$(mktemp)"; \
    jq --arg bin "$goose_bin" '. + {"goose.binaryPath": $bin}' "$settings" > "$tmp"; \
    mv "$tmp" "$settings"; \
    chown "$USERNAME:$USERNAME" "$settings"; \
    chmod 0644 "$settings"; \
    jq -e '."goose.binaryPath"' "$settings" > /dev/null; \
    cli_version="$(goose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; \
    [ "$(printf '%s\n%s\n' "$GOOSE_EXT_MIN_CLI_VERSION" "$cli_version" | sort -V | head -n1)" = "$GOOSE_EXT_MIN_CLI_VERSION" ] \
        || { echo "goose $cli_version is older than the extension's minimum $GOOSE_EXT_MIN_CLI_VERSION" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Endpoint configuration
# -----------------------------------------------------------------------------
COPY agents/common/lib.sh /usr/local/lib/agent-ide/lib.sh
COPY agents/common/openai.env.example /etc/agent-ide/openai.env.example
COPY agents/common/entrypoint.sh /usr/local/bin/agent-ide-entrypoint
COPY agents/goose/configure.sh /usr/local/bin/agent-ide-configure

RUN set -eux; \
    chmod 0755 /usr/local/bin/agent-ide-entrypoint /usr/local/bin/agent-ide-configure; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    test_env="OPENAI_BASE_URL=http://agent-ide-config-test.invalid:8080/v1 OPENAI_MODEL=agent-ide-smoke-test OPENAI_API_KEY=agent-ide-smoke-test"; \
    su -s /bin/bash -c "HOME=${target_home} ${test_env} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    su -s /bin/bash -c "HOME=${target_home} GOOSE_DISABLE_KEYRING=1 goose info -v" "$USERNAME" \
        | grep -q 'agent-ide-config-test.invalid'; \
    su -s /bin/bash -c "HOME=${target_home} GOOSE_DISABLE_KEYRING=1 goose info -v" "$USERNAME" \
        | grep -q 'agent-ide-smoke-test'; \
    su -s /bin/bash -c "HOME=${target_home} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    chown -R "$USERNAME:$USERNAME" "$target_home/.config/goose"

# No desktop keyring in a container: store secrets in ~/.config/goose/secrets.yaml.
# Telemetry is off by default upstream; state it explicitly for the sandbox.
ENV GOOSE_DISABLE_KEYRING=1 \
    GOOSE_TELEMETRY_ENABLED=false

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Same default port as the base image (`vscode-web`).
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/agent-ide-entrypoint"]
CMD ["/bin/bash"]
