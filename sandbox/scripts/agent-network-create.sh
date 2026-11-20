#!/usr/bin/env bash
# =============================================================================
# agent-ide - create the podman network(s) used by the agent sandbox
# =============================================================================
#   agent-lan        a normal bridge network. It is NOT isolated by itself: the
#                    public-IP denial comes from sandbox/nftables/agent-egress.nft
#                    (see sandbox/scripts/agent-egress-apply.sh).
#   agent-internal   created with --internal: no default route, no address
#                    translation, no reachability off the host at all. Use this
#                    (plus a bind-mounted NFS share) when the workload does not
#                    need the LAN - it is the only tier that cannot fail open.
#
# Usage:
#   agent-network-create.sh [--with-internal] [--name agent-lan]
#                           [--subnet 10.89.240.0/24] [--dns 10.0.0.53]
#
# Environment defaults: LAN_NAME, LAN_SUBNET, LAN_DNS, INTERNAL_NAME,
# INTERNAL_SUBNET, PODMAN.
#
# Notes
#   * Subnets must not overlap the LAN that carries your NFS share / model
#     gateway, or the containers' own addresses and the allowlist will collide.
#   * --dns pins the containers to an internal resolver instead of the host's
#     resolvers. External names then have to be resolvable by that resolver.
#   * --opt isolate=true stops containers on this network from talking to
#     containers on other networks that also set isolate.
# =============================================================================
set -euo pipefail

TOOL="${PODMAN:-podman}"
LAN_NAME="${LAN_NAME:-agent-lan}"
LAN_SUBNET="${LAN_SUBNET:-10.89.240.0/24}"
LAN_DNS="${LAN_DNS:-}"
INTERNAL_NAME="${INTERNAL_NAME:-agent-internal}"
INTERNAL_SUBNET="${INTERNAL_SUBNET:-10.89.241.0/24}"
WITH_INTERNAL=0

usage() {
	cat << 'EOF'
agent-network-create.sh - create agent-lan (LAN reachable, public IPs denied
by the nftables policy) and optionally agent-internal (no egress at all).

  --with-internal        also create the fully isolated network
  --name NAME            bridge network name (default agent-lan)
  --subnet CIDR          subnet for the bridge network (default 10.89.240.0/24)
  --dns IP               resolver the containers should use (default: host's)
  --internal-name NAME   name of the isolated network (default agent-internal)
  --internal-subnet CIDR subnet of the isolated network (default 10.89.241.0/24)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--with-internal) WITH_INTERNAL=1; shift ;;
		--name) LAN_NAME="${2:?}"; shift 2 ;;
		--subnet) LAN_SUBNET="${2:?}"; shift 2 ;;
		--dns) LAN_DNS="${2:?}"; shift 2 ;;
		--internal-name) INTERNAL_NAME="${2:?}"; shift 2 ;;
		--internal-subnet) INTERNAL_SUBNET="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "agent-network-create: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

command -v "$TOOL" > /dev/null 2>&1 || {
	echo "agent-network-create: $TOOL not found" >&2
	exit 2
}

create_network() {
	name="$1"
	shift
	if "$TOOL" network exists "$name" > /dev/null 2>&1; then
		echo "network $name already exists - leaving it alone"
		return 0
	fi
	echo "+ $TOOL network create $* $name"
	"$TOOL" network create "$@" "$name"
}

# Bridge network: LAN reachable, public address space denied by the nftables
# policy. IPv6 is off by default so the policy has a single address family to
# reason about; the ruleset drops IPv6 from agent bridges anyway.
if [ -n "$LAN_DNS" ]; then
	create_network "$LAN_NAME" \
		--subnet "$LAN_SUBNET" --ipv6=false --opt isolate=true \
		--dns "$LAN_DNS" --label agent-ide.sandbox=lan
else
	create_network "$LAN_NAME" \
		--subnet "$LAN_SUBNET" --ipv6=false --opt isolate=true \
		--label agent-ide.sandbox=lan
fi

if [ "$WITH_INTERNAL" -eq 1 ]; then
	create_network "$INTERNAL_NAME" \
		--internal --subnet "$INTERNAL_SUBNET" --ipv6=false \
		--opt isolate=true --label agent-ide.sandbox=internal
fi

echo
echo "network state:"
for n in "$LAN_NAME"; do
	"$TOOL" network inspect "$n" --format '  {{.Name}}: iface={{.NetworkInterface}} internal={{.Internal}} ipv6={{.IPv6Enabled}} subnet={{range .Subnets}}{{.Subnet}} gw={{.Gateway}}{{end}}'
done
if [ "$WITH_INTERNAL" -eq 1 ]; then
	"$TOOL" network inspect "$INTERNAL_NAME" --format '  {{.Name}}: iface={{.NetworkInterface}} internal={{.Internal}} ipv6={{.IPv6Enabled}} subnet={{range .Subnets}}{{.Subnet}} gw={{.Gateway}}{{end}}'
fi

cat << EOF

next steps
  1. sandbox/scripts/agent-egress-apply.sh          # install the deny policy
  2. run agents on the network:
       $TOOL run -d --name agent-devbox --network $LAN_NAME \\
         -e OPENAI_BASE_URL=http://gateway.internal:8080/v1 \\
         agent-ide-opencode:rocky9 sleep infinity
     (or add --network $LAN_NAME to the devcontainer "runArgs")
  3. sandbox/scripts/agent-egress-verify.sh --network $LAN_NAME \\
       --lan-target <nfs-server-ip>:2049
EOF
