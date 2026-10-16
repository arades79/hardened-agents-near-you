# =============================================================================
# agent-ide base image - Rocky Linux 9 + pre-installed VS Code Server
# =============================================================================
#
# Purpose
# -------
# A Rocky Linux 9 base that behaves as a turnkey VS Code Dev Container, including
# on fully air-gapped networks where the container cannot reach
# update.code.visualstudio.com to fetch the VS Code Server at attach time.
#
# How it works
# ------------
# * The VS Code Server tarball is baked into ~/.vscode-server/bin/<commit>, next
#   to the "0" install marker file, so the Dev Containers / Remote extensions
#   find an installed server and never try to download one.
# * <commit> MUST match the commit of the VS Code desktop client that attaches
#   to this container (Help > About shows it). If it does not match, the client
#   will try to download its own server and fail on an air-gapped network.
#   Rebuild with --build-arg VSCODE_COMMIT=<sha> to match your fleet.
#   The default below is VS Code 1.142.0.
# * Extensions are supplied as .vsix files in ./vsix and installed at build
#   time through the server's own CLI. No marketplace access is used.
# * Machine-scope settings disable workspace-trust prompts, telemetry, update
#   checks and extension auto-updates - things that would otherwise keep
#   reaching for the internet from inside the sandbox.
# * The standalone VS Code CLI ("code") is installed for tunnel/serve-web use
#   on connected networks. It is not needed for the air-gapped attach flow.
# * The web flavor of the server is baked into /opt/vscode-server-web so the
#   browser UI also works with zero downloads via the `vscode-web` command.
#
# Build
# -----
#   docker build -t agent-ide-base:rocky9 .
#   docker build --build-arg VSCODE_COMMIT=<sha> --build-arg VSCODE_ARCH=arm64 ...
#
# Requires BuildKit (default in Docker 23+ / Podman 4+). ./vsix is copied into
# a throwaway scratch stage and bind-mounted read-only during the extension
# install, so the .vsix payloads never become part of the shipped image - which
# matters because these images are transferred with `docker save`/`load`.
#
# =============================================================================

# Throwaway stage holding the .vsix files (see vsix/README.md). Bind-mounting
# from a stage works across builders, unlike mounting a host path, which can
# trip over SELinux labels on hardened build hosts.
FROM scratch AS vsix
COPY vsix/ /

FROM rockylinux:9

# -----------------------------------------------------------------------------
# VS Code version to bake in.
#
# VSCODE_COMMIT:  the 40-char commit of the desktop client release to match.
#                 1.142.0 = 6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1
# VSCODE_ARCH:    x64 | arm64
# VSCODE_SERVER_SHA256: sha256 of vscode-server-linux-<arch>.tar.gz from
#                 https://update.code.visualstudio.com/api/update/server-linux-<arch>/stable/<commit>
#                 Set empty to skip verification (e.g. behind a mirror).
# VSCODE_SERVER_URL / VSCODE_CLI_URL: full overrides for internal mirrors.
# INSTALL_VSCODE_CLI: install the standalone "code" CLI (tunnel/serve-web).
#
# The browser UI (`vscode-web`) needs the separate web flavor of the server:
# VSCODE_WEB_SERVER_SHA256: sha256 of vscode-server-linux-<arch>-web.tar.gz.
#                 Note: the update API does not expose -web metadata; compute
#                 it with: curl -fsSL <url> | sha256sum
# VSCODE_WEB_SERVER_URL / INSTALL_WEB_SERVER: override URL / skip the web
#                 server entirely (it is the largest single component).
# -----------------------------------------------------------------------------
ARG VSCODE_COMMIT=6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1
ARG VSCODE_ARCH=x64
ARG VSCODE_SERVER_SHA256=f1ee2833c6323ee03e49d46351e834c44811c53d14ba178f5debdb84a5eb7876
ARG VSCODE_SERVER_URL=
ARG VSCODE_CLI_URL=
ARG INSTALL_VSCODE_CLI=true
ARG VSCODE_WEB_SERVER_SHA256=0c9e305190e69895ad609321a001f0b44496e3f8dfdbcbf9fc72125cb82b87de
ARG VSCODE_WEB_SERVER_URL=
ARG INSTALL_WEB_SERVER=true

