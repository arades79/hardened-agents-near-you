#!/usr/bin/env bash
# =============================================================================
# agent-ide - install the container-side egress policy (Tier 1b)
# =============================================================================
# Installed in the images as /usr/local/bin/agent-ide-sandbox and called from
# the container entrypoint. It applies sandbox/nftables/egress-container.nft in
# this container's own network namespace: default-deny to public IP space, LAN
# allowlist, metadata deny-list.
#
# Why inside the container: it is the only place that can filter the default
# rootless network (per-container pasta), where the traffic leaves as host
# sockets of the pasta process (sandbox/README.md, §2). It also works on bridge
# networks, and needs no podman-side configuration at all.
#
# Usage: agent-ide-sandbox [apply|check|status|flush]
#
# Environment
#   AGENT_IDE_SANDBOX=apply     (default) apply if possible, WARN if not
#   AGENT_IDE_SANDBOX=require   apply, and fail the container if that is not
#                               possible (use this in sanctioned devcontainers)
#   AGENT_IDE_SANDBOX=off       do nothing (deliberate opt-out)
#   AGENT_IDE_SANDBOX_RULESET   ruleset file (default /etc/agent-ide/egress-container.nft)
#   AGENT_IDE_SANDBOX_ALLOW     extra destination ranges on top of the ruleset
#                               file, e.g. "10.20.0.0/16 192.0.2.7/32"
#
# Applying rules needs CAP_NET_ADMIN, so the container must be started with
# `--cap-add=NET_ADMIN` and this script re-executes itself through sudo when it
# is started as the unprivileged dev user. A container that has NET_ADMIN can
# also remove these rules again: this is accident prevention, not a boundary
# (sandbox/README.md, "Scope: accidents, not adversaries").
#
# Exit codes: 0 ok (or deliberately disabled), 3 unusable environment (no nft,
# no privileges), 4 nft refused the ruleset, 5 verification failed.
# =============================================================================
set -euo pipefail

TABLE=agent_egress_out
RULESET="${AGENT_IDE_SANDBOX_RULESET:-/etc/agent-ide/egress-container.nft}"
MODE="${AGENT_IDE_SANDBOX:-apply}"
ACTION="apply"

case "${1:-}" in
	apply | check | status | flush) ACTION="$1" ;;
	-h | --help)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	"") ;;
	*)
		echo "agent-ide-sandbox: unknown action: $1 (use apply, check, status, flush)" >&2
		exit 2
		;;
esac

case "$MODE" in
	apply | require | off) ;;
	*)
		echo "agent-ide-sandbox: AGENT_IDE_SANDBOX must be apply, require or off" >&2
		exit 2
		;;
esac

warn_or_fail() { # $1 = exit code, $2 = reason
	if [ "$MODE" = require ]; then
		printf '\033[1;31m[agent-ide-sandbox] FAILED:\033[0m container egress is NOT filtered: %s\n' "$2" >&2
		printf '  Start the container with --cap-add=NET_ADMIN (the sandbox needs it to\n' >&2
		printf '  load its firewall rules), or set AGENT_IDE_SANDBOX=off explicitly.\n' >&2
		exit "$1"
	fi
	printf '\033[1;33m[agent-ide-sandbox] WARNING:\033[0m container egress is NOT filtered: %s\n' "$2" >&2
	printf '  Start the container with --cap-add=NET_ADMIN to enable it, or set\n' >&2
	printf '  AGENT_IDE_SANDBOX=require to make this a hard failure.\n' >&2
	exit 0
}

if [ "$MODE" = off ]; then
	echo "agent-ide-sandbox: disabled (AGENT_IDE_SANDBOX=off); container egress is not filtered"
	exit 0
fi

# ---------------------------------------------------------------- privileges
# Loading netfilter rules needs CAP_NET_ADMIN. The devcontainer convention is a
# passwordless-sudo user, so re-exec through sudo and keep this script as the
# single entry point. `sudo -n` fails visibly (no-new-privileges, no sudoers)
# instead of prompting.
if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo > /dev/null 2>&1; then
		set +e
		sudo -n --preserve-env=AGENT_IDE_SANDBOX,AGENT_IDE_SANDBOX_ALLOW,AGENT_IDE_SANDBOX_RULESET \
			-- "$0" "$ACTION"
		rc=$?
		set -e
		case "$rc" in
			0) exit 0 ;;
			2 | 3 | 4 | 5) exit "$rc" ;;
			126 | 127)
				warn_or_fail 3 "the applier could not run inside this container (exit $rc - is a helper such as 'ip' or 'nft' missing?)"
				;;
			*)
				warn_or_fail 3 "could not become root (sudo -n exited $rc; no sudoers entry, or no-new-privileges set?)"
				;;
		esac
	fi
	warn_or_fail 3 "running as uid $(id -u) without sudo, so rules cannot be applied"
fi

