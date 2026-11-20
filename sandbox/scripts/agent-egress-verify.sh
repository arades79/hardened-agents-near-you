#!/usr/bin/env bash
# =============================================================================
# agent-ide - prove that the egress policy is in the packet path
# =============================================================================
# Run this after installing the policy, after changing the allowlist, after
# rebooting, and as part of the air-gap acceptance test (see testing/README.md).
#
# The test is behavioural, from inside a container on the target network:
#
#   * a public destination must NOT be reachable (TCP and ICMP)
#   * the cloud metadata endpoint must NOT be reachable
#   * the network's own gateway MUST be reachable (a working network is what
#     makes "blocked" meaningful rather than "there was no network")
#   * the deny counter must have increased (the policy, not something else,
#     is what blocked the traffic)
#   * the configured LAN target MUST be reachable (the allowlist still works)
#
# Usage:
#   agent-egress-verify.sh [--network agent-lan] [--image IMG]
#                          [--public 1.1.1.1] [--lan-target HOST[:PORT]] [--keep]
#
# --lan-target is what turns this from "public is blocked" into "public is
# blocked AND my NFS server / model gateway is still reachable". Point it at a
# service you know responds (e.g. <nfs-server>:2049 or <gateway>:8080).
#
# Exit codes: 0 pass, 1 fail, 3 prerequisite missing, 5 policy not installed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

TABLE=agent_egress
TOOL="${PODMAN:-podman}"
CONF="${AGENT_EGRESS_CONF:-$SANDBOX_DIR/config/agent-egress.conf}"

NETWORK="${AGENT_VERIFY_NETWORK:-}"
IMAGE="${AGENT_VERIFY_IMAGE:-agent-ide-base:rocky9}"
PUBLIC="${AGENT_VERIFY_PUBLIC:-1.1.1.1}"
LAN_TARGET=""
LAN_PORT=""
KEEP=0

usage() {
	cat << 'EOF'
agent-egress-verify.sh - behavioural check of the container egress policy

  --network NAME       podman network to test on (default: agent-lan if it
                       exists, else the default "podman" network)
  --image IMAGE        image for the probe container (default agent-ide-base:rocky9)
  --public IP          public destination that must be blocked (default 1.1.1.1)
  --lan-target H[:P]   LAN destination that must stay reachable (H = hostname/IP;
                       optional port for a TCP check, e.g. 10.0.0.5:2049)
  --keep               keep the probe container for inspection
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--network) NETWORK="${2:?}"; shift 2 ;;
		--image) IMAGE="${2:?}"; shift 2 ;;
		--public) PUBLIC="${2:?}"; shift 2 ;;
		--lan-target)
			LAN_TARGET="${2:?}"
			case "$LAN_TARGET" in
				*:*) LAN_PORT="${LAN_TARGET##*:}"; LAN_TARGET="${LAN_TARGET%%:*}" ;;
			esac
			shift 2
			;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "agent-egress-verify: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# shellcheck source=agent-egress-lib.sh
. "$SCRIPT_DIR/agent-egress-lib.sh"

echo "namespace: $(ns_mode)"

# ------------------------------------------------- 0. is the policy installed?
if ! policy_present; then
	echo
	echo "FAIL: the egress policy is not loaded in the $(ns_mode) namespace." >&2
	echo "      Container egress is UNPOLICED. Install it first:" >&2
	echo "        $SCRIPT_DIR/agent-egress-apply.sh" >&2
	exit 5
fi

if [ -z "$NETWORK" ]; then
	if "$TOOL" network exists agent-lan > /dev/null 2>&1; then
		NETWORK=agent-lan
	else
		NETWORK=podman
	fi
fi
"$TOOL" network exists "$NETWORK" > /dev/null 2>&1 || {
	echo "FAIL: no such podman network: $NETWORK" >&2
	exit 3
}

NETIF="$("$TOOL" network inspect "$NETWORK" --format '{{.NetworkInterface}}')"
COVERED=0
for iface in $(agent_network_ifaces); do
	[ "$iface" = "$NETIF" ] && COVERED=1
done
if [ "$COVERED" -ne 1 ]; then
	echo "FAIL: network $NETWORK ($NETIF) is not covered by the policy scope." >&2
	echo "      Selected networks: $(agent_networks)" >&2
	echo "      Fix sandbox/config/agent-egress.conf (or --exclude/--networks)" >&2
	echo "      and re-run agent-egress-apply.sh." >&2
	exit 5