# -----------------------------------------------------------------------------
# Dev-container user. Matches the convention used by the upstream devcontainer
# base images so `"remoteUser": "vscode"` and postCreate hooks just work.
# -----------------------------------------------------------------------------
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000

# -----------------------------------------------------------------------------
# Base packages. Everything here is either required by the VS Code Server or
# part of the baseline toolset a dev container is expected to provide.
# Note: curl comes from curl-minimal, which is already in the base image
# (installing the full curl package conflicts with it).
#
# EPEL is enabled for the search/inspection tools below (ripgrep, fd-find).
# It is a build-time convenience only: this image targets air-gapped networks,
# so no repo is reachable at runtime. epel-release is kept so derived images
# can `dnf install` from EPEL when they are built.
# xsv is not shipped by Rocky 9 or EPEL; add it as a static binary or from
# source in a derived image if needed.
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=false epel-release; \
    dnf -y install --setopt=install_weak_deps=false \
        ca-certificates \
        wget \
        git \
        tar \
        gzip \
        xz \
        unzip \
        zip \
        jq \
        procps-ng \
        findutils \
        hostname \
        which \
        less \
        sudo \
        shadow-utils \
        glibc-langpack-en \
        ripgrep \
        fd-find \
        ; \
    dnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

# Locale after the language pack is present, so later build steps (and the
# running container) get a valid UTF-8 locale without setlocale warnings.
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# Create the non-root user with passwordless sudo (devcontainer convention).
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd --gid "${USER_GID}" "${USERNAME}"; \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}"; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${USERNAME}" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# -----------------------------------------------------------------------------
# Install the VS Code Server + CLI into /home/vscode/.vscode-server
# -----------------------------------------------------------------------------
COPY scripts/install-vscode-server.sh /tmp/install-vscode-server.sh
RUN VSCODE_COMMIT="${VSCODE_COMMIT}" \
    VSCODE_ARCH="${VSCODE_ARCH}" \
    VSCODE_SERVER_SHA256="${VSCODE_SERVER_SHA256}" \
    VSCODE_SERVER_URL="${VSCODE_SERVER_URL}" \
    VSCODE_CLI_URL="${VSCODE_CLI_URL}" \
    INSTALL_VSCODE_CLI="${INSTALL_VSCODE_CLI}" \
    VSCODE_WEB_SERVER_SHA256="${VSCODE_WEB_SERVER_SHA256}" \
    VSCODE_WEB_SERVER_URL="${VSCODE_WEB_SERVER_URL}" \
    INSTALL_WEB_SERVER="${INSTALL_WEB_SERVER}" \
    /bin/bash /tmp/install-vscode-server.sh "${USERNAME}" \
 && rm -f /tmp/install-vscode-server.sh

# -----------------------------------------------------------------------------
# Install extensions from ./vsix (offline; no marketplace). Mounted read-only
# from the throwaway `vsix` stage, so the payloads stay out of the image.
# -----------------------------------------------------------------------------
COPY scripts/install-extensions.sh /tmp/install-extensions.sh
RUN --mount=type=bind,from=vsix,source=.,target=/tmp/vsix \
    /bin/bash /tmp/install-extensions.sh "${USERNAME}" /tmp/vsix \
 && rm -f /tmp/install-extensions.sh

# -----------------------------------------------------------------------------
# Runtime helper: serve the pre-installed server as a browser endpoint,
# fully offline (no `code serve-web` download).
# -----------------------------------------------------------------------------
COPY scripts/vscode-web.sh /usr/local/bin/vscode-web
RUN chmod 0755 /usr/local/bin/vscode-web

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Default port used by /usr/local/bin/vscode-web.
EXPOSE 8000

CMD ["/bin/bash"]
