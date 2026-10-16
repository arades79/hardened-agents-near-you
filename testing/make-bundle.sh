#!/usr/bin/env bash
#
# Build an air-gap test bundle for the agent-ide base image.
#
# Run this on a CONNECTED host. It produces a directory (and optionally an ISO)
# containing everything the disconnected Rocky 9 VM needs:
#
#   agent-ide-base.tar     container image (docker-archive, loadable by
#                          podman and docker)
#   code-<v>-<build>.el8.<arch>.rpm
#                          VS Code desktop client, exact commit matching the
#                          server baked into the image
#   ms-vscode-remote.remote-containers-<v>.vsix
#                          Dev Containers extension for the client
#   rpms/                  offline dependencies (podman if missing in the VM,
#                          plus GUI libs the VS Code rpm may need)
#   airgap-test.sh         the in-VM acceptance test
#   RUNBOOK.md             this procedure
#   bundle.env             values the in-VM test uses
#   MANIFEST.sha256        integrity manifest for the transfer
#
# Usage:
#   testing/make-bundle.sh [--out DIR] [--image TAG] [--iso] [--docker] [--arch x64|arm64]
#
set -euo pipefail

OUT="$(pwd)/airgap-bundle"
IMAGE="agent-ide-base:rocky9"
MAKE_ISO=false
WITH_DOCKER=false
ARCH="x64"
UPDATE_BASE="https://update.code.visualstudio.com"
GALLERY_BASE="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode-remote/vsextensions/remote-containers/latest/vspackage"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m[bundle]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bundle] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bundle] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
		--out) OUT="$2"; shift 2 ;;
		--image) IMAGE="$2"; shift 2 ;;
		--arch) ARCH="$2"; shift 2 ;;
		--iso) MAKE_ISO=true; shift ;;
		--docker) WITH_DOCKER=true; shift ;;
		-h | --help) usage ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

case "$ARCH" in
	x64) RPM_ARCH=x86_64 ;;
	arm64) RPM_ARCH=aarch64 ;;
	*) die "--arch must be x64 or arm64" ;;
esac

command -v podman >/dev/null || die "podman not found - build the bundle on a host with podman"
podman image exists "$IMAGE" || die "image '$IMAGE' not found - build it first (see README.md), or pass --image"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute path so paths printed below are usable as-is

# ---------------------------------------------------------------------------
# 1. Read version/commit out of the image itself, so the client rpm always
#    matches the server baked into the image.
# ---------------------------------------------------------------------------
log "reading VS Code version from image '$IMAGE'"
mapfile -t version_info < <(podman run --rm "$IMAGE" bash -lc '"$HOME"/.vscode-server/bin/*/bin/code-server --version')
VSCODE_VERSION="${version_info[0]}"
VSCODE_COMMIT="${version_info[1]}"
[ -n "$VSCODE_VERSION" ] && [ -n "$VSCODE_COMMIT" ] || die "could not read version/commit from the image"
log "image contains VS Code $VSCODE_VERSION (commit $VSCODE_COMMIT)"

# ---------------------------------------------------------------------------
# 2. VS Code desktop client rpm for that exact commit
# ---------------------------------------------------------------------------
log "downloading VS Code $VSCODE_VERSION rpm"
rpm_url="${UPDATE_BASE}/commit:${VSCODE_COMMIT}/linux-rpm-${ARCH}/stable"
rpm_final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$rpm_url")" || die "could not resolve rpm url: $rpm_url"
RPM_FILE="$(basename "$rpm_final")"
curl -fsSL --retry 5 -o "$OUT/$RPM_FILE" "$rpm_url" || die "rpm download failed"
log "  $RPM_FILE"

# ---------------------------------------------------------------------------
# 3. Dev Containers extension as VSIX
# ---------------------------------------------------------------------------
log "downloading Dev Containers extension (VSIX)"
vsix_tmp="$OUT/.devcontainers.vsix.tmp"
curl -fsSL --compressed -o "$vsix_tmp" "$GALLERY_BASE" || die "vsix download failed"
vsix_version="$(python3 - "$vsix_tmp" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(json.loads(z.read("extension/package.json"))["version"])
PY
)" || die "downloaded VSIX is not a valid extension package"
VSIX_FILE="ms-vscode-remote.remote-containers-${vsix_version}.vsix"
mv "$vsix_tmp" "$OUT/$VSIX_FILE"
log "  $VSIX_FILE"

