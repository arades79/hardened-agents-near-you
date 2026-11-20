# Sandboxing agent-container egress

How to keep an agent container from sending CUI / ITAR / proprietary data to a
server it should not reach, on a host that may be **internet connected**, while
the LAN (NFS share, model gateway) stays reachable.

Everything marked **verified** was tested on this machine (podman 5.8.7,
netavark 1.17.2, pasta, SELinux enforcing); the target fleet runs the same podman
5.8.2 / netavark 1.17.2 from `airgap-bundle/MANIFEST.sha256`. See
([Appendix A](#appendix-a--what-was-verified)) for the raw evidence,
[Appendix B](#appendix-b--upstream-references) for the upstream issues and doc
quotes this design rests on, and
[Appendix C](#appendix-c--open-questions-for-the-rocky-98-hosts) for the two
things worth re-checking on Rocky 9.8.

---

## TL;DR

1. **The container is not the boundary.** The dev user has passwordless sudo
   inside it (`Dockerfile`), so the agent can rewrite its own config, install
   tools, change its resolver and open any socket it likes. Every control that
   matters has to sit *outside* the container.
2. **The default rootless network is not filterable at all.** Podman 5.x
   defaults to per-container *pasta*: the container is handed a copy of the
   host's addresses, pasta emits the traffic as ordinary host sockets, and no
   netfilter path ever sees it. **Verified**: plain `podman run` → container has
   `enp5s0` = the host's LAN IP; with `--network <bridge>` → `eth0` on the
   network's subnet. This single default decides whether any of the rest works.
3. **With bridge networking, a default-deny policy works** and is in this
   directory: [`nftables/agent-egress.nft`](nftables/agent-egress.nft), loaded by
   [`scripts/agent-egress-apply.sh`](scripts/agent-egress-apply.sh). **Verified
   end-to-end**: on a real container, public TCP+ICMP and the cloud metadata IP
   were blocked, while the LAN target, the bridge gateway and DNS kept working,
   and the deny counter incremented.
4. **The policy lives in a namespace podman destroys when nothing references
   it**, which silently removes the rules (fail-open). **Verified**. The systemd
   unit in [`systemd/`](systemd/agent-egress-keeper.service) is what keeps it
   alive, and the scripts refuse to report success without reading the state
   back out of the kernel.
5. **Public-IP denial is necessary but not sufficient.** External DNS still
   resolves *through* the sandbox (verified), any address you allowlist is an
   exfiltration path, and an allowed-but-legitimate endpoint (model gateway,
   registry, MCP server) can carry your data inside a perfectly valid request.
   See [Residual channels](#residual-channels-backlog).
6. **The images now carry the inside half of the sandbox.** `/usr/local/bin/agent-ide-sandbox`
   applies [`nftables/egress-container.nft`](nftables/egress-container.nft) in the
   container's own netns at every start - the only mechanism that also filters
   the default rootless network (per-container pasta). Grant it with
   `--cap-add=NET_ADMIN`; `AGENT_IDE_SANDBOX=require` (what the example
   devcontainers set) makes a failed install fatal instead of a silent gap.

---

## 1. Threat model

| | |
| --- | --- |
| **Asset** | CUI / ITAR technical data / proprietary source on the host, the NFS share, and whatever the container can mount or reach |
| **Actor** | An AI coding agent (opencode, goose, pi, VS Code built-in agent) with root in its container, plus whatever prompt-injected content it consumes (repo files, dependencies, issues, tool output) |
| **Failure we are defending against** | The agent *sends data out* to a server nobody authorised: a public API, a registry, a telemetry endpoint, an attacker's collector, or the same data routed through an allowed LAN host |
| **Not in scope** | A human deliberately exfiltrating data (that is a policy/DLP/host problem), and kernel-level container escapes (see [§3.6](#36-stronger-isolation-runtimes)) |

Two properties of this workload drive the design: the agent needs a **local area
network** (the NFS share, and in the current bundles an OpenAI-compatible
gateway at `gateway.internal:8080`), and it must **not** reach public address
space. That is exactly "deny by default, permit by exception" applied to a dev
container - NIST SP 800-171 `3.13.6` / CMMC `SC.L2-3.13.6`.

### Scope: accidents, not adversaries (a deliberate decision)

This policy exists to stop **accidental** egress, not a determined insider.
Keeping that boundary explicit matters, because it decides how much machinery is
worth building:

* **Covered** - the ways CUI actually leaves by accident: an image default that
  points at a public endpoint (the agent bundles bake `api.openai.com`, and the
  note in `agents/README.md` that it "will time out" assumes an air-gapped
  host), telemetry and auto-update traffic, a tool shelling out to a package
  manager or fetching a URL the agent supplied, a mistyped gateway address, an
  environment variable nobody set.
* **Not covered** - a person who decides to move data out, or an agent
  explicitly steered around the sandbox. Anyone with sudo on the *host* can
  delete the policy; `--network host --privileged` walks around it. Both show up
  in the audit and the deny counter, which is the useful part.
* **What it implies for the design** - coverage and defaults beat depth.
  Hence: `containers.conf` forces the safe network so forgetting a flag cannot
  leak; the deny rule lives **outside** the container so a restart cannot lose
  it; the keeper keeps it installed while no container runs; and every denial is
  counted and logged so an accident is visible rather than silent. Tier 2
  (TLS-inspecting proxy, DLP) and the runtime-isolation section are only worth
  the effort if the threat model changes to "adversary".

There is one asymmetry that shapes the tiers below, and it cuts both ways. A
**default** container cannot install or change firewall rules in its own network
namespace: podman's default capability set has no `NET_ADMIN`, the bounding set
equals the effective set, so even root-with-sudo inside cannot acquire it
(verified). Adding `--cap-add=NET_ADMIN` flips that completely - the container
can then apply rules in its own netns and just as easily remove them (verified).
The first fact means rules placed by podman cannot be tampered with from inside;
the second is the mechanism behind
[Tier 1b](#tier-1b---in-container-rules-cheap-and-the-only-thing-that-covers-pasta),
which is the cheapest tier that fits an accident-prevention scope.

Rules are kernel state, not files, so there is no such thing as installing them
at image **build** time: a `RUN nft ...` step only affects the build container's
namespace and evaporates when the step exits (and with a host-networked build it
would touch the builder's own netns - never do that). Images can carry the
*ruleset file*; applying it is a runtime action, once per container start.

---

## 2. Where container traffic actually goes

Getting this wrong is the most common way a "sandbox" turns out to be
decorative, so it is worth being precise. There are four shapes:

| Container shape | Who emits the packets | Is the nftables policy in the rootless netns effective? |
| --- | --- | --- |
| `--network host` | the container's own processes, in the **host** netns | **no** - it *is* the host |
| `--network pasta` / `slirp4netns` (rootless default, **verified**) | the `pasta`/`slirp4netns` process, as host sockets | **no** - no forward path, nothing to match |
| `--network none` | nobody | n/a (nothing can leave - the strongest case) |
| bridge network (`agent-lan`, `podman`, ...) | the container, forwarded **inside podman's rootless netns** | **yes** - this is what the policy filters (**verified**) |

For the bridge case the chain is:

```
container netns            podman rootless netns                    host netns
  eth0 10.89.240.2  --veth-->  podman2 (bridge)  --> nft forward --> pasta tap (enp5s0)
                                  ^ policy hooks here              --> sockets on the host
```

Notes from the live host:

* The rootless netns really does hold the bridge and the container's veth
  (`podman2`, `veth0@if2`) - and `pasta` runs in the **host** netns with
  `--no-map-gw` (so containers cannot reach host loopback services by default).
* netavark's own rules live in `table inet netavark`, its `FORWARD` chain at
  `priority filter` (0) with `policy accept`: container → internet and
  container → LAN are allowed out of the box, and **netavark has no egress
  policy concept at all**. Its `isolate` option only blocks traffic between
  networks that set it, and `--internal` removes the route entirely.
* Our policy hooks `forward` at `priority -1`, i.e. before netavark. An `accept`
  there is not final (netavark still runs), a `drop` is final.

---

## 3. State of the art (and what each thing actually covers)

### 3.1 podman-native

| Knob | What it does | What it does not do |
| --- | --- | --- |
| `--network none` | loopback only | nothing else works either (needs another way to get NFS/gateway) |
| `podman network create --internal` | no default route, forwarding off on the bridge, aardvark answers only container names | kills LAN reachability too; **the only tier that cannot fail open** |
| `--opt isolate=true` | blocks traffic between networks that enable it | does **not** restrict internet or LAN egress (verified: opts recorded, no egress effect) |
| `--disable-dns`, `--dns <ip>` | container name resolution off / pin a resolver | not an egress control by itself |
| `--ipv6=false` | v4-only container network | v6 appears again if anyone enables it |
| `pasta_options`, `--network pasta:...` | `--no-map-gw` (already on for the rootless netns), `--dns none`, `--no-tcp/--no-udp`, `-4` | **no allowlist** - neither pasta nor slirp4netns can express "RFC1918 only" |
| `containers.conf [containers] netns="bridge"` + `[network] default_network=<name>` | **forces the default network** for every container that does not ask for another one, including ones the Dev Containers extension creates (**verified**) | a container can still pass `--network host|pasta|slirp4netns` explicitly - audit for it |

There is **no built-in per-container egress policy** in podman 5.8 (no
`--allow-cidr`, no network policy object). That is the gap this directory fills.

### 3.2 Kernel / systemd primitives

| Primitive | Reality on this stack |
| --- | --- |
| **nftables/iptables** (`forward` hook) | the practical mechanism. Scope rules to the agent bridges, run at priority `-1`, and install them in the namespace that forwards the traffic (rootless netns vs host netns) |
| **systemd `IPAddressAllow=` / `IPAddressDeny=`** | cgroup-v2 BPF egress/ingress filter; accepted by `.service`, `.scope`, `.socket`, `.mount`, `.swap`, `.slice`. Excellent for **rootful** containers (their scope lives under the unit). **The user manager does not support it** (systemd issue #38588, closed *not-supported*), so it cannot protect rootless containers on Rocky 9.8's systemd 252. Pairs well with the Quadlet/rootful option in [§5](#tier-3--rootful--quadlet-variant-optional) |
| **`nft` `socket cgroupv2 level N "path"`** | matches by the *socket owner's* cgroup; for rootless containers the socket owner is pasta, so it cannot distinguish containers. Rootful-only, and still only L3/L4 |
| **bpfilter** (iptables → eBPF translator) | removed from the kernel in 6.8 (`98e20e5e13d2`); do not plan around it |
| **OpenSnitch / Portmaster** | per-process firewalls on the *host*. For rootless containers they see `pasta`, not the workload - wrong attribution point |
| **eBPF policy (Cilium, Tetragon)** | Kubernetes/CRI-oriented. No maintained equivalent for plain podman/docker; `bpfman` only manages program lifecycle |

### 3.3 What the agents do themselves

Useful as defence in depth, and worth turning on, but none of it survives a
prompt injection *plus* an authorised destination:

| Agent | Sandbox today | Gap that matters here |
| --- | --- | --- |
| Claude Code | `sandbox.enabled`, off by default; wraps only Bash/PowerShell/monitor commands; host-side HTTP/SOCKS proxies over a bind-mounted unix socket on Linux; domain allowlist (no paths/methods) | Read/Edit/WebFetch/WebSearch, MCP servers and hooks run **outside** it; broad domains (`github.com`) are exfil paths; TLS not inspected; `dangerouslyDisableSandbox` exists |
| Codex CLI | `workspace-write` = network off (bwrap + seccomp; seccomp blocks network syscalls) | a domain allowlist exists only behind the experimental `features.network_proxy`; the proxy does not filter model traffic, web search, MCP or connector traffic |
| Gemini CLI | `-s` sandbox exists | default Seatbelt profile is write-confined but **network-allowed**; container mode does not document `--network none` |
| opencode | `permission` policy per tool (also used by this repo's bundle) | approval policy, not an OS sandbox; allowed commands run with user privileges |
| goose | Adversary Mode / prompt-injection review | detection, not egress control; MCP extensions run as the user |
| pi | none | upstream docs recommend exactly this sandbox: a container/VM with restricted network |
| MCP servers (all agents) | spec recommends consent + sandboxing + an **egress proxy** and blocking private/link-local ranges | no normative per-server allowlist; treat every MCP server as untrusted code with the agent's egress |

The unavoidable limit, stated by the vendors themselves: none of this stops the
model from putting your data into a request to an **allowed** destination - the
model API, a registry, a git remote, an MCP server (OWASP LLM01 prompt
injection, LLM06 excessive agency).

### 3.4 Proxies, mirrors, gateways, DLP

| Pattern | Covers | Bypasses |
| --- | --- | --- |
| Explicit forward proxy (`HTTPS_PROXY`) + allowlist (squid, mitmproxy, Envoy) | name-based allowlist, logging, per-tool policy | tools ignoring the proxy, direct-IP connections, QUIC/UDP, pinning (fails closed - often fine) |
| Transparent redirect (TPROXY/DNAT into a proxy) | catches everything that routes | content is still TLS unless you break it; UDP/QUIC needs explicit handling |
| `squid ssl_bump` / ICAP DLP | content inspection, real DLP | clients with pinning, ECH, non-HTTP protocols |
| Internal mirrors (Artifactory/Nexus/devpi/npm proxy) | removes package-manager egress entirely - the single cheapest control | does not touch model traffic or `curl`/`git` |
| LLM gateway (LiteLLM etc.) as the only route to a model | one auditable, keyed, redact-capable choke point | anything the agent sends via other tools |
| Enclave boundary NGFW with default-deny egress + SSL decryption | the control auditors actually look for (3.13.1, 3.13.6) | out of scope on a disconnected host; but on a *connected* host with CUI, this is where the requirement really lands |

### 3.5 Stronger isolation runtimes

gVisor (`podman --runtime=runsc`) and Kata Containers (`--runtime=kata`) make
escape harder - and nothing else. gVisor's netstack emits packets from the
host-side runtime, and its "external proxy" mode explicitly leaves egress
filtering to you; Kata guests must be filtered at the tap/bridge. Rootless Kata
is not a supported path (only the VMM drops privileges; the shim and virtiofsd
stay root). bubblewrap/nsjail with `--unshare-net` are useful for
non-containerized agents: they do not *filter* egress, they *remove* it.

### 3.6 macOS / Windows (for completeness)

macOS: `pf` is host/interface level; per-application policy needs Little Snitch
or LuLu, and neither sees inside Docker Desktop/Lima VMs. Windows: WSL2 is a
Hyper-V VM - use the Hyper-V firewall (on by default, Win11 22H2+/WSL 2.0.9+),
and note `dnsTunneling` means DNS is not even visible as packets.

---

## 4. How the state of the art falls short

1. **The default rootless network cannot be filtered.** Per-container pasta
   hands the container the *host's* LAN address and emits traffic as host
   sockets (verified). Until `netns="bridge"` is set, every control below is
   moot. This is the single most important finding in this document.
2. **No policy plane for rootless**: the rootless netns is created on demand,
   there is **no hook** that runs when it is (re)created, and podman destroys it
   when the last reference goes away. Rules installed there disappear silently -
   the worst possible failure mode for a security control (verified: my own
   apply script's read-back caught a policy that had evaporated).
3. **Silent failures everywhere**: `podman unshare` does not reliably forward
   the child's stderr, and `nft` inside the netns can be denied by SELinux when
   the ruleset file sits in a home directory (`user_home_t`) while the domain it
   runs in cannot read it (verified). Load rulesets over **stdin** and always
   read state back.
4. **The rootless netns is shared with every other rootless container.** A
   catch-all rule there breaks all of them (I did this to myself with an
   unconditional `drop` while experimenting: every bridge container on the host
   lost networking). Rules **must** be scoped by `iifname`.
5. **Sudo inside the container.** The agent can edit agent configs, install
   `curl`, change `resolv.conf`, and stop/start its own services. Any control
   that assumes the container is honest is not a control.
6. **DNS keeps working.** With public IPs denied, `nslookup example.com` still
   resolves (verified) because aardvark-dns forwards to the host's resolvers
   through pasta. DNS remains a low-bandwidth exfiltration channel, and DNS
   answers remain a way to *discover* internal names. Options, from best:
   internal-only resolver + `--dns <internal-ip>` + block other resolvers;
   or break the pasta DNS forward for the whole host (affects all rootless
   containers - verify before doing it).
7. **Allowed destinations are the real risk.** "Deny public IPs" closes the
   accidental-egress case (telemetry, auto-update, a mistyped endpoint, a
   prompt-injected `curl` to a collector). It does **not** stop the agent from
   putting data into a legitimate request to the gateway, a registry, a git
   remote, or an MCP server - and no vendor claims otherwise.
8. **The LAN allowlist is a trust decision, not a boundary.** Any LAN host with
   internet access becomes a jump host (an SSH config or a `ProxyCommand` away),
   and the NFS server itself holds the CUI. Allowlist the narrowest prefixes
   you can, and treat "can reach the LAN" as "can reach whatever the LAN can".
9. **IPv6 bypasses v4-only rulesets.** Their networks are v4-only (verified:
   `ipv6=false`), and the ruleset drops v6 from agent bridges anyway - but any
   host-level v4-only ruleset elsewhere is a bypass waiting to happen.
10. **Metadata endpoints are inside the allowlist ranges.** `169.254.0.0/16` is
    "local", so `169.254.169.254` is reachable unless explicitly denied. The
    policy denies the known metadata addresses first (AWS/GCP/Azure/OpenStack,
    ECS, Alibaba, Azure platform, Oracle, AWS IMDSv6).
11. **The container engine is the boundary's weakest seam.** `--network host`,
    `--privileged`, a mounted podman socket, or `/dev/kvm` all defeat the model.
    The policy cannot prevent them; policy + audit must.
12. **Host tooling is outside all of this.** VS Code desktop, git on the host, a
    browser, or a second terminal are not filtered by the container policy. On a
    connected host holding CUI, the enforceable boundary is the **host/enclave**,
    not the container.

---

## 5. Recommended architecture

Three tiers, cheapest first. Tier 1b is the one the images enable themselves
and it covers every container shape; the others close the gaps it cannot reach
(an entrypoint override, a whole-network policy, content inspection).

### Tier 0 - no LAN at all (cannot fail open)

Use when the only LAN need is the NFS share: mount it on the **host** and bind
it into the container. Then the container needs no route anywhere.

```sh
podman run -d --name agent-devbox --network none \
  -v /mnt/nfs/project:/workspace:rslave \
  agent-ide-opencode:rocky9 sleep infinity
```

* NFS is a host concern; the container just sees a directory (label it
  correctly on SELinux hosts: `:z` for a private label, or a matching context).
* No gateway reachable at this tier - if the agent needs an internal model
  endpoint, add a **two-homed gateway container** and let only that container
  have LAN reach:

```sh
podman network create --internal --ipv6=false agent-internal
podman network create --subnet 10.89.240.0/24 --ipv6=false --opt isolate=true agent-lan
# gateway: one interface on each network; it is the only thing that can reach the LAN
podman run -d --name agent-gateway --network agent-internal --network agent-lan \
  -p 8080:8080 my-llm-gateway
```

### Tier 1 - LAN allowlist (recommended default for this fleet)

1. Create the network and (optionally) pin the containers' resolver:

   ```sh
   sandbox/scripts/agent-network-create.sh --subnet 10.89.240.0/24 --dns 10.20.0.53
   ```

2. Force every container onto a policed bridge, including the ones the Dev
   Containers extension creates:

   ```sh
   sudo install -D -m 0644 \
     sandbox/config/containers.rootless.d-50-agent-sandbox.conf \
     /etc/containers/containers.rootless.d/50-agent-sandbox.conf
   ```

   `netns = "bridge"` + `default_network = "agent-lan"` - both keys, or the
   per-container pasta default comes back and the policy is bypassed.

3. Install the policy and keep it installed:

   ```sh
   sudo nft -f /dev/null   # (no-op) - see the note below about rootless vs rootful
   sandbox/scripts/agent-egress-apply.sh
   cp sandbox/systemd/agent-egress-keeper.service ~/.config/systemd/user/
   systemctl --user enable --now agent-egress-keeper.service
   ```

4. Prove it, and keep proving it - the state is not self-evident:

   ```sh
   sandbox/scripts/agent-egress-verify.sh --network agent-lan --lan-target <nfs-server>:2049
   ```

5. Tighten the allowlist in `nftables/agent-egress.nft` (`lan4`/`lan6`): replace
   RFC1918-in-general with your actual NFS server, gateway and resolver.
   **Every address you add is an exfiltration path** - keep it as narrow as the
   workload allows, and prefer explicit `…/32`s over `10.0.0.0/8`.

6. Harden the container itself (this does not replace the above; it limits what
   an escape would get):

   ```sh
   podman run -d --name agent-devbox --network agent-lan \
     --security-opt no-new-privileges --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
     --read-only --tmpfs /tmp:rw,size=1g \
     --userns=auto --pids-limit=2048 \
     -v /mnt/nfs/project:/workspace:rslave \
     agent-ide-opencode:rocky9 sleep infinity
   ```

   Caveat: dropping capabilities (or `no-new-privileges`) also breaks tools that
   rely on file capabilities - `ping` for a non-root container user, for
   example. That is usually the desired trade.

### Tier 1b - in-container rules (implemented)

For the accident-prevention scope this is the most useful tier: it is the only
mechanism that filters the **default rootless network** (per-container pasta
emits the traffic as host sockets, so no rule outside the container sees it -
[§2](#2-where-container-traffic-actually-goes)), and it needs no podman-side
configuration at all.

| Piece | Where it lives |
| --- | --- |
| policy | [`nftables/egress-container.nft`](nftables/egress-container.nft) → `/etc/agent-ide/egress-container.nft` in the image |
| applier | [`scripts/agent-egress-container.sh`](scripts/agent-egress-container.sh) → `/usr/local/bin/agent-ide-sandbox` |
| applied by | `/usr/local/bin/agent-ide-entrypoint` (base image and bundles), before any agent is configured |
| control | `AGENT_IDE_SANDBOX=apply` (default) or `require` or `off`; extra ranges via `AGENT_IDE_SANDBOX_ALLOW` |
| devcontainers | `examples/devcontainer-agent.json` and `examples/.devcontainer/devcontainer.json` pass `--cap-add=NET_ADMIN` + `AGENT_IDE_SANDBOX=require` |

How it behaves:

* `chain output` in the `inet` family: `established,related` first (so replies to
  published ports survive), then loopback, the metadata deny-list, the
  container's own directly connected prefixes (read from its routing table at
  start), the site allowlist in `allowed4`/`allowed6`, and finally log + counter
  + drop. IPv6 rules are included because a pasta container inherits the host's
  IPv6 prefixes - verified, and easy to forget.
* Installing rules needs `CAP_NET_ADMIN`; the applier re-executes itself through
  `sudo` (the devcontainer convention is a passwordless-sudo user) and says so
  plainly when that is impossible. `require` makes failure fatal *before* an
  agent starts; `apply` warns and continues so an image stays usable without the
  capability; `off` is a deliberate opt-out.
* Overlapping prefixes are handled: kernel route tables legitimately contain them
  (an RA-learned `/60` next to the `/64` inside it) while nftables interval sets
  reject overlaps. Each prefix goes in its own transaction, most specific first,
  and skipped ones are reported. A partial failure can only over-restrict, never
  under-restrict - the default-deny rule is in place before any dynamic element
  is added.
* Verified end-to-end in a Rocky 9 container as a non-root sudo user on the
  default pasta network: `1.1.1.1` and `169.254.169.254` blocked, LAN and DNS
  working, a second `apply` idempotent, `require` without the capability refusing
  to start, `apply` without it warning but running.

Use it alone when you only care about accidents. Use it **together with**
Tier 1 when you want a backstop that survives an entrypoint override
(`--entrypoint bash`) or a flushed in-container chain.

### Tier 2 - inspected choke point (CUI / high side)

Tier 1 plus: the only egress path is a proxy on a policed network, with
hostname allowlisting, logging and (where the endpoint is HTTP and you control
the client) TLS termination or a controlled LLM gateway so the payload can be
inspected and redacted. Combine with an internal-only resolver and, on a
connected host, default-deny egress at the enclave boundary (NIST 3.13.1 /
3.1.3 / 3.1.20; DFARS 252.204-7012 (b)(2)(ii)(D) expects cloud services
handling CDI to meet a FedRAMP Moderate-equivalent bar - a public model API is
not that). For ITAR technical data, a public/foreign cloud endpoint raises
deemed-export questions (22 CFR 120.50); there is no published DDTC guidance
that blesses LLM APIs, so treat it as a legal determination, not a config flag.

### Tier 3 - rootful / Quadlet variant (optional)

If the fleet can run these containers **rootful** (or you want Docker CE per
`testing/README.md`'s plan B), the host netns is the forward path, and you get a
second, independent layer for free:

```sh
nft -f - < sandbox/nftables/agent-egress.nft      # + the generated elements, see --dry-run
```

and, for the unit that owns the container's cgroup, `IPAddressDeny=any` +
`IPAddressAllow=<lan>` (cgroup BPF, inherited by the container's processes;
works on system units, **not** on the user manager). Two independent
enforcement points that fail differently - that is worth a lot.

---

## 6. Operating it

```sh
# state
sandbox/scripts/agent-egress-apply.sh --check      # exit 5 = egress is unpoliced

# install / re-install (idempotent; re-run after reboots and netns changes)
sandbox/scripts/agent-egress-apply.sh
sandbox/scripts/agent-egress-apply.sh --hold       # what the keeper unit runs

# change scope: which networks are policed
$EDITOR sandbox/config/agent-egress.conf
sandbox/scripts/agent-egress-apply.sh

# see exactly what would be loaded, without touching the kernel
sandbox/scripts/agent-egress-apply.sh --dry-run

# prove it behaves (do this in CI / in the acceptance test, not once)
sandbox/scripts/agent-egress-verify.sh --network agent-lan --lan-target 10.20.0.5:2049

# roll back
sandbox/scripts/agent-egress-apply.sh --flush
```

**Monitoring** (this is the control your assessor will ask for):

* `nft list counter inet agent_egress agent_egress_drops` - non-zero means an
  agent tried to reach something outside the allowlist. That is your
  prompt-injection / misconfiguration tripwire; alert on it.
* Denied packets are logged (`log prefix "agent-egress-drop: "`, rate-limited)
  into the kernel log on the host that forwards them - `journalctl -k | grep
  agent-egress-drop`.
* `systemctl --user status agent-egress-keeper.service` and
  `systemctl --user list-units --failed` - the keeper failing *is* the alarm:
  while it is down, container egress is unpoliced.
* Audit for bypass shapes after any change to the fleet:

  ```sh
  for c in $(podman ps -q); do
    printf '%s %s\n' "$(podman inspect -f '{{.Name}}' "$c")" \
                     "$(podman inspect -f '{{.HostConfig.NetworkMode}}' "$c")"
  done
  ```

  Anything that is not `none` or a policed bridge name is not filtered.
  `agent-egress-verify.sh` performs the same audit and warns.

**Wiring into the existing acceptance test**: `testing/airgap-test.sh` proves
"the VM is offline, the container works". Add a `--network agent-lan` variant
that runs `agent-egress-verify.sh` inside the VM, so a bundle that reintroduces
a public default endpoint fails the test instead of shipping.

---

## Residual channels (backlog)

| Channel | Status | Mitigation |
| --- | --- | --- |
| External DNS from inside the sandbox | **open** (verified: resolves) | internal-only resolver + `--dns <internal>` + block other resolvers; or break pasta's DNS forward host-wide (verify first) |
| Data inside a request to an **allowed** endpoint (gateway, registry, git remote, MCP) | open by design | Tier 2 proxy/gateway with logging + redaction; internal mirrors; treat MCP servers as untrusted |
| LAN pivot (allowlisted host with internet access, SSH jump hosts) | open by design | narrow allowlist; default-deny egress at the LAN boundary too |
| `--network host|pasta|slirp4netns` containers | open unless audited | the audit above; policy forbids them for agent workloads |
| Host-side tooling (VS Code desktop, git, browser, telemetry) | open | host/enclave boundary, host firewall, MDM; the container policy cannot help |
| Container escape (`--privileged`, mounted podman socket, kernel bugs) | open | `--cap-drop=ALL`, `no-new-privileges`, `--userns=auto`, read-only rootfs, never mount the engine socket; gVisor/Kata if the threat model justifies it |
| Removable media / OS image transfers (the air-gap bundle) | open | existing transfer procedure; keep it outside the agent's reach and log it |

---

## Files

| Path | Purpose |
| --- | --- |
| `nftables/agent-egress.nft` | Host-side policy (Tier 1): default-deny to public IP space for whole podman networks, LAN allowlist, metadata deny-list, anti-spoof, logging, counters |
| `nftables/egress-container.nft` | Container-side policy (Tier 1b): the same idea as an `output` hook inside the container - the only tier that also filters the default pasta network |
| `scripts/agent-egress-container.sh` | Installs that policy inside a container (`agent-ide-sandbox` in the images); `apply` / `check` / `flush`, self-escalates via sudo |
| `config/agent-egress.conf` | Which podman networks the policy covers (default: all bridges) |
| `config/containers.rootless.d-50-agent-sandbox.conf` | Installs `netns=bridge` + `default_network=agent-lan` system-wide for rootless users |
| `scripts/agent-egress-lib.sh` | Shared helpers (`ns_run`, `policy_present`, `drop_counter`, network discovery) |
| `scripts/agent-network-create.sh` | Creates `agent-lan` (and optionally `agent-internal`) with the right options |
| `scripts/agent-egress-apply.sh` | Installs / checks / flushes the policy; fails loudly if it is not really in place |
| `scripts/agent-egress-verify.sh` | Behavioural proof from inside a container + container audit |
| `systemd/agent-egress-keeper.service` | Holds the rootless netns open and re-applies the policy |

---

## Appendix A - what was verified

Environment: Fedora 44 / Bazzite host, kernel 7.2.8, **podman 5.8.7**,
netavark 1.17.2, aardvark-dns 1.17.1, passt 2026xxxx build, nftables 1.1.6,
SELinux enforcing. The fleet target is Rocky 9.8 with podman 5.8.2 /
netavark 1.17.2 / nftables 1.0.9 / systemd 252.

| # | Claim | How it was checked |
| --- | --- | --- |
| 1 | Rootless default is per-container pasta | `podman run alpine ip -o addr` → `enp5s0` with the **host's** LAN IP and default route; `--network podman` → `eth0 10.88.0.2/16` |
| 2 | Container traffic is forwarded in podman's rootless netns | `podman unshare --rootless-netns ip -o link show` → `podman2` (the network's bridge) and `veth0@if2` (the container's peer); `nft list tables` there shows `table inet netavark` with per-subnet rules |
| 3 | netavark's `FORWARD` chain is `priority filter`, policy accept, no egress policy | `nft list ruleset` in the rootless netns |
| 4 | `isolate=true` is recorded but is not an egress control | `podman network inspect` → `opts=map[isolate:true]`; traffic still allowed out |
| 5 | The policy blocks public IPs and keeps the LAN working | Applied in the rootless netns to a live container: public TCP **blocked**, public ICMP **blocked**, LAN ICMP/TCP **ok**, bridge gateway **ok**, metadata **blocked**, deny counter +5 |
| 6 | The policy is not persistent by itself | Installed, then the holder process exited → netns (and policy) gone; `--check` reported it |
| 7 | `podman unshare --rootless-netns nft -f <file-in-home>` fails silently (SELinux label) | `nft -f /path` inside the netns → failure with no message; `nft -f -` over stdin → success; `ls -Z` showed `user_home_t` |
| 8 | A catch-all rule in the shared netns breaks all rootless bridge containers | An unconditional `counter drop` chain created while experimenting took every bridge container offline (public **and** LAN) until it was deleted |
| 9 | `netns="bridge"` + `default_network=<name>` changes the rootless default | `CONTAINERS_CONF=... podman run alpine` → `eth0 10.89.0.2/24` on the named network (and `10.88.0.3/16` on `podman` with the key alone) |
| 10 | ICMP is unavailable to a non-root container user by default | `CapBnd=0x800405fb` (no `NET_RAW`), `net.ipv4.ping_group_range="0 0"`, and `no-new-privileges` blocks iputils' file capabilities: `ping` fails as `vscode`, works as root. The probe therefore runs `--user 0` |
| 11 | A default container cannot touch its own network namespace | bounding set == effective set (no `NET_ADMIN`, `NET_RAW`, `SYS_ADMIN`): `ip link set lo down` and `unshare -n` fail with EPERM even as root inside the container |

## Appendix B - upstream references

The design in this directory exists because podman has **no supported egress
filter for rootless users**. The trail, for anyone who wants to check the claim
or track a fix:

### The canonical answer (quoted verbatim from the issue thread)

**containers/podman #27094** - *"Make it possible for non root user to restrict /
filter the network communications of podman containers following custom
rules"* - closed **not planned** (2025-09-17).
<https://github.com/containers/podman/issues/27094>

Maintainer reply (Luap99):

* *"I would consider such request outside of the scope of podman. There is just
  to much complexity in creating custom firewall rules and how they get exposed
  to users."*
* *"For the default case (--network pasta) there is only the container netns and
  the host netns, pasta doesn't have any sort of firewall so the only way (if
  you cannot add them on the host) is to add them into the container."*
* For *named* networks: rules go into the intermediate **rootless-netns** via
  `podman unshare --rootless-netns`, *"but keep in mind the namespace only lives
  as long as there are active users of it. So once all containers using it exit
  it will be removed by podman and on the next start created again. You would
  need to inject the firewall rules each time it is created and **there are no
  hooks to do that**."*
* *"The best thing would be to podman unshare --rootless-netns add the rules
  there and then sleep inf to keep the podman process alive forever which then
  keeps the namespace around"* - which is precisely what
  `agent-egress-apply.sh --hold` and `agent-egress-keeper.service` implement.
* You have full privilege in that namespace: *"compare `unshare -rn` as user,
  you can create any firewall rules you want there"* - and rules added *inside*
  the container are *"only safe as long as the container doesn't get
  CAP_NET_ADMIN"*.
* Upstream's own extension points: **OCI hooks** (runs per container start) or
  writing a **netavark plugin** (you implement the whole network driver) -
  <https://github.com/containers/netavark/blob/main/plugin-API.md>. A
  createRuntime hook can run `podman unshare --rootless-netns nft ...`; it
  depends on `hooks_dir` being wired up per container, which is why this repo
  uses the keeper service instead.

### The mechanism that would be native, if it existed

* **containers/netavark #705** - *"Allow user to control firewall - DOCKER-USER
  replica"* - **open** since 2023-05-30, 6 👍.
  <https://github.com/containers/netavark/issues/705> - a user-owned chain to
  permit/deny destinations. There is no `DOCKER-USER` equivalent; this is the
  issue to watch or +1.
* **containers/netavark #1149** - *"Limit firewall rules to podman interfaces
  only"* (open) - netavark's jump into `NETAVARK_FORWARD` is unqualified, which
  is why custom rules have to be scoped to the agent bridges.
* **containers/podman #27399** - *"Run container inside rootless netns"*
  (open) - `--network=ns:<path>` can already join the rootless netns; the
  request is to make that a first-class mode.

### What `--internal` and `isolate` really mean

* `podman-network-create(1)` v5.8.2 (<https://docs.podman.io/en/v5.8.2/markdown/podman-network-create.1.html>):
  `--internal`: *"Restrict external access of this network when using a bridge
  network"* / *"IP forwarding is disabled on the bridge interface instead of
  setting up a firewall"* / *"No default route will be added to the
  container"*; `--opt isolate`: *"This option isolates networks by blocking
  traffic between those that have this option enabled"*; `--route ... blackhole`:
  *"Note, routes are added into the container namespace, if a container is
  given the CAP_NET_ADMIN capability it is able to alter the routes so this
  cannot be used for security relevant things in that case."* - i.e. no option
  here denies public IPs while keeping the LAN.
* `podman-network(1)`: *"Pasta by default performs no Network Address
  Translation (NAT) and copies the IPs from your main interface into the
  container namespace"* - the documented form of what Appendix A item 1 shows.
* `podman-run(1)`: `pasta` is *"the default for rootless containers"*, with
  `--no-map-gw` assumed and `--dns-forward 169.254.1.1` added as first resolver
  - the documented source of the DNS residual channel.
* `containers.conf(5)`: `default_network` *"only effects the network assignment
  when the bridge network mode is selected ... It is the default for rootful
  containers but not as rootless."* - hence the need for `netns="bridge"` next
  to it.
* **containers/netavark #331** (closed) - maintainer: *"Isolation blocks all
  external communication which is wrong, this is what internal is used for"* -
  settles `isolate` (bridge-to-bridge) vs `--internal` (no external route).
* **containers/podman #16085** - *"Restrict outgoing network access"* (closed)
  - the recurring expectation gap: `--internal --disable-dns` stopped name
  resolution but *"Requests to IP address still working"* in the reporter's
  environment (podman-machine 4.2).

### Evidence that rootless egress is allow-by-default

* **containers/podman #26913** (closed) contains a live rootless
  `podman unshare --rootless-netns iptables -L` dump: `NETAVARK_FORWARD` with a
  blanket `ACCEPT <subnet> -> anywhere`, DNS accepts in `NETAVARK_INPUT`, and
  DROP rules in `NETAVARK_ISOLATION_*`. That is the default this policy
  replaces.

### Namespace lifecycle (why a keeper is needed)

* **containers/podman #28441**, **#29419**, **#26118** (all open) - the
  rootless netns is cleaned up and rebuilt around container lifecycles
  (`rootless-netns-<id>.scope`, *"rootless netns program no longer running,
  trying to start it again"*), which is the failure mode `--check` and the
  verify script are designed to catch.
* `podman-unshare(1)`: *"--rootless-netns: Join the rootless network namespace
  used for netavark networking."*
* **containers/podman #29727** (closed) - the real pasta argv used for the
  rootless netns (`-t none -u none -T none -U none --no-map-gw ...
  --map-guest-addr 169.254.1.2`).

### Community recipes

* Stack Overflow **#78952110** - *"nftables - block outgoing traffic for Podman
  rootless containers"* (0 answers) - the exact question, unanswered.
  <https://stackoverflow.com/questions/78952110/nftables-block-outgoing-traffic-for-podman-rootless-containers>
* Recipes built on `DOCKER-USER`, `NETAVARK_FORWARD` or host-nftables (e.g.
  Docker's own iptables documentation) assume **rootful** and do not apply to
  the rootless pasta/bridge path.

### Version note for later upgrades

In podman 6 / netavark 2 the `isolate` option changed: it now defaults to
`strict` and accepts `strict|true|false`. `--opt isolate=true` (what
`agent-network-create.sh` passes) keeps the podman 5.8 behaviour after an
upgrade.

| 12 | `--cap-add=NET_ADMIN` gives a rootless container authority over its own netns | `CapBnd` gains bit 12 (`0x800405fb` → `0x800415fb`); `nft add table`, `ip link set lo down` and `ip route add blackhole ...` all succeed |
| 13 | In-container `output` rules filter the **default pasta** network | `chain output` (loopback/link-local/LAN accepts, rest dropped): public `1.1.1.1` blocked, LAN `192.168.1.1` reachable, DNS working - with no podman-side configuration at all |
| 14 | With `NET_ADMIN` the container can also remove its own rules | `nft flush table inet t` succeeded from inside (a flush keeps chains, which is why egress stayed blocked in that test; deleting the table or setting `policy accept` is equally available) |

## Appendix C - open questions for the Rocky 9.8 hosts

1. **SELinux domain of `nft` inside the rootless netns on Rocky**: the silent
   file-read denial above was observed on the Fedora/Bazzite host. On Rocky 9.8
   with `container-selinux` installed, if the tooling is the same, loading over
   stdin avoids the question entirely - which is what the scripts do. If `nft -f
   <path>` works there, nothing changes.
2. **`podman` 5.8.2 vs 5.8.7 details**: `netns="bridge"`, `default_network`,
   `--opt isolate` and the `pasta` default were verified on 5.8.7; the same
   keys exist in 5.8.2 (man pages in `airgap-bundle` show
   `default_rootless_network_cmd`, `firewall_driver`, `pasta_options`). Run
   `sandbox/scripts/agent-egress-verify.sh` once on the first Rocky host as part
   of acceptance - it is the only check that matters.
