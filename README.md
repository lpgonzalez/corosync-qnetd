# corosync-qnetd

A lightweight Docker image that provides a **Corosync QDevice arbitrator**
(`corosync-qnetd`) — the external tie-breaker vote that turns a 2-node Proxmox
VE cluster into a real High-Availability setup.

[![Docker Pulls](https://img.shields.io/docker/pulls/lpgonzalez/corosync-qnetd?cacheSeconds=3600)](https://hub.docker.com/r/lpgonzalez/corosync-qnetd)
[![Image Size](https://img.shields.io/docker/image-size/lpgonzalez/corosync-qnetd/1?cacheSeconds=3600)](https://hub.docker.com/r/lpgonzalez/corosync-qnetd)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Table of contents

- [Why this image exists](#why-this-image-exists)
- [How QDevice works in 2 minutes](#how-qdevice-works-in-2-minutes)
- [Features](#features)
- [Supported tags and architectures](#supported-tags-and-architectures)
- [Quick start](#quick-start)
- [Full setup for Proxmox VE](#full-setup-for-proxmox-ve)
  - [1. Prerequisites](#1-prerequisites)
  - [2. Deploy the qnetd container](#2-deploy-the-qnetd-container)
  - [3. Provide PVE node public keys](#3-provide-pve-node-public-keys)
  - [4. Bootstrap the QDevice from PVE](#4-bootstrap-the-qdevice-from-pve)
  - [5. Verify quorum](#5-verify-quorum)
- [Configuration reference](#configuration-reference)
  - [Volumes](#volumes)
  - [Ports](#ports)
  - [Environment variables](#environment-variables)
- [Backup and restore](#backup-and-restore)
- [Deployment recipes](#deployment-recipes)
  - [QNAP Container Station](#qnap-container-station)
  - [Synology / TrueNAS / generic Docker host](#synology--truenas--generic-docker-host)
  - [Raspberry Pi as the QDevice host](#raspberry-pi-as-the-qdevice-host)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Security notes](#security-notes)
- [FAQ](#faq)
- [License](#license)
- [Credits](#credits)

---

## Why this image exists

Proxmox VE clusters need **quorum** (a majority vote) to take HA decisions
safely. With 2 nodes you have 2 votes total, so if a node can no longer see
the other one, neither side has a majority and the cluster freezes
HA-managed VMs to prevent split-brain.

The official Proxmox-recommended fix is **QDevice**: a small process running
on a third machine that adds one vote, so any single surviving node ends up
with 2 of 3 votes and stays quorate.

But Proxmox documents this assuming you have a third Linux box lying around.
Most homelab and small-business setups don't — they have a NAS. There is **no
official container image** for `corosync-qnetd`, so people end up either
adding a Pi or polluting their NAS host OS with packages. This image solves
exactly that: drop it on any Docker-capable host (QNAP Container Station,
Synology, TrueNAS, Raspberry Pi…) and let the NAS be your arbitrator.

## How QDevice works in 2 minutes

```
   ┌──────────────┐                       ┌──────────────┐
   │   pve01      │◄───── corosync ──────►│   pve02      │
   │  (1 vote)    │                       │  (1 vote)    │
   └──────┬───────┘                       └───────┬──────┘
          │                                       │
          │   corosync-qdevice (on each node)     │
          └────────────┬──────────────────────────┘
                       │
                       │  TCP/5403 (TLS, NSS certs)
                       ▼
              ┌─────────────────────┐
              │  corosync-qnetd     │   <-- this container
              │  (1 vote, arbiter)  │
              └─────────────────────┘
```

| Component | Where it runs | What it does |
|-----------|---------------|--------------|
| `corosync` | each PVE node | cluster messaging bus |
| `corosync-qdevice` | each PVE node | local client of the arbitrator |
| `corosync-qnetd` | **this container** | external arbitrator, gives 1 extra vote |

Quorum math with this image deployed:

| Scenario | Votes available | Quorum (≥2) | Cluster state |
|----------|-----------------|-------------|---------------|
| Everything healthy | 3 (2 nodes + qnetd) | yes | quorate |
| One PVE node down | 2 (1 node + qnetd) | yes | quorate, HA recovers VMs |
| qnetd down, both nodes up | 2 (2 nodes) | yes | quorate, no HA failover possible |
| One PVE node down AND qnetd down | 1 | no | survivor freezes (correct) |

## Features

- Minimal image (`debian:bookworm-slim` + `corosync-qnetd` + `openssh-server`),
  around **120 MB**.
- **SSH server included** so `pvecm qdevice setup <ip>` works out of the box
  — Proxmox uses SSH on port 22 (hard-coded) to install the NSS cert.
- **Pubkey-only SSH**: passwords, PAM and challenge-response disabled.
- **Auto-init**: on first start, generates persistent SSH host keys and
  initialises the qnetd NSS database; on subsequent starts, reuses them.
- **Defensive permission fix**: forces `root:root` ownership on
  `/root/.ssh/authorized_keys` so SSH `StrictModes` doesn't silently reject
  files uploaded via SMB with a non-root UID.
- **Healthcheck** built in (verifies both ports are listening).
- **OCI metadata** labels (source, version, revision, license…).
- **Multi-architecture**: `linux/amd64`, `linux/arm64`.

## Supported tags and architectures

| Tag | Description | Architectures |
|-----|-------------|---------------|
| `1.0.0`, `1.0`, `1`, `latest` | Stable releases | `linux/amd64`, `linux/arm64` |

> Tags follow [Semantic Versioning](https://semver.org/). The `latest` tag
> always points to the newest stable release.

## Quick start

If you just want to see the container running:

```bash
docker run -d \
  --name corosync-qnetd \
  -p 5403:5403/tcp \
  -p 22:22/tcp \
  -v ./configs/qnetd-nssdb:/etc/corosync/qnetd/nssdb \
  -v ./configs/ssh-host-keys:/etc/ssh/keys \
  -v ./configs/ssh-authorized-keys:/root/.ssh \
  lpgonzalez/corosync-qnetd:latest
```

It will start, generate keys, expose `5403/tcp` (qnetd) and `22/tcp` (SSH),
and wait for `pvecm qdevice setup` to populate the NSS database.

This is **not enough by itself** — read the [Full setup for Proxmox
VE](#full-setup-for-proxmox-ve) section for the actual integration with PVE.

## Full setup for Proxmox VE

### 1. Prerequisites

- A working Proxmox VE cluster of 2 nodes (run `pvecm status` — you should
  see both nodes listed and `Quorum: 2`).
- On each PVE node, install the QDevice client:
  ```bash
  apt update && apt install -y corosync-qdevice
  ```
- A third host capable of running Docker, with **TCP/22 and TCP/5403 free**.
  If port 22 is already in use by the host's own SSH (common on NAS
  appliances), see the [QNAP Container Station](#qnap-container-station)
  recipe for two ways to work around it.
- Network connectivity from both PVE nodes to the Docker host on TCP/22 and
  TCP/5403.

### 2. Deploy the qnetd container

Pick the [recipe](#deployment-recipes) that matches your host and bring the
container up. The container will:

1. Generate persistent SSH host keys under `configs/ssh-host-keys/`.
2. Initialise an empty qnetd NSS database under `configs/qnetd-nssdb/`.
3. Start `sshd` and then `corosync-qnetd` in the foreground.

Verify it's healthy:

```bash
docker ps --filter name=corosync-qnetd
# STATUS column should read 'Up X minutes (healthy)' after ~30 s
```

### 3. Provide PVE node public keys

Proxmox bootstraps the QDevice over SSH as `root`. The container only allows
pubkey authentication, so each PVE node's root pubkey needs to be present in
the container's `authorized_keys`.

On **each** PVE node:

```bash
# Generate a key only if one doesn't exist yet:
[ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa
cat /root/.ssh/id_rsa.pub
```

Append the resulting lines into the container's authorized_keys file:

```
<host>/configs/ssh-authorized-keys/authorized_keys
```

One line per node. The container's entrypoint will re-apply the correct
ownership (`root:root`) and permissions (`600`) on the next restart, so it
doesn't matter under which UID the file was uploaded.

> If your file was uploaded via SMB/CIFS or NFS, ownership may show up inside
> the container as UID 1000 or similar. Restart the container so the
> entrypoint can fix it, or run `docker exec corosync-qnetd chown -R
> root:root /root/.ssh`.

Test from each PVE node that SSH actually reaches the container:

```bash
ssh -o IdentitiesOnly=yes -i /root/.ssh/id_rsa root@<qnetd-host> hostname
```

It should print the container's hostname. If it asks to accept the host key,
say yes — that fingerprint corresponds to the keys in
`configs/ssh-host-keys/`.

### 4. Bootstrap the QDevice from PVE

Run **once** from **any one PVE node** (it configures both nodes
automatically via Corosync):

```bash
pvecm qdevice setup <qnetd-host>
```

Behind the scenes, `pvecm` will:

1. SSH into the container, generate cluster certificates.
2. Place them inside `/etc/corosync/qnetd/nssdb/` (your persistent volume).
3. Update `/etc/corosync/corosync.conf` on both PVE nodes to declare the
   QDevice.
4. Reload Corosync.

### 5. Verify quorum

```bash
pvecm status
```

What you want to see:

```
Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
Flags:            Quorate Qdevice

Membership information
----------------------
    Nodeid      Votes    Qdevice Name
0x00000001          1    A,V,NMW <node1>
0x00000002          1    A,V,NMW <node2>
0x00000000          1            Qdevice
```

If `Flags` says `Quorate Qdevice` and `Total votes: 3`, **you're done**.

## Configuration reference

### Volumes

| Container path | Purpose | Persistence required? |
|----------------|---------|-----------------------|
| `/etc/corosync/qnetd/nssdb` | NSS database holding the cluster cert | **Yes** — losing it forces a fresh `pvecm qdevice setup` |
| `/etc/ssh/keys` | SSH host keys (server identity) | Recommended — avoids "host key changed" warnings on PVE after rebuilds |
| `/root/.ssh` | Authorized keys file | **Yes** — your operator/PVE pubkeys live here |

### Ports

| Port | Protocol | Purpose | Notes |
|------|----------|---------|-------|
| 5403 | TCP | Corosync QNet protocol (TLS) | PVE nodes connect here for quorum votes |
| 22 | TCP | OpenSSH server | Only used during `pvecm qdevice setup` — can be firewalled off afterwards |

> Both ports must reach the container from each PVE node. The qnetd port
> (5403) must remain reachable; the SSH port can be closed after the cert
> bootstrap if you want to reduce attack surface.

### Environment variables

This image takes no runtime environment variables — all behaviour is driven
by the persistent NSS database and the authorized_keys file. The
`configs/env/vars.env` slot in the compose file exists as a placeholder for
future extensions.

## Backup and restore

The only **state** worth backing up is the NSS database. Without it you
need to re-run `pvecm qdevice setup`; with it you can rebuild the host from
scratch in minutes.

**Backup:**

```bash
docker compose stop                       # quick stop to avoid mid-write capture
tar czf qnetd-state-$(date +%F).tar.gz \
    configs/qnetd-nssdb \
    configs/ssh-host-keys \
    configs/ssh-authorized-keys
docker compose start
```

A weekly cron entry on the host is usually enough — the NSS database barely
changes once the cluster is set up.

**Restore on a new host:**

```bash
tar xzf qnetd-state-YYYY-MM-DD.tar.gz
docker compose up -d
```

The PVE side needs no action — both nodes will reconnect to the
restored qnetd on the next Corosync poll. If you also moved the qnetd to a
new IP, update Corosync on the PVE side instead:

```bash
pvecm qdevice remove
pvecm qdevice setup <new-qnetd-host>
```

## Deployment recipes

### QNAP Container Station

Container Station on older QNAP models (e.g. TS-x63 series) has two known
quirks that influence the deployment:

1. **It does not reliably build Dockerfiles from the Application UI** — when
   you paste a compose with `build:`, Container Station copies the YAML into
   a temp directory without the rest of your files and the build fails with
   `open Dockerfile: no such file or directory`.
2. **Its `docker` CLI for non-root users can fail to create its `$HOME`** —
   you may see `ERROR: mkdir /share/CACHEDEV1_DATA/.qpkg/.../homes/<user>:
   permission denied` when you run `docker build`.

**Recommended approach:**

1. Use the **pre-built image from Docker Hub** (no Dockerfile needed):
   ```yaml
   services:
     corosync-qnetd:
       image: lpgonzalez/corosync-qnetd:latest
       container_name: corosync-qnetd
       restart: unless-stopped
       ports:
         - "5403:5403/tcp"
         - "22:22/tcp"
       volumes:
         - /share/Container/corosync-qnetd/configs/qnetd-nssdb:/etc/corosync/qnetd/nssdb
         - /share/Container/corosync-qnetd/configs/ssh-host-keys:/etc/ssh/keys
         - /share/Container/corosync-qnetd/configs/ssh-authorized-keys:/root/.ssh
   ```
2. **Free port 22 on the NAS** by moving QTS's own SSH to a custom port (e.g.
   7000) in `Control Panel → Network & File Services → Telnet/SSH`. Once QTS
   SSH is on 7000, the `22:22` mapping above doesn't conflict.
3. Upload the directory (with the compose file) to
   `/share/Container/corosync-qnetd/` via SMB, then create the Application
   in Container Station pointing to that compose.

**Alternative (no DockerHub pull):** Build the image locally on your
workstation and `docker save` / `docker load` it onto the NAS. See the
[Building from source](#building-from-source) section — the included
`Makefile` automates exactly this with `make nas-deploy`.

### Synology / TrueNAS / generic Docker host

Standard `docker compose up -d` works. The only thing to check is that port
22 on the host is either free or you remap the container's SSH to another
host port (e.g. `2222:22`). Note however that **`pvecm qdevice setup` hard-
codes SSH port 22**, so if you remap, you'll need to bootstrap the
certificate by hand:

```bash
# On a PVE node, generate the cert files only (the SSH step will fail):
pvecm qdevice setup <host> 2>/dev/null || true

# Copy /etc/pve/qnetd-cacert.crt to the container via scp -P 2222, then:
ssh -p 2222 root@<host> \
  corosync-qnetd-certutil -s -c /tmp/qnetd-cacert.crt -n <ClusterName>

# Re-run on PVE to finish the setup:
pvecm qdevice setup <host>
```

### Raspberry Pi as the QDevice host

A 30-€ Raspberry Pi running Docker is the cheapest and most reliable
QDevice host. Standard install:

```bash
sudo apt install -y docker.io docker-compose-plugin
git clone https://github.com/lpgonzalez/corosync-qnetd-docker
cd corosync-qnetd-docker
docker compose up -d
```

The image's `arm64` variant runs natively on Pi 3/4/5 with 64-bit Raspberry
Pi OS. Pull is around 50 MB compressed.

## Troubleshooting

### `Permission denied (publickey)` when SSH-ing from PVE

In order of likelihood:

1. **Ownership of `authorized_keys` is not root**. SSH with `StrictModes`
   silently rejects authorized_keys not owned by the target user.
   Fix:
   ```bash
   docker exec corosync-qnetd chown -R root:root /root/.ssh
   docker exec corosync-qnetd chmod 700 /root/.ssh
   docker exec corosync-qnetd chmod 600 /root/.ssh/authorized_keys
   ```
   Then restart the container so the entrypoint cements those permissions.
2. **The pubkey in authorized_keys doesn't match the PVE's `id_rsa.pub`**.
   Compare fingerprints:
   ```bash
   # On the container host:
   docker exec corosync-qnetd ssh-keygen -lf /root/.ssh/authorized_keys
   # On each PVE node:
   ssh-keygen -lf /root/.ssh/id_rsa.pub
   ```
3. **The bind mount points to the wrong host path**. Inspect what's
   actually mounted:
   ```bash
   docker inspect corosync-qnetd --format '{{ range .Mounts }}{{ .Source }} -> {{ .Destination }}{{ "\n" }}{{ end }}'
   ```

### `pvecm qdevice setup` fails with `No route to host`

The container is healthy but the PVE node can't reach it on TCP/22. Usual
causes:

- Firewall on the Docker host blocking 22 inbound.
- The container is on a `macvlan` network whose parent NIC is not the one
  with the cable plugged in.
- A managed switch is dropping the container's new MAC because of
  port-security.

### `exec: corosync-qnetd: not found` in logs (container restart loop)

If you're building from source, make sure your Dockerfile uses Debian
`bookworm` or newer — the binary path moved from `/usr/sbin/corosync-qnetd`
in older releases to `/usr/bin/corosync-qnetd` in current Debian. The
included entrypoint uses `exec corosync-qnetd -f` (no absolute path), which
works on both layouts.

### After a container rebuild, PVE complains about host key changed

The container regenerates SSH host keys only when the volume
`/etc/ssh/keys` is empty. If you didn't persist that volume (or you cleared
it), the new keys are fresh. Clear the stale entry on each PVE node:

```bash
ssh-keygen -R <qnetd-host>
```

### `bind: address already in use` when running `sshd -d` manually

You forgot to kill the entrypoint's sshd first. Use:

```bash
docker exec corosync-qnetd pkill sshd
docker exec -d corosync-qnetd /usr/sbin/sshd -d -e -E /tmp/sshd.log
```

## Building from source

Clone and use the `Makefile`:

```bash
git clone https://github.com/lpgonzalez/corosync-qnetd-docker
cd corosync-qnetd-docker
make help                       # list all targets
```

Common flows:

```bash
# Local single-arch build (current host's architecture):
make build

# Build, save to tar.gz, upload to NAS over SSH and load there in one shot:
make nas-deploy
# (edit nas-user, nas-host, nas-ssh-port, nas-dest at the top of the Makefile first)

# Multi-architecture release to Docker Hub:
docker login
make release
```

The `release` target uses Docker Buildx to produce a manifest list covering
all platforms in the `platforms` variable (default: `linux/amd64,linux/arm64`)
and pushes it under the tags listed in `release-tags` (default: the current
`image-version` and `latest`).

To bump the version, edit `image-version` in the `Makefile` and re-run
`make release`.

## Security notes

- The container ships with `sshd` listening on port 22 with **root login
  permitted via public key only**. Passwords, PAM, and challenge-response
  are disabled. No password is set for root.
- Only put **operator/PVE pubkeys** into `authorized_keys`. Never put
  private keys anywhere inside the container.
- TCP/22 is only needed during the initial `pvecm qdevice setup`. After
  bootstrap, you can firewall it off and the cluster will keep working —
  `corosync-qnetd` itself uses TCP/5403.
- The NSS database in `configs/qnetd-nssdb/` contains the cluster
  certificate authority. Treat it as a secret: do not push it to a public
  git repository (the included `.gitignore` excludes it by default).

## FAQ

**Q: Can I use a single qnetd container to arbitrate multiple PVE clusters?**
Yes. `corosync-qnetd` supports multiple clusters out of the box — each
cluster registers under a distinct name. Just run `pvecm qdevice setup
<host>` from each cluster.

**Q: What happens if the qnetd container goes down?**
The PVE cluster keeps working as long as both PVE nodes can still see each
other (they still have 2 of 3 votes). HA failover stops being possible
until qnetd comes back. No data is lost.

**Q: Do I need to put qnetd on a UPS?**
Not strictly. The worst case (qnetd down + one PVE node down) just freezes
the surviving node, which is the correct behaviour. But if you want HA to
survive a power blip on the NAS, sure — UPS the NAS.

**Q: Can I run qnetd on one of the PVE nodes themselves?**
No. The whole point of QDevice is that it's **external** to the cluster.
A qnetd that dies with one of the nodes provides no quorum benefit.

**Q: Does this image support IPv6?**
Yes. `corosync-qnetd` listens on both stacks by default. Expose the port
accordingly in your compose.

**Q: Why an SSH server inside the container? Isn't that overhead?**
Proxmox's `pvecm qdevice setup` script does the certificate bootstrap over
SSH. Without SSH inside the container you can do it by hand, but the
official tooling won't work. The sshd footprint is ~5 MB and ~3 MB of RAM
when idle.

## License

[MIT](LICENSE) © Lisardo Prieto

## Credits

- The [Cluster Labs](https://clusterlabs.org/) team for `corosync-qnetd`.
- The [Proxmox VE](https://www.proxmox.com/proxmox-ve) project for making
  HA accessible to small infrastructures.
- The Debian project for `bookworm-slim`.

---

**Found a bug or want to contribute?** Open an issue or PR at the
[GitHub repository](https://github.com/lpgonzalez/corosync-qnetd-docker).