command -v nft > /dev/null 2>&1 || warn_or_fail 3 "nft is not installed in this image"
[ -r "$RULESET" ] || warn_or_fail 3 "ruleset file not readable: $RULESET"

# ------------------------------------------------------------ gather + apply
collect() {
	# Directly connected networks of this container. With pasta these are copies
	# of the host's prefixes, including its IPv6 ones; kernel route tables
	# legitimately contain overlapping prefixes (a /60 learned from RA next to
	# the /64 it contains), so the lists are sorted most-specific-first and
	# added one per nft transaction - interval sets reject overlaps.
	# `ip` is best-effort: without it the static allowlist still applies.
	OWN4=""
	OWN6=""
	IP_MISSING=""
	if command -v ip > /dev/null 2>&1; then
		OWN4="$(ip -o -4 route show 2> /dev/null |
			awk '$1 != "default" && $1 ~ "/" { print $1 }' | sort -u -t/ -k2,2nr | tr '\n' ' ' || true)"
		OWN6="$(ip -o -6 route show 2> /dev/null |
			awk '$1 != "default" && $1 ~ "/" { print $1 }' | sort -u -t/ -k2,2nr | tr '\n' ' ' || true)"
	else
		IP_MISSING=1
	fi
	EXTRA4=""
	EXTRA6=""
	if [ -n "${AGENT_IDE_SANDBOX_ALLOW:-}" ]; then
		for cidr in $(printf '%s' "$AGENT_IDE_SANDBOX_ALLOW" | tr ',' ' '); do
			case "$cidr" in
				*:*) EXTRA6="${EXTRA6}${EXTRA6:+ }$cidr" ;;
				*) EXTRA4="${EXTRA4}${EXTRA4:+ }$cidr" ;;
			esac
		done
	fi
}

SKIPPED=""
add_elements() { # $1 = set name, $2 = prefixed range list
	[ -n "$2" ] || return 0
	for prefix in $2; do
		if ! nft add element inet "$TABLE" "$1" "{ $prefix }" 2> /dev/null; then
			SKIPPED="${SKIPPED}${SKIPPED:+, }$prefix"
		fi
	done
}

apply() {
	# Idempotent: drop any previous table (the netns is normally fresh, but
	# `podman exec agent-ide-sandbox apply` must work too).
	nft delete table inet "$TABLE" 2> /dev/null || true
	# Read the ruleset through the shell and feed it to nft on stdin: nft can be
	# denied by SELinux on files it does not expect to read, and that failure is
	# silent. The default-deny chain is in place before any dynamic element is
	# added, so a partial failure can only over-restrict, never under-restrict.
	cat "$RULESET" | nft -f - || return 4
	add_elements own4 "$OWN4"
	add_elements own6 "$OWN6"
	add_elements allowed4 "$EXTRA4"
	add_elements allowed6 "$EXTRA6"
}

verify() {
	# The named counter appears in the rule as: counter name "agent_egress_out_drops" drop
	nft list chain inet "$TABLE" output 2> /dev/null | grep -q 'agent_egress_out_drops' || return 5
}

drop_count() {
	nft list counter inet "$TABLE" agent_egress_out_drops 2> /dev/null |
		tr '\t' ' ' |
		awk '{ for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }' |
		grep . || echo 0
}

case "$ACTION" in
	check | status)
		if verify; then
			echo "agent-ide-sandbox: egress policy is active (dropped so far: $(drop_count) packets)"
			nft list chain inet "$TABLE" output 2> /dev/null
			exit 0
		fi
		echo "agent-ide-sandbox: egress policy is NOT active in this container" >&2
		exit 5
		;;
	flush)
		if nft delete table inet "$TABLE" 2> /dev/null; then
			echo "agent-ide-sandbox: egress policy removed"
		else
			echo "agent-ide-sandbox: no egress policy to remove"
		fi
		exit 0
		;;
esac

collect
if ! apply; then
	warn_or_fail 4 "nft refused the ruleset (missing CAP_NET_ADMIN, or a ruleset that does not fit this kernel)"
fi
if ! verify; then
	warn_or_fail 5 "rules did not survive the read-back check"
fi

echo "agent-ide-sandbox: egress policy active"
echo "  allowlist:  LAN only, see allowed4/allowed6 in $RULESET"
echo "  own nets:  ${OWN4:-none} ${OWN6:-}"
if [ -n "${IP_MISSING:-}" ]; then
	echo "  note: 'ip' is not installed here, so the container's own subnets could not be"
	echo "        added; the allowlist above still applies (install iproute to get them)"
fi
[ -n "$EXTRA4$EXTRA6" ] && echo "  extra allow: $EXTRA4 $EXTRA6"
[ -n "$SKIPPED" ] && echo "  (already covered or conflicting, skipped: $SKIPPED)"
echo "  dropped so far: $(drop_count) packets"
echo "  (public IP space is denied; denials are logged as 'agent-egress-drop:' on the host)"
