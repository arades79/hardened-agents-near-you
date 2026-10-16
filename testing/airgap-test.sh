#!/usr/bin/env bash
#
# Air-gap acceptance test for the agent-ide base image.
#
# Run INSIDE the disconnected Rocky 9 VM, as your desktop user, from the
# unpacked bundle directory:
#
#   bash ~/airgap-bundle/airgap-test.sh [--allow-network] [--negative-control]
#
#   --allow-network     treat network reachability as a warning instead of a
#                       failure (use for a smoke run before disconnecting)
#   --negative-control  after the main test, hide the baked server to show
#                       that attach then fails - proves what the image
#                       pre-install actually buys you
#
# The script automates everything scriptable (offline proof, client rpm, VSIX
# install, settings, podman, image load, baked-content checks, browser UI) and
# walks you through the two interactive parts: attaching from VS Code and
# reading the evidence.
#
set -uo pipefail

ALLOW_NETWORK=false
NEGATIVE_CONTROL=false
for arg in "$@"; do
	case "$arg" in
		--allow-network) ALLOW_NETWORK=true ;;
		--negative-control) NEGATIVE_CONTROL=true ;;
		-h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME=agentide-devbox
WEB_CONTAINER_NAME=agentide-web
WEB_PORT=8000
PODMAN_SOCKET_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PODMAN_SOCKET="$PODMAN_SOCKET_DIR/podman/podman.sock"

