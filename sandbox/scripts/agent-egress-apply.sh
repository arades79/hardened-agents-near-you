#!/usr/bin/env bash
# =============================================================================
# agent-ide - load (or remove) the default-deny egress policy
# =============================================================================
# Installs sandbox/nftables/agent-egress.nft in whichever network namespace
# forwards this host's container traffic (podman's rootless netns for rootless
# podman, the host netns for rootful podman / Docker), with the bridge
# interfaces and subnets of the selected networks added in the same
# transaction.
#
# Usage:
#   agent-egress-apply.sh [options]
#
#   --mode auto|rootless|host   namespace to install into (default: auto)
#   --networks all|"n1 n2"      networks to police (default: site config)
#   --exclude "n3"              networks to leave alone (default: site config)
#   --policy FILE               ruleset to install
#                               (default: sandbox/nftables/agent-egress.nft)
#   --conf FILE                 site config (default: sandbox/config/agent-egress.conf)
#   --hold                      keep the rootless netns referenced after
#                               installing (stays in the foreground and runs
#                               `sleep infinity` inside the netns). Used by
#                               agent-egress-keeper.service so podman cannot
#                               tear the netns - and the policy - down.
#   --check                     report whether the policy is loaded; no changes
#   --flush                     remove the policy
#   --dry-run                   print what would be loaded
#   -h | --help
#
# Exit codes: 0 ok, 2 usage/config error, 3 discovery, 4 install failed,
#             5 verification failed (policy is NOT in place - treat container
#             egress as unpoliced).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

POLICY="${AGENT_EGRESS_POLICY:-$SANDBOX_DIR/nftables/agent-egress.nft}"
CONF="${AGENT_EGRESS_CONF:-$SANDBOX_DIR/config/agent-egress.conf}"

TABLE=agent_egress
TOOL="${PODMAN:-podman}"

MODE=auto
HOLD=0
CHECK=0
FLUSH=0
DRY_RUN=0
NETWORKS=""
EXCLUDE=""

usage() {
	cat << 'EOF'
agent-egress-apply.sh - install the agent-ide default-deny egress policy

  --mode auto|rootless|host   namespace to install into (default: auto)
  --networks all|"n1 n2"      podman networks to police (default: site config)
  --exclude "n3 n4"           networks to leave unpoliced (site config)
  --policy FILE               ruleset file (sandbox/nftables/agent-egress.nft)
  --conf FILE                 site config (sandbox/config/agent-egress.conf)
  --hold                      keep the rootless netns referenced (keeper unit)
  --check                     report state, change nothing
  --flush                     remove the policy
  --dry-run                   show the ruleset that would be loaded

Exit codes: 0 ok, 2 usage, 3 discovery, 4 install, 5 verification.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
		--networks) NETWORKS="${2:?--networks needs a value}"; shift 2 ;;
		--exclude) EXCLUDE="${2:?--exclude needs a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy needs a value}"; shift 2 ;;
		--conf) CONF="${2:?--conf needs a value}"; shift 2 ;;
		--hold) HOLD=1; shift ;;
		--check) CHECK=1; shift ;;
		--flush) FLUSH=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "agent-egress-apply: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# shellcheck source=agent-egress-lib.sh
. "$SCRIPT_DIR/agent-egress-lib.sh"

# Scope precedence: command line > site config > default (all bridges).
CLI_NETWORKS="$NETWORKS"
CLI_EXCLUDE="$EXCLUDE"
if [ -r "$CONF" ]; then
	# shellcheck disable=SC1090
	. "$CONF"
fi
: "${CLI_NETWORKS:=${AGENT_NETWORKS:-all}}"
: "${CLI_EXCLUDE:=${AGENT_NETWORK_EXCLUDE:-}}"
NETWORKS="$CLI_NETWORKS"
EXCLUDE="$CLI_EXCLUDE"
# The library reads these when it enumerates networks.
AGENT_NETWORKS="$NETWORKS"
AGENT_NETWORK_EXCLUDE="$EXCLUDE"

case "$MODE" in
	auto) MODE="$(ns_mode)" ;;
	rootless | host) ;;
	*) echo "agent-egress-apply: --mode must be auto, rootless or host" >&2; exit 2 ;;
esac

# ------------------------------------------------------------------ --check
if [ "$CHECK" -eq 1 ]; then
	echo "mode:        $MODE"
	echo "policy file: $POLICY"
	if policy_present; then
		echo "state:       policy loaded (drop counter: $(drop_counter) packets)"
		ns_run nft list set inet "$TABLE" agent_bridges 2> /dev/null || true
		exit 0
	fi
	echo "state:       POLICY NOT LOADED - container egress is unpoliced" >&2
	exit 5
fi

# ------------------------------------------------------------------ --flush
if [ "$FLUSH" -eq 1 ]; then
	if policy_present; then
		ns_run nft delete table inet "$TABLE" || {
			echo "agent-egress-apply: could not remove the policy" >&2
			exit 4
		}
		echo "removed egress policy from the $MODE namespace"
	else
		echo "no egress policy to remove"
	fi
	exit 0
fi

[ -r "$POLICY" ] || {
	echo "agent-egress-apply: cannot read policy file: $POLICY" >&2
	exit 2
}

# ------------------------------------------------------- discover + build
SELECTED="$(agent_networks)"
if [ -z "$SELECTED" ]; then
	echo "agent-egress-apply: no bridge networks selected (nothing to police)" >&2
	exit 3
fi