# ---------------------------------------------------------------------------
# 4. Offline dependencies: podman (if the VM lacks it) and the GUI libs the
#    VS Code rpm may need. Resolved with a throwaway rockylinux:9 container.
# ---------------------------------------------------------------------------
log "downloading offline rpm dependencies into rpms/"
mkdir -p "$OUT/rpms"
podman run --rm -u root -v "$OUT:/bundle:z" rockylinux:9 bash -lc "
	set -e
	dnf -y install --downloadonly --destdir /bundle/rpms --setopt=install_weak_deps=false podman
	dnf -y install --downloadonly --destdir /bundle/rpms --setopt=install_weak_deps=false '/bundle/${RPM_FILE}'
" || warn "dependency download failed - the in-VM rpm install may need manual handling"

if [ "$WITH_DOCKER" = "true" ]; then
	log "downloading Docker CE rpms into rpms-docker/ (plan B)"
	mkdir -p "$OUT/rpms-docker"
	podman run --rm -u root -v "$OUT:/bundle:z" rockylinux:9 bash -lc "
		set -e
		curl -fsSLo /etc/yum.repos.d/docker-ce.repo https://download.docker.com/linux/centos/docker-ce.repo
		dnf -y install --downloadonly --destdir /bundle/rpms-docker --setopt=install_weak_deps=false \
			docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	" || warn "Docker CE download failed - plan B will not be available"
fi

# ---------------------------------------------------------------------------
# 5. The image itself
# ---------------------------------------------------------------------------
log "saving image to agent-ide-base.tar (this takes a minute)"
podman save --format docker-archive -o "$OUT/agent-ide-base.tar" "$IMAGE"

# ---------------------------------------------------------------------------
# 6. Test script, runbook, metadata, manifest
# ---------------------------------------------------------------------------
cp "$REPO_DIR/testing/airgap-test.sh" "$OUT/airgap-test.sh"
cp "$REPO_DIR/testing/README.md" "$OUT/RUNBOOK.md"
chmod +x "$OUT/airgap-test.sh"

cat > "$OUT/bundle.env" <<ENV
# Generated by testing/make-bundle.sh - consumed by airgap-test.sh
IMAGE_TAG=$IMAGE
IMAGE_TAR=agent-ide-base.tar
VSCODE_VERSION=$VSCODE_VERSION
VSCODE_COMMIT=$VSCODE_COMMIT
VSCODE_RPM=$RPM_FILE
DC_VSIX=$VSIX_FILE
DC_EXT_ID=ms-vscode-remote.remote-containers
ENV

log "writing MANIFEST.sha256"
(
	cd "$OUT"
	sha256sum agent-ide-base.tar "$RPM_FILE" "$VSIX_FILE" airgap-test.sh bundle.env RUNBOOK.md > MANIFEST.sha256
	if ls rpms/*.rpm >/dev/null 2>&1; then sha256sum rpms/*.rpm >> MANIFEST.sha256; fi
	if ls rpms-docker/*.rpm >/dev/null 2>&1; then sha256sum rpms-docker/*.rpm >> MANIFEST.sha256; fi
)

# ---------------------------------------------------------------------------
# 7. Optional transfer ISO
# ---------------------------------------------------------------------------
if [ "$MAKE_ISO" = "true" ]; then
	command -v xorriso >/dev/null || die "--iso requested but xorriso not found (dnf install xorriso)"
	iso_path="$(dirname "$OUT")/agentide-bundle.iso"
	log "building transfer ISO: $iso_path"
	xorriso -as mkisofs -quiet -J -R -V AIRGAPBUNDLE -o "$iso_path" "$OUT"
	log "transfer ISO ready: $iso_path ($(du -h "$iso_path" | cut -f1))"
fi

log "bundle at: $OUT"
du -h "$OUT"/* 2>/dev/null | sort -h | sed 's/^/  /'

cat <<EOF

Next steps (RUNBOOK.md in the bundle has the full procedure):

  1. shut the VM down, then attach the bundle ISO and boot it:
       virsh domblklist <vm>    # find the current cdrom target, e.g. sda
       virsh change-media <vm> sda --eject --config
       virsh attach-disk <vm> "$(dirname "$OUT")/agentide-bundle.iso" sdc --type cdrom --mode readonly --targetbus sata --config
  2. disconnect the VM's network:
       virsh domiflist <vm>     # note the MAC address
       virsh detach-interface <vm> --type network --mac <MAC> --live --config
  3. inside the VM, as your desktop user:
       sudo mount -o ro /dev/disk/by-label/AIRGAPBUNDLE /mnt
       cp -r /mnt/. \$HOME/airgap-bundle && chmod -R u+w \$HOME/airgap-bundle
       bash \$HOME/airgap-bundle/airgap-test.sh

EOF