PASS=0
FAIL=0
WARN=0
pass() { PASS=$((PASS + 1)); printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
fail_or_warn() {
	# network findings are failures during the real run, warnings with --allow-network
	if [ "$ALLOW_NETWORK" = true ]; then
		WARN=$((WARN + 1))
		printf '\033[1;33m[WARN]\033[0m %s (allowed by --allow-network)\n' "$*"
	else
		FAIL=$((FAIL + 1))
		printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"
	fi
}
warn() { WARN=$((WARN + 1)); printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
info() { printf '     %s\n' "$*"; }

# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
	printf 'Run this as your desktop user (not root); sudo is used where needed.\n' >&2
	exit 1
fi
if [ ! -f "$BUNDLE_DIR/bundle.env" ]; then
	printf 'bundle.env not found - run this from the unpacked bundle directory.\n' >&2
	exit 1
fi
# shellcheck source=/dev/null
source "$BUNDLE_DIR/bundle.env"
: "${IMAGE_TAG:?}" "${IMAGE_TAR:?}" "${VSCODE_VERSION:?}" "${VSCODE_COMMIT:?}"
: "${VSCODE_RPM:?}" "${DC_VSIX:?}" "${DC_EXT_ID:?}"

printf '\033[1magent-ide air-gap acceptance test\033[0m\n'
info "bundle:        $BUNDLE_DIR"
info "image:         $IMAGE_TAG"
info "VS Code:       $VSCODE_VERSION (commit $VSCODE_COMMIT)"

# ---------------------------------------------------------------------------
step "1/9  offline check"
if ! command -v ip >/dev/null 2>&1; then
	warn "'ip' command not available - interface check skipped"
fi
non_lo="$(ip -brief addr 2>/dev/null | awk '$1 != "lo" && $2 != "DOWN" {print $1"("$2")"}' | tr '\n' ' ')"
if [ -z "$non_lo" ]; then
	pass "no non-loopback interfaces are up"
else
	fail_or_warn "these interfaces are up: $non_lo"
fi
if timeout 8 getent hosts update.code.visualstudio.com >/dev/null 2>&1; then
	fail_or_warn "DNS resolves update.code.visualstudio.com"
else
	pass "DNS for update.code.visualstudio.com does not resolve"
fi
if curl -fsS -m 5 -o /dev/null https://update.code.visualstudio.com/ 2>/dev/null; then
	fail_or_warn "HTTPS to update.code.visualstudio.com succeeds"
else
	pass "HTTPS to update.code.visualstudio.com fails (no route / no DNS)"
fi

# ---------------------------------------------------------------------------
step "2/9  bundle integrity"
if (cd "$BUNDLE_DIR" && sha256sum -c --quiet MANIFEST.sha256 >/dev/null 2>&1); then
	pass "MANIFEST.sha256 verified"
else
	fail "checksum mismatch - re-transfer the bundle"
fi

# ---------------------------------------------------------------------------
step "3/9  VS Code desktop client (rpm)"
need_install=true
if rpm -q code >/dev/null 2>&1; then
	have="$(rpm -q --qf '%{VERSION}' code)"
	if [ "$have" = "$VSCODE_VERSION" ]; then
		need_install=false
		pass "code rpm $have already installed"
	else
		warn "installed code rpm is $have, bundle has $VSCODE_VERSION - reinstalling"
	fi
fi
if [ "$need_install" = true ]; then
	info "installing $VSCODE_RPM (plus bundled dependencies)"
	if ! sudo dnf -y install --disablerepo='*' "$BUNDLE_DIR/$VSCODE_RPM" >/tmp/airgap-dnf.log 2>&1; then
		info "direct install failed, retrying with bundled dependencies"
		if ! sudo dnf -y install --disablerepo='*' "$BUNDLE_DIR"/rpms/*.rpm "$BUNDLE_DIR/$VSCODE_RPM" >/tmp/airgap-dnf.log 2>&1; then
			fail "rpm install failed - see /tmp/airgap-dnf.log"
		else
			pass "code rpm installed (with bundled dependencies)"
		fi
	else
		pass "code rpm installed"
	fi
fi

client_commit=""
if command -v code >/dev/null 2>&1; then
	mapfile -t code_info < <(code --version 2>/dev/null)
	client_commit="${code_info[1]:-}"
	info "client: ${code_info[0]:-unknown} / ${client_commit:-unknown} / ${code_info[2]:-}"
	if [ "$client_commit" = "$VSCODE_COMMIT" ]; then
		pass "client commit matches the server commit baked into the image"
	else
		fail "client commit '$client_commit' != baked server commit '$VSCODE_COMMIT' - attach would try to download a server"
	fi
else
	fail "code CLI not found after install"
fi

# ---------------------------------------------------------------------------
step "4/9  Dev Containers extension (VSIX, offline)"
if code --install-extension "$BUNDLE_DIR/$DC_VSIX" --force >/tmp/airgap-vsix.log 2>&1; then
	pass "installed $DC_VSIX"
else
	fail "VSIX install failed - see /tmp/airgap-vsix.log"
fi
if code --list-extensions 2>/dev/null | grep -qx "$DC_EXT_ID"; then
	pass "$DC_EXT_ID is listed by the client"
else
	fail "$DC_EXT_ID not listed after install"
fi

# ---------------------------------------------------------------------------
step "5/9  client settings (podman engine, quiet offline defaults)"
settings_file="$HOME/.config/Code/User/settings.json"
mkdir -p "$(dirname "$settings_file")"
PODMAN_SOCKET="$PODMAN_SOCKET" python3 - "$settings_file" <<'PY'
import json, os, sys

path = sys.argv[1]
overrides = {
    "update.mode": "none",
    "telemetry.telemetryLevel": "off",
    "extensions.autoCheckUpdates": False,
    "extensions.autoUpdate": False,
    "dev.containers.dockerPath": "podman",
    "dev.containers.dockerSocketPath": os.environ.get("PODMAN_SOCKET", ""),
    "dev.containers.logLevel": "debug",
}
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except ValueError:
            data = {}
    os.rename(path, path + ".pre-airgap-test")
data.update({k: v for k, v in overrides.items() if v != ""})
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"settings written: {path}")
PY
if [ -f "$settings_file" ]; then
	pass "settings.json written (previous file backed up as *.pre-airgap-test if it existed)"
	info "dev.containers.dockerPath=podman, dockerSocketPath=$PODMAN_SOCKET"
else
	fail "could not write $settings_file"
fi

# ---------------------------------------------------------------------------
step "6/9  container engine (podman)"
if ! command -v podman >/dev/null 2>&1; then
	info "podman not installed - installing from bundle"
	sudo dnf -y install --disablerepo='*' "$BUNDLE_DIR"/rpms/*.rpm >/tmp/airgap-dnf.log 2>&1 || true
fi
if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
	pass "podman works ($(podman --version))"
else
	fail "podman is not usable"
fi
systemctl --user enable --now podman.socket >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
	[ -S "$PODMAN_SOCKET" ] && break
	sleep 1
done
if [ -S "$PODMAN_SOCKET" ]; then
	pass "rootless podman socket is up at $PODMAN_SOCKET"
else
	warn "podman socket not found at $PODMAN_SOCKET (the extension may still work via the podman CLI)"
fi

# ---------------------------------------------------------------------------
step "7/9  image + baked server content"
podman load -i "$BUNDLE_DIR/$IMAGE_TAR" >/tmp/airgap-load.log 2>&1 || fail "podman load failed - see /tmp/airgap-load.log"
if podman image exists "$IMAGE_TAG"; then
	pass "image '$IMAGE_TAG' loaded"
elif podman image exists "localhost/$IMAGE_TAG"; then
	podman tag "localhost/$IMAGE_TAG" "$IMAGE_TAG" && pass "image '$IMAGE_TAG' loaded (as localhost/$IMAGE_TAG)"
else
	fail "image '$IMAGE_TAG' not present after load"
fi

if podman run --rm "$IMAGE_TAG" bash -lc 'test -e "$HOME"/.vscode-server/bin/*/0'; then
	pass "install marker ~/.vscode-server/bin/<commit>/0 present"
else
	fail "install marker missing in the image"
fi
in_image_version="$(podman run --rm "$IMAGE_TAG" bash -lc '"$HOME"/.vscode-server/bin/*/bin/code-server --version' 2>/dev/null | tr '\n' ' ')"
info "in-image server: $in_image_version"
if printf '%s' "$in_image_version" | grep -q "$VSCODE_COMMIT"; then
	pass "in-image server commit is $VSCODE_COMMIT"
else
	fail "in-image server does not match the expected commit"
fi
if podman run --rm "$IMAGE_TAG" bash -lc 'grep -q "workspace.trust" "$HOME"/.vscode-server/data/Machine/settings.json'; then
	pass "air-gap machine settings are baked in"
else
	warn "Machine settings.json not found where expected"
fi

# ---------------------------------------------------------------------------
step "8/9  start targets"
podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
if podman run -d --name "$CONTAINER_NAME" "$IMAGE_TAG" sleep infinity >/dev/null 2>&1; then
	pass "container '$CONTAINER_NAME' is running (attach target)"
else
	fail "could not start the attach target container"
fi

podman rm -f "$WEB_CONTAINER_NAME" >/dev/null 2>&1 || true
if podman run -d --name "$WEB_CONTAINER_NAME" -p "${WEB_PORT}:8000" "$IMAGE_TAG" vscode-web >/dev/null 2>&1; then
	web_code=""
	for _ in $(seq 1 30); do
		web_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null || true)"
		[ "$web_code" = "200" ] && break
		sleep 1
	done
	if [ "$web_code" = "200" ]; then
		pass "browser UI serves HTTP 200 at http://localhost:${WEB_PORT}/ (open it in Firefox)"
	else
		fail "browser UI did not come up (last HTTP code: '${web_code}')"
	fi
else
	warn "could not start the browser UI container"
fi

# ---------------------------------------------------------------------------
step "9/9  attach from VS Code (manual step)"
cat <<'EOT'
     1. Open VS Code (Activities -> Visual Studio Code, or run: code)
     2. Ctrl+Shift+P -> "Dev Containers: Attach to Running Container..."
     3. Select "agentide-devbox"
     4. Confirm the trust prompt once ("Yes, I trust the authors")
     5. A second VS Code window opens, connected to the container.
        With the server pre-installed this should take a few seconds and
        must not attempt any download.
EOT
read -r -p "     Press Enter once the VS Code window shows it is connected ['s' to skip]: " answer
if [ "${answer:-}" = "s" ]; then
	warn "skipped the manual attach check"
else
	server_args="$(podman exec "$CONTAINER_NAME" sh -lc 'ps -eo args | grep -v grep | grep server-main.js' 2>/dev/null | head -n 1)"
	if [ -z "$server_args" ]; then
		fail "no server-main.js process in the container - did the attach complete?"
	else
		info "server process: $server_args"
		case "$server_args" in
			*"/.vscode-server/bin/${VSCODE_COMMIT}/"*) pass "server runs from the baked path (no download happened)" ;;
			*) fail "server does not run from the baked commit directory" ;;
		esac
	fi
	commits="$(podman exec "$CONTAINER_NAME" sh -lc 'ls "$HOME"/.vscode-server/bin' 2>/dev/null | tr '\n' ' ')"
	if [ "$(printf '%s' "$commits" | tr -d ' ')" = "$VSCODE_COMMIT" ]; then
		pass "~/.vscode-server/bin contains exactly the baked commit ($commits)"
	else
		fail "unexpected contents in ~/.vscode-server/bin: $commits"
	fi
	if podman exec "$CONTAINER_NAME" sh -lc "test -e \"\$HOME/.vscode-server/code-${VSCODE_COMMIT}\"" 2>/dev/null; then
		pass "client wrote its code-<commit> launcher - it found and reused the baked server"
	else
		warn "code-<commit> launcher not found (may vary by client version)"
	fi
	residue="$(podman exec "$CONTAINER_NAME" sh -lc 'find "$HOME/.vscode-server" -maxdepth 2 -name "vscode-server-*.tar.gz" 2>/dev/null' 2>/dev/null)"
	if ! podman exec "$CONTAINER_NAME" true >/dev/null 2>&1; then
		warn "could not inspect the container for downloaded server tarballs"
	elif [ -n "$residue" ]; then
		warn "found a server tarball inside the container - something downloaded despite the bake"
	else
		pass "no downloaded server tarballs inside the container"
	fi
