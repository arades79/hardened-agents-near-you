# shellcheck shell=sh
# =============================================================================
# agent-ide sandbox - shared helpers for the egress scripts
# =============================================================================
# Sourced by agent-egress-apply.sh and agent-egress-verify.sh. Not executable.
#
# The important part is `ns_run`: with *rootless* podman, container traffic is
# forwarded inside podman's rootless network namespace, not in the host
# namespace, so nftables rules that must see that traffic have to be installed
# there. With rootful podman (or Docker CE) the host namespace is the right one
# and the rules are installed directly.
#
# Note (observed on podman 5.8, SELinux enforcing): `podman unshare` does not
# reliably forward the child's stderr, so a failing `nft` invocation can be
# silent. Never trust "the command returned" - always read the state back
# (policy_present / drop_counter below) and fail loudly.
# =============================================================================

: "${TABLE:=agent_egress}"
: "${TOOL:=${PODMAN:-podman}}"

# ns_mode: print "rootless" or "host" - which namespace forwards this host's
# container traffic.
ns_mode() {
	if ! command -v "$TOOL" > /dev/null 2>&1; then
		printf '%s\n' host
		return 0
	fi
	case "$("$TOOL" info --format '{{.Host.Security.Rootless}}' 2> /dev/null)" in
		true) printf '%s\n' rootless ;;
		*) printf '%s\n' host ;;
	esac
}

# ns_run: run a command in the namespace that forwards container traffic.
ns_run() {
	if [ "$(ns_mode)" = rootless ]; then
		"$TOOL" unshare --rootless-netns "$@"
	else
		"$@"
	fi
}

# policy_present: true if the egress policy table is loaded.
policy_present() {
	ns_run nft list chain inet "$TABLE" forward > /dev/null 2>&1
}

# drop_counter: number of packets the default-deny rule has dropped (0 if the
# counter cannot be read yet). A non-zero value after an agent session is a
# finding worth looking at.
drop_counter() {
	n=$(ns_run nft list counter inet "$TABLE" agent_egress_drops 2> /dev/null |
		tr '\t' ' ' |
		awk '{ for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }')
	printf '%s\n' "${n:-0}"
}

# agent_networks: the networks the policy should cover, honouring the site
# config and excluding non-bridge networks (host/none have no interface).
# The caller may pre-set AGENT_NETWORKS / AGENT_NETWORK_EXCLUDE (command line
# wins); otherwise they come from CONF.
agent_networks() {
	if [ -z "${AGENT_NETWORKS:-}" ]; then
		# shellcheck disable=SC1090
		[ -r "$CONF" ] && . "$CONF"
		: "${AGENT_NETWORKS:=all}"
	fi
	: "${AGENT_NETWORK_EXCLUDE:=}"

	_all="$("$TOOL" network ls --format '{{.Name}}' 2> /dev/null || true)"
	_out=
	for _net in $_all; do
		case " $AGENT_NETWORK_EXCLUDE " in
			*" $_net "*) continue ;;
		esac
		if [ "$AGENT_NETWORKS" != all ]; then
			case " $AGENT_NETWORKS " in
				*" $_net "*) ;;
				*) continue ;;
			esac
		fi
		_if="$("$TOOL" network inspect "$_net" --format '{{.NetworkInterface}}' 2> /dev/null || true)"
		[ -n "$_if" ] || continue
		_out="${_out}${_out:+ }$_net"
	done
	printf '%s\n' "$_out"
}

# agent_network_ifaces: bridge interface names of the networks to police.
agent_network_ifaces() {
	for _net in $(agent_networks); do
		"$TOOL" network inspect "$_net" --format '{{.NetworkInterface}}' 2> /dev/null || true
	done
}
