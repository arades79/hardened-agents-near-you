# Air-gap acceptance test: Rocky 9 KVM VM + VS Code desktop (rpm)

This procedure proves the core promise of the base image: a VS Code desktop
client, installed from the official rpm and matching the baked commit, can
attach to a container on a **completely disconnected** network - because the
VS Code Server is already inside the image.

The topology under test:

```
Rocky 9 KVM VM  (network detached at the hypervisor level)
|-- VS Code desktop (rpm) + Dev Containers extension (VSIX only)
|-- podman (rootless)  <- image loaded from the transfer bundle
`-- container "agentide-devbox"  (agent-ide-base:rocky9)
        `-- ~/.vscode-server/bin/<commit>  <- baked server, matches the client
```

Everything below is run either on the host or in the VM, and is marked as such.

## 0. Prerequisites

- Host with KVM/libvirt (`virsh`, `virt-install`, `virt-viewer`), `xorriso`,
  and podman. `virt-copy-in` is optional (see step 3).
- Rocky 9 DVD ISO, e.g.
  `https://dl.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-dvd.iso`
- The `agent-ide-base:rocky9` image built on the host (see top-level `README.md`).
- ~5 GB free disk for the VM disk and the bundle/ISO.

## 1. Build the bundle  (host, connected)

```sh
cd /path/to/agent-ide
testing/make-bundle.sh --iso --out airgap-bundle
```

It reads the baked commit out of the image, downloads the **exact matching**
VS Code client rpm (`commit:<sha>/linux-rpm-x64/stable`), the Dev Containers
VSIX, resolves offline rpm dependencies (podman + GUI libs) in a throwaway
Rocky 9 container, saves the image (`podman save`, docker-archive) and writes
`MANIFEST.sha256`. `--docker` additionally stages Docker CE rpms as plan B
(see Troubleshooting).

## 2. Create the VM  (host, connected)

Skip if you already have a Rocky 9 GUI VM; just note its name.

```sh
virt-install \
  --name agentide-airgap \
  --memory 8192 --vcpus 4 \
  --disk size=40 \
  --cdrom /var/lib/libvirt/images/Rocky-9-latest-x86_64-dvd.iso \
  --os-variant rocky9 \
  --graphics spice,listen=127.0.0.1 --video qxl \
  --network network=default,model=virtio \
  --noautoconsole

virt-viewer --connect qemu:///system agentide-airgap
```

In the installer:

- Software selection: **Workstation with GUI** (GNOME). Create an admin user
  (the desktop user the test runs as) and log in once.
- While this provisioning network is still up, optionally
  `sudo dnf -y upgrade` so the VM matches the repo versions used for the
  bundled dependency rpms. Reboot when done.
- `podman` may or may not be present - the bundle carries it if it is missing,
  so no need to check.

The disk is `/var/lib/libvirt/images/agentide-airgap.qcow2` if you used the
default pool. Shut the VM down: `virsh shutdown agentide-airgap`.

## 3. Transfer the bundle in  (host, offline phase)

Two options; the ISO route needs no extra host tooling:

**ISO route (default).** Attach the bundle ISO as a second cdrom (needs one
reboot to appear in the guest), then mount it inside the VM:

```sh
# with the VM shut off, or running only if you also reboot afterwards:
virsh domblklist agentide-airgap          # find the cdrom target, e.g. 'sda'
virsh change-media agentide-airgap sda --eject --config
virsh attach-disk agentide-airgap "$(pwd)/agentide-bundle.iso" \
  sdc --type cdrom --mode readonly --targetbus sata --config
virsh start agentide-airgap
```

If `attach-disk` complains about the bus, check `virsh dumpxml agentide-airgap`
and use `--targetbus ide` (i440fx domains) instead of `sata`.

**Alternative:** `sudo dnf install guestfs-tools`, then with the VM shut off:

```sh
sudo virt-copy-in -a /var/lib/libvirt/images/agentide-airgap.qcow2 airgap-bundle /root/
```

## 4. Disconnect the network  (host + guest)

```sh
virsh dumpxml agentide-airgap > ~/agentide-airgap-netbackup.xml
virsh domiflist agentide-airgap            # note the MAC address
virsh detach-interface agentide-airgap --type network --mac <MAC> --live --config
virsh domiflist agentide-airgap            # must print nothing
```

In the guest (belt and braces), and to confirm:

