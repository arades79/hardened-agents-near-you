# =============================================================================
# agent-ide-opencode - agent bundle: opencode CLI + VS Code extension
# =============================================================================
#
# Layered on `agent-ide-base:rocky9`, so it keeps the baked-in VS Code Server,
# the machine settings and the offline `vscode-web` helper. On top of that it
# adds:
#
# * the opencode CLI (release binary from the upstream GitHub repository,
#   checksum verified; this image is glibc-based, so it takes the glibc asset
#   rather than the musl one upstream uses in its own Alpine image),
# * the "opencode" VS Code extension (sst-dev.opencode), installed from a
#   checksum-pinned VSIX at build time, never from the marketplace at runtime,
# * an OpenAI-compatible provider entry pre-configured from environment
#   variables at container start (OPENAI_BASE_URL / OPENAI_API_KEY /
#   OPENAI_MODEL), written to ~/.config/opencode/opencode.json.
#
# The extension itself is a thin launcher: it opens the opencode CLI in an
# integrated terminal, so all model configuration lives in opencode's own
# config file - which is what the entrypoint writes.
#
# Build (context is the repository root):
#
#   podman build -f agents/opencode/Dockerfile -t agent-ide-opencode:rocky9 .
#   docker build -f agents/opencode/Dockerfile -t agent-ide-opencode:rocky9 .
#
# (or build every bundle at once with agents/build.sh)
# Run:
#
#   podman run -d --name opencode-devbox \
#     -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \
#     -e OPENAI_API_KEY=sk-... \
#     -e OPENAI_MODEL=qwen3-coder \
#     agent-ide-opencode:rocky9 sleep infinity
#
# See agents/README.md for the environment contract and air-gap notes.
# =============================================================================

ARG BASE_IMAGE=agent-ide-base:rocky9
FROM ${BASE_IMAGE}

# Re-declared because ARGs do not survive a FROM.
ARG USERNAME=vscode

# -----------------------------------------------------------------------------
# opencode CLI
#
# OPENCODE_ASSET selects the release build. This image is glibc-based, so the
# default is the plain linux-x64 build (it needs glibc 2.17+, Rocky 9 has 2.34).
# The -musl assets are for Alpine-style images and will not start here; the
# -baseline assets are the same glibc build without AVX2 requirements, for
# older fleet CPUs.
# -----------------------------------------------------------------------------
ARG OPENCODE_VERSION=1.19.3
ARG OPENCODE_ASSET=opencode-linux-x64.tar.gz
ARG OPENCODE_SHA256=13a8fb2978302071b86f9d7e00da9c8895f9cd846978379c3bdc6a5333536c9b
ARG OPENCODE_URL=
ARG OPENCODE_EXT_PUBLISHER=sst-dev
ARG OPENCODE_EXT_NAME=opencode
ARG OPENCODE_EXT_VERSION=1.0.0
ARG OPENCODE_EXT_SHA256=ddec815ab9a4a481b351e1ea297996688a443d9ac02cb21b7d9b423ce315e0c4
ARG OPENCODE_EXT_URL=

USER root

RUN set -eux; \
    version="${OPENCODE_VERSION#v}"; \
    url="${OPENCODE_URL:-https://github.com/anomalyco/opencode/releases/download/v${version}/${OPENCODE_ASSET}}"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 -o "$tmp/opencode.tar.gz" "$url"; \
    echo "${OPENCODE_SHA256}  $tmp/opencode.tar.gz" | sha256sum -c -; \
    tar -xzf "$tmp/opencode.tar.gz" -C "$tmp"; \
    bin="$(find "$tmp" -type f -name opencode -perm -u+x -print -quit)"; \
    [ -n "$bin" ] || { echo "opencode binary not found in $url" >&2; exit 1; }; \
    install -m 0755 "$bin" /usr/local/bin/opencode; \
    rm -rf "$tmp"; \
    /usr/local/bin/opencode --version

# -----------------------------------------------------------------------------
# VS Code extension
#
# Downloaded from the marketplace as a version-pinned VSIX and installed with
# the server's own offline CLI through the same script the base image uses. The
# payload is deleted in the same layer, so it never becomes part of the image.
# The checksum is of the VSIX as `curl --compressed` writes it (the gallery
# serves the file with Content-Encoding: gzip; --compressed undoes that).
# -----------------------------------------------------------------------------
COPY scripts/install-extensions.sh /tmp/install-extensions.sh

RUN set -eux; \
    url="${OPENCODE_EXT_URL:-https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${OPENCODE_EXT_PUBLISHER}/vsextensions/${OPENCODE_EXT_NAME}/${OPENCODE_EXT_VERSION}/vspackage}"; \
    tmp="$(mktemp -d)"; \
    # the extension CLI runs as the target user, so the payload has to be readable by it
    chmod 0755 "$tmp"; \
    curl -fsSL --compressed --retry 5 --retry-delay 2 -o "$tmp/${OPENCODE_EXT_PUBLISHER}.${OPENCODE_EXT_NAME}.vsix" "$url"; \
    chmod 0644 "$tmp/${OPENCODE_EXT_PUBLISHER}.${OPENCODE_EXT_NAME}.vsix"; \
    echo "${OPENCODE_EXT_SHA256}  $tmp/${OPENCODE_EXT_PUBLISHER}.${OPENCODE_EXT_NAME}.vsix" | sha256sum -c -; \
    /bin/bash /tmp/install-extensions.sh "$USERNAME" "$tmp"; \
    rm -rf "$tmp" /tmp/install-extensions.sh

# -----------------------------------------------------------------------------
# Endpoint configuration
#
# lib.sh + configure.sh render the opencode provider from the environment. The
# build runs it once so the image works with defaults; the entrypoint runs it
# again on every container start.
# -----------------------------------------------------------------------------
COPY agents/common/lib.sh /usr/local/lib/agent-ide/lib.sh
COPY agents/common/openai.env.example /etc/agent-ide/openai.env.example
COPY agents/common/entrypoint.sh /usr/local/bin/agent-ide-entrypoint
COPY agents/opencode/configure.sh /usr/local/bin/agent-ide-configure

RUN set -eux; \
    chmod 0755 /usr/local/bin/agent-ide-entrypoint /usr/local/bin/agent-ide-configure; \
    target_home="$(getent passwd "$USERNAME" | cut -d: -f6)"; \
    test_env="OPENAI_BASE_URL=http://agent-ide-config-test.invalid:8080/v1 OPENAI_MODEL=agent-ide-smoke-test"; \
    su -s /bin/bash -c "HOME=${target_home} ${test_env} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    su -s /bin/bash -c "HOME=${target_home} opencode models agent-endpoint" "$USERNAME" \
        | grep -q 'agent-endpoint/agent-ide-smoke-test'; \
    su -s /bin/bash -c "HOME=${target_home} /usr/local/bin/agent-ide-configure" "$USERNAME"; \
    jq -e . "$target_home/.config/opencode/opencode.json" > /dev/null; \
    chown -R "$USERNAME:$USERNAME" "$target_home/.config"

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Same default port as the base image (`vscode-web`).
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/agent-ide-entrypoint"]
CMD ["/bin/bash"]