fi

"$TOOL" image exists "$IMAGE" > /dev/null 2>&1 || {
	echo "FAIL: probe image $IMAGE is not present locally." >&2
	echo "      Load it first (air-gapped: podman load -i <archive>) or pass --image." >&2
	exit 3
}

GATEWAY="$("$TOOL" network inspect "$NETWORK" --format '{{range .Subnets}}{{.Gateway}} {{end}}' | awk '{print $1}')"
[ -n "$GATEWAY" ] || {
	echo "FAIL: could not determine the gateway of $NETWORK" >&2
	exit 3
}

# ----------------------------------------------------------------- probe
read -r -d '' PROBE << 'PROBE' || true
set -u

tcp_probe() { # host port -> ok|blocked|skipped
	# A dropped SYN does not fail fast, it hangs until the kernel gives up, so
	# every attempt has to be bounded by `timeout`.
	if command -v bash > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1; then
		if timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null; then echo ok; else echo blocked; fi
	elif command -v curl > /dev/null 2>&1; then
		if curl -sS -o /dev/null --connect-timeout 3 --max-time 5 "http://$1:$2/"; then echo ok; else echo blocked; fi
	elif command -v wget > /dev/null 2>&1; then
		if wget -T3 -q -O /dev/null "http://$1:$2/"; then echo ok; else echo blocked; fi
	else
		echo skipped
	fi
}

icmp_probe() { # host -> ok|blocked|skipped
	if command -v ping > /dev/null 2>&1; then
		if ping -c1 -W2 "$1" > /dev/null 2>&1; then echo ok; else echo blocked; fi
	else
		echo skipped
	fi
}

dns_probe() { # name -> ok|blocked|skipped
	if command -v getent > /dev/null 2>&1; then
		if getent hosts "$1" > /dev/null 2>&1; then echo ok; else echo blocked; fi
	else
		echo skipped
	fi
}

echo "public_tcp=$(tcp_probe "$1" 80)"
echo "public_icmp=$(icmp_probe "$1")"
echo "metadata_tcp=$(tcp_probe 169.254.169.254 80)"
echo "gateway_icmp=$(icmp_probe "$4")"
if [ -n "$2" ]; then
	if [ -n "$3" ]; then
		echo "lan_tcp=$(tcp_probe "$2" "$3")"
	else
		echo "lan_icmp=$(icmp_probe "$2")"
	fi
else
	echo "lan_test=skipped"
fi
echo "dns_external=$(dns_probe example.com)"
PROBE

BEFORE="$(drop_counter)"

VERIFY_TIMEOUT="${AGENT_VERIFY_TIMEOUT:-180}"
echo "probing network $NETWORK (gateway $GATEWAY, image $IMAGE)"
# --user 0: ping in this container only works for gid 0. Podman's default capability
# set has no NET_RAW and sets net.ipv4.ping_group_range="0 0", and
# --security-opt no-new-privileges blocks the file capabilities iputils would
# otherwise fall back on. Run as the image's default user, the probe reports a
# reachable gateway as "blocked".
RUN_ARGS=(run --name agent-egress-probe --user 0 --network "$NETWORK" --security-opt no-new-privileges)
set +e
OUT="$(timeout "$VERIFY_TIMEOUT" "$TOOL" "${RUN_ARGS[@]}" "$IMAGE" sh -c "$PROBE" agent-egress-probe \
	"$PUBLIC" "$LAN_TARGET" "$LAN_PORT" "$GATEWAY" 2>&1)"
RUN_RC=$?
set -e
if [ "$KEEP" -eq 0 ]; then
	"$TOOL" rm -f agent-egress-probe > /dev/null 2>&1 || true
else
	echo "probe container kept: $(podman ps -q -f name=agent-egress-probe > /dev/null 2>&1 && echo yes || echo no)"
fi

printf '%s\n' "$OUT" | sed 's/^/  /'

if [ "$RUN_RC" -eq 124 ]; then
	echo >&2
	echo "FAIL: the probe did not finish within ${VERIFY_TIMEOUT}s - inconclusive." >&2
	echo "      (a container that hangs instead of failing usually means a probe" >&2
	echo "      without a timeout, or a blocked SYN being retried.)" >&2
	exit 1
fi
if [ -z "$OUT" ]; then
	echo >&2
	echo "FAIL: the probe produced no output - inconclusive (image without a usable" >&2
	echo "      shell, or the container did not start; try --image with another image)." >&2
	exit 1