```sh
nmcli networking off
ip -brief addr                             # only 'lo' should remain
ping -c1 -W2 1.1.1.1                       # must fail
```

If hot-unplug is not supported for your domain, shut it down, run the same
`detach-interface` with only `--config`, and start it again.

## 5. Run the acceptance test  (guest, disconnected)

```sh
sudo mount -o ro /dev/disk/by-label/AIRGAPBUNDLE /mnt
cp -r /mnt/. ~/airgap-bundle && chmod -R u+w ~/airgap-bundle
sudo umount /mnt
bash ~/airgap-bundle/airgap-test.sh
```

The script (see `airgap-test.sh --help`):

1. proves the VM is really offline (interfaces, DNS, HTTPS),
2. verifies `MANIFEST.sha256`,
3. installs the bundled VS Code rpm and **compares the client commit to the
   baked server commit** (the one thing that must match),
4. installs the Dev Containers VSIX with the client CLI,
5. writes client settings (podman path/socket, no auto-updates, no telemetry),
6. starts the rootless podman socket,
7. loads the image, checks marker file, server commit and machine settings,
8. starts the attach target (`agentide-devbox`) and the browser UI
   (`http://localhost:8000/`),
9. walks you through the manual attach and then reads the evidence for you.

Pre-flight tip: run it once while still connected with `--allow-network` to
exercise everything except the attach before committing to the air gap.

## 6. What "good" looks like

- The attach (**Dev Containers: Attach to Running Container...** -> pick
  `agentide-devbox`) completes in a few seconds; the window title shows the
  container.
- The script's evidence checks all pass, in particular:
  - the running server process path is
    `/home/vscode/.vscode-server/bin/<commit>/out/server-main.js`,
  - `~/.vscode-server/bin/` contains exactly the baked commit,
  - the client wrote its `code-<commit>` launcher (it found the baked server),
  - no `vscode-server-*.tar.gz` exists inside the container,
  - the browser UI returns HTTP 200.
- Output panel -> **Dev Containers** shows connection steps but no download
  attempt of a server.

Closest equivalent commands, if you want to look yourself:

```sh
podman exec agentide-devbox sh -lc 'ps -eo user,args | grep [s]erver-main.js'
podman exec agentide-devbox sh -lc 'ls -a ~/.vscode-server ~/.vscode-server/bin'
```

## 7. Negative control (optional but convincing)

```sh
bash ~/airgap-bundle/airgap-test.sh --negative-control
```

After the main test it moves the baked server aside inside the container and
asks you to detach and re-attach. The attach must now **fail** (there is no
network to fetch a server). That failure is the proof that the first attach
was served entirely from the image. The script restores the server and asks
you to re-attach to confirm recovery.

## 8. Restore and clean up

```sh
# guest
podman rm -f agentide-devbox agentide-web
# host (VM shut off)
virsh attach-interface agentide-airgap --type network --source default --model virtio --config
#   or: virsh define ~/agentide-airgap-netbackup.xml
```

## Troubleshooting

- **Attach fails although everything else passed**: check that the client
  commit equals the baked commit (`code --version` vs the directory under
  `~/.vscode-server/bin/` inside the container). A client auto-update would
  break the match - that is why the test pins `update.mode: none`.
- **Extension cannot see containers** (podman is a Docker-compatible CLI that
  the extension supports on a best-effort basis, per its docs):
  - `dev.containers.dockerPath` must be `podman` and the rootless socket
    `$XDG_RUNTIME_DIR/podman/podman.sock` must exist (script verifies both).
  - Set `dev.containers.logLevel: debug` (done by the script) and watch the
    **Dev Containers** output channel for the exact command that failed.
- **Plan B - Docker CE instead of podman**: rebuild the bundle with
  `--docker`, then in the VM
  `sudo dnf -y install --disablerepo='*' ~/airgap-bundle/rpms-docker/*.rpm`,
  `sudo systemctl enable --now docker`, add your user to the `docker` group,
  remove `dev.containers.dockerPath`/`dockerSocketPath` from settings (or set
  `dockerPath` back to `docker`) and re-run the test.
- **`/dev/disk/by-label/AIRGAPBUNDLE` not found**: run `lsblk -o NAME,LABEL`
  and mount the device carrying the label manually.
- **The VM boots the installer again** after provisioning: the install DVD is
  still attached; eject it as in step 3 (`change-media ... --eject --config`).
