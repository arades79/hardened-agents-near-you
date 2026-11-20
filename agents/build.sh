#!/usr/bin/env bash
#
# Build the agent-bundle images in agents/.
#
# Usage:
#   agents/build.sh [--base-image TAG] [--tag-suffix SUFFIX] [--tool podman|docker]
#                   [agent ...] [-- extra build args...]
#
# Examples:
#   agents/build.sh                       # all four bundles, agent-ide-base:rocky9
#   agents/build.sh opencode goose        # only those two
#   agents/build.sh --tag-suffix 1.142    # agent-ide-opencode:1.142 etc.
#   agents/build.sh pi -- --build-arg PI_VERSION=1.4.0
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_AGENTS=(opencode pi goose vscode-agent)
BASE_IMAGE="agent-ide-base:rocky9"
TAG_SUFFIX="rocky9"
TOOL=""
AGENTS=()
EXTRA_ARGS=()

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
		--base-image) BASE_IMAGE="$2"; shift 2 ;;
		--tag-suffix) TAG_SUFFIX="$2"; shift 2 ;;
		--tool) TOOL="$2"; shift 2 ;;
		--help | -h) usage ;;
		--)
			shift
			EXTRA_ARGS=("$@")
			break
			;;
		-*) die "unknown argument: $1 (try --help)" ;;
		*) AGENTS+=("$1"); shift ;;
	esac
done

if [ "${#AGENTS[@]}" -eq 0 ]; then
	AGENTS=("${ALL_AGENTS[@]}")
fi

for agent in "${AGENTS[@]}"; do
	found=false
	for known in "${ALL_AGENTS[@]}"; do
		[ "$agent" = "$known" ] && found=true
	done
	[ "$found" = "true" ] || die "unknown agent '$agent' (known: ${ALL_AGENTS[*]})"
done

if [ -z "$TOOL" ]; then
	if command -v podman > /dev/null; then
		TOOL=podman
	elif command -v docker > /dev/null; then
		TOOL=docker
	else
		die "neither podman nor docker found"
	fi
fi
command -v "$TOOL" > /dev/null || die "$TOOL not found"

"$TOOL" image exists "$BASE_IMAGE" ||
	die "base image '$BASE_IMAGE' not found - build it first: $TOOL build -t $BASE_IMAGE $REPO_DIR"

for agent in "${AGENTS[@]}"; do
	tag="agent-ide-${agent}:${TAG_SUFFIX}"
	log "building $tag from agents/${agent}/Dockerfile"
	"$TOOL" build \
		-f "$REPO_DIR/agents/${agent}/Dockerfile" \
		--build-arg "BASE_IMAGE=${BASE_IMAGE}" \
		"${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
		-t "$tag" \
		"$REPO_DIR"
	log "built $tag"
done

cat <<EOF

Built: $(for agent in "${AGENTS[@]}"; do printf '%s ' "agent-ide-${agent}:${TAG_SUFFIX}"; done)

Run one, then attach VS Code (Dev Containers: Attach to Running Container...):

  $TOOL run -d --name agent-devbox \\
    -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \\
    -e OPENAI_API_KEY=sk-your-key \\
    -e OPENAI_MODEL=your-model \\
    agent-ide-${AGENTS[0]}:${TAG_SUFFIX} sleep infinity

Details, including air-gap transfer and per-agent config paths, are in
agents/README.md.
EOF