BRIDGES=""
SUBNETS4=""
SUBNETS6=""
echo "selected networks (mode: $MODE):"
for net in $SELECTED; do
	iface="$("$TOOL" network inspect "$net" --format '{{.NetworkInterface}}' 2> /dev/null || true)"
	[ -n "$iface" ] || continue
	subs="$("$TOOL" network inspect "$net" --format '{{range .Subnets}}{{.Subnet}} {{end}}' 2> /dev/null || true)"
	BRIDGES="${BRIDGES}${BRIDGES:+, }\"$iface\""
	for s in $subs; do
		case "$s" in
			*:*) SUBNETS6="${SUBNETS6}${SUBNETS6:+, }$s" ;;
			*) SUBNETS4="${SUBNETS4}${SUBNETS4:+, }$s" ;;
		esac
	done
	printf '  %-24s %-10s %s\n' "$net" "$iface" "$subs"
done

if [ -z "$BRIDGES" ]; then
	echo "agent-egress-apply: selected networks have no bridges" >&2
	exit 3
fi

ELEMENTS="flush set inet $TABLE agent_bridges
flush set inet $TABLE agent_subnets4
flush set inet $TABLE agent_subnets6
add element inet $TABLE agent_bridges { $BRIDGES }
"
if [ -n "$SUBNETS4" ]; then
	ELEMENTS="${ELEMENTS}add element inet $TABLE agent_subnets4 { $SUBNETS4 }
"
fi
if [ -n "$SUBNETS6" ]; then
	ELEMENTS="${ELEMENTS}add element inet $TABLE agent_subnets6 { $SUBNETS6 }
"
fi

POLICY_TEXT="$(cat "$POLICY")"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "--- $POLICY"
	printf '%s\n' "$POLICY_TEXT"
	echo "--- generated network data"
	printf '%s' "$ELEMENTS"
	exit 0
fi

# ------------------------------------------------------------------ install
# The policy and the discovered network data are fed to nft over stdin. Do not
# replace this with `nft -f <file>`: inside podman's rootless netns, nft runs in
# a confined SELinux domain that cannot necessarily open a file in your home
# directory, and the failure is silent (see sandbox/README.md).
#
# The read-back check runs inside the same invocation as the install, so an
# install failure is always visible even when `podman unshare` swallows the
# child's error output.
install_rootless() {
	_hold="$1"
	"$TOOL" unshare --rootless-netns sh -c '
		printf "%s\n" "$1" | nft -f - || { echo "agent-egress-apply: nft rejected the policy" >&2; exit 4; }
		printf "%s" "$2" | nft -f - || { echo "agent-egress-apply: nft rejected the network data" >&2; exit 4; }
		nft list chain inet '"$TABLE"' forward 2>/dev/null | grep -q "iifname @agent_bridges" || { echo "agent-egress-apply: policy chain missing after install" >&2; exit 5; }
		if [ "$3" = 1 ]; then
			echo "agent-egress-apply: policy loaded, holding the rootless netns open (--hold)" >&2
			exec sleep infinity
		fi
	' agent-egress-apply "$POLICY_TEXT" "$ELEMENTS" "$_hold"
}

install_host() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "agent-egress-apply: mode host needs root (or run as the rootless user)" >&2
		exit 2
	fi
	nft -f - <<< "$POLICY_TEXT" || {
		echo "agent-egress-apply: nft rejected the policy" >&2
		exit 4
	}
	printf '%s' "$ELEMENTS" | nft -f - || {
		echo "agent-egress-apply: nft rejected the network data" >&2
		exit 4
	}
	if [ "$_hold" -eq 1 ]; then
		echo "agent-egress-apply: --hold only applies to rootless mode" >&2
	fi
}

RC=0
if [ "$MODE" = rootless ]; then
	install_rootless "$HOLD" || RC=$?
else
	install_host || RC=$?
fi
if [ "$RC" -ne 0 ]; then
	echo "agent-egress-apply: install failed (exit $RC)." >&2
	echo "  Hint: run '$0 --dry-run' and check that nft accepts the ruleset on this host." >&2
	exit "$RC"
fi

# ------------------------------------------------------- verify by read-back
# A silent no-op is the documented failure mode here, so never report success
# without reading the state back out of the kernel.
if ! policy_present; then
	cat >&2 << 'HINT'
agent-egress-apply: FAILED - the policy did not survive the install command.

With rootless podman the rules live in podman's *rootless network namespace*,
and podman destroys that namespace as soon as nothing references it - taking
the rules with it before the next container starts (fail-open).

Keep the namespace (and the policy) alive with the keeper service:
    cp sandbox/systemd/agent-egress-keeper.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now agent-egress-keeper.service
    sandbox/scripts/agent-egress-apply.sh --check

While a container on a policed bridge is running, the namespace also stays
alive, which is why the policy survives normal agent sessions.
HINT
	exit 5
fi

CHAIN="$(ns_run nft list chain inet "$TABLE" forward 2> /dev/null || true)"
case "$CHAIN" in
	*iifname\ @agent_bridges*) ;;
	*)
		echo "agent-egress-apply: FAILED - forward chain does not reference agent_bridges" >&2
		echo "$CHAIN" >&2
		exit 5
		;;
esac

SETS="$(ns_run nft list set inet "$TABLE" agent_bridges 2> /dev/null || true)"
case "$SETS" in
	*\"*\"*) ;;
	*)
		echo "agent-egress-apply: FAILED - agent_bridges is empty, the policy would" >&2
		echo "not match any traffic (fail-open). Check the network selection." >&2
		exit 5
		;;
esac

echo
echo "egress policy active in the $MODE namespace"
echo "  networks:   $(echo "$SELECTED" | tr '\n' ' ')"
echo "  bridges:    $BRIDGES"
echo "  subnets:    $SUBNETS4 $SUBNETS6"
echo "  allowlist:  see lan4/lan6 in $POLICY"
echo "  dropped so far: $(drop_counter) packets"
echo
echo "Prove it with: sandbox/scripts/agent-egress-verify.sh"