fi

# ---------------------------------------------------------------------------
if [ "$NEGATIVE_CONTROL" = true ]; then
	step "negative control: hide the baked server"
	info "moving ~/.vscode-server/bin/$VSCODE_COMMIT aside inside the container"
	podman exec "$CONTAINER_NAME" sh -lc 'mv "$HOME"/.vscode-server/bin/* "$HOME"/.vscode-server/bin-hidden' 2>/dev/null \
		|| warn "could not hide the server directory"
	cat <<'EOT'
     In the VS Code window: Command Palette -> "Remote: Close Remote Connection"
     (or close the window), then attach again from the main window.
     Expected: the attach now FAILS with a download error - this is proof that
     the baked server (not something cached on the client) is what made the
     first attach work.
EOT
	read -r -p "     Press Enter after observing the failure, to restore the server: " _
	podman exec "$CONTAINER_NAME" sh -lc 'mv "$HOME"/.vscode-server/bin-hidden "$HOME"/.vscode-server/bin-tmp && mkdir -p "$HOME"/.vscode-server/bin && mv "$HOME"/.vscode-server/bin-tmp "$HOME"/.vscode-server/bin/'"$VSCODE_COMMIT" 2>/dev/null \
		|| warn "could not restore automatically - check ~/.vscode-server inside the container"
	info "server restored - attach once more to confirm it succeeds again"
fi

# ---------------------------------------------------------------------------
step "summary"
printf '     PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
info "containers left running: $CONTAINER_NAME (attach target), $WEB_CONTAINER_NAME (http://localhost:$WEB_PORT/)"
info "stop them with: podman rm -f $CONTAINER_NAME $WEB_CONTAINER_NAME"
if [ "$FAIL" -eq 0 ]; then
	printf '\033[1;32m     Air-gap acceptance test passed.\033[0m\n'
else
	printf '\033[1;31m     Air-gap acceptance test has failures - see [FAIL] lines above.\033[0m\n'
	exit 1
fi