fi

AFTER="$(drop_counter)"
DELTA=$((AFTER - BEFORE))

get() { printf '%s\n' "$OUT" | awk -F= -v k="$1" '$1 == k { print $2; exit }'; }

PUB_TCP="$(get public_tcp)"
PUB_ICMP="$(get public_icmp)"
META="$(get metadata_tcp)"
GW="$(get gateway_icmp)"
LAN_TCP="$(get lan_tcp)"
LAN_ICMP="$(get lan_icmp)"
LAN_TEST="$(get lan_test)"
DNS="$(get dns_external)"

FAILED=0
ok() { printf '  PASS  %s\n' "$1"; }
bad() {
	printf '  FAIL  %s\n' "$1"
	FAILED=1
}
warn() { printf '  WARN  %s\n' "$1"; }

echo
echo "results"
[ "$PUB_TCP" = blocked ] && ok "public TCP $PUBLIC:80 blocked" || bad "public TCP $PUBLIC:80 is $PUB_TCP"
case "$PUB_ICMP" in
	blocked) ok "public ICMP $PUBLIC blocked" ;;
	skipped) warn "public ICMP not tested (no ping in the image)" ;;
	*) bad "public ICMP is $PUB_ICMP" ;;
esac
[ "$META" = blocked ] && ok "cloud metadata 169.254.169.254 blocked" || bad "cloud metadata is $META"
case "$GW" in
	ok) ok "gateway $GATEWAY reachable (container really has a working network)" ;;
	skipped) warn "gateway not tested (no ping in the image) - 'blocked' results are inconclusive without it" ;;
	*) bad "gateway $GATEWAY is $GW - the container has no working network, results are inconclusive" ;;
esac
case "$LAN_TEST" in
	ok) ok "lan_target=$LAN_TARGET${LAN_PORT:+:$LAN_PORT} reachable (allowlist works)" ;;
	blocked) bad "lan_target=$LAN_TARGET${LAN_PORT:+:$LAN_PORT} is blocked - check lan4 in the policy" ;;
	skipped) ;;
esac
case "$LAN_TCP" in
	ok) ok "LAN TCP $LAN_TARGET:$LAN_PORT reachable (allowlist works)" ;;
	blocked) bad "LAN TCP $LAN_TARGET:$LAN_PORT is blocked - check lan4 in the policy" ;;
	"") ;;
	*) warn "LAN TCP test: $LAN_TCP" ;;
esac
case "$LAN_ICMP" in
	ok) ok "LAN ICMP $LAN_TARGET reachable (allowlist works)" ;;
	blocked) bad "LAN ICMP $LAN_TARGET is blocked - check lan4 in the policy" ;;
	"") ;;
	*) warn "LAN ICMP test: $LAN_ICMP" ;;
esac
if [ "$DELTA" -gt 0 ]; then
	ok "deny counter increased by $DELTA (the policy is what blocked the probes)"
else
	bad "deny counter did not move - the policy may not be in the packet path"
fi
case "$DNS" in
	ok) warn "external DNS still resolves (expected: aardvark-dns forwards to the host's resolvers; see README 'Residual channels')" ;;
	blocked) ok "external DNS does not resolve" ;;
	*) warn "external DNS test: $DNS" ;;
esac

if [ -z "$LAN_TARGET" ]; then
	echo
	warn "no --lan-target given: the positive half of the allowlist was not tested."
	warn "Re-run with --lan-target <nfs-server>:2049 (or your model gateway) to prove more than 'public is blocked'."
fi

# ------------------------------------------------------------ container audit
echo
echo "container audit (anything not on a policed bridge network is NOT filtered)"
COVERED=" $(agent_networks | tr '\n' ' ') "
for cid in $("$TOOL" ps -q 2> /dev/null); do
	cname="$("$TOOL" inspect -f '{{.Name}}' "$cid" 2> /dev/null || echo '?')"
	cmode="$("$TOOL" inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2> /dev/null || echo '?')"
	case "$COVERED" in
		*" $cmode "*) ok "container $cname is on policed network $cmode" ;;
		none) ok "container $cname has no network at all (--network none)" ;;
		*) warn "container $cname runs with NetworkMode=$cmode - not covered by the policy" ;;
	esac
done

echo
if [ "$FAILED" -eq 0 ]; then
	echo "PASS - egress policy is enforced on network $NETWORK"
	exit 0
fi
echo "FAIL - see the lines above" >&2
exit 1
