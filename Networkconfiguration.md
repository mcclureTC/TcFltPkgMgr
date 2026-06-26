# TcFltPkgMgr — Network Configuration Guide

This document describes the physical and logical network requirements for
TcFltPkgMgr, with particular attention to Docker containers running inside
VMware virtual machines.

---

## Physical network topology

```
Internet
    │
    ├── VMware NAT (192.168.223.x)     ← operator PC VMware virtual network
    │       │
    │       ├── Operator PC (Windows)   192.168.223.1 (VMware host adapter)
    │       ├── Beckhoff RT Linux 2     192.168.223.129  (ens33, VMware NAT)
    │       └── Beckhoff RT Linux 3     192.168.223.130  (ens33, VMware NAT)
    │
    ├── PC network (192.168.8.x)       ← physical LAN
    │       ├── PC-1                   192.168.8.101
    │       ├── PC-2                   192.168.8.102
    │       ├── PC-3                   192.168.8.103
    │       ├── PC-4                   192.168.8.104
    │       ├── PC-5                   192.168.8.105
    │       └── Project-Supervisor    192.168.8.100
    │
    └── Project network (192.168.3.x) ← physical LAN
            └── Project-Prg           192.168.3.42
```

---

## Linux VM network interfaces

Each Linux VM (`Beckhoff RT Linux 2`, `Beckhoff RT Linux 3`) has two
network adapters:

| Interface | VMware type | IP | Internet | Purpose |
|-----------|------------|-----|----------|---------|
| `ens33` | NAT (VMnet8) | 192.168.223.x | ✅ via VMware NAT | Management — operator PC connects here |
| `ens34` | Bridged (LAN segment) | 192.168.3.x | ❌ no gateway | Originally for Project network access |

### Important: default route after reboot

After each VM reboot, `systemd-networkd` adds a metric-100 default route
via `ens34`. This route takes priority over `ens33` and breaks Docker
container internet access. Remove it after every reboot:

```bash
sudo ip route del default via 192.168.3.1 dev ens34 metric 100
```

**Verify** with:
```bash
ip route show | grep default
# Should show only: default via 192.168.223.2 dev ens33
```

To make this persistent, add a systemd-networkd drop-in for `ens34`:

```bash
sudo mkdir -p /etc/systemd/network/20-wired.network.d/
sudo tee /etc/systemd/network/20-wired.network.d/no-default-route.conf << 'CONF'
[Network]
UseGateway=no
CONF
sudo systemctl restart systemd-networkd
```

---

## Docker networking on VMware NAT VMs

### The double-NAT problem

Docker's default **bridge networking** creates a virtual network
(`172.17.0.0/16`) on the VM and NATs container traffic through the VM's
IP before it leaves `ens33`. VMware NAT then NATs again from the VM's IP
to the host machine's IP.

**The problem:** VMware NAT only forwards packets sourced from the VM's
own IP (`192.168.223.129`). Docker's MASQUERADE rule is supposed to
rewrite container source IPs (`172.17.x.x`) to the VM's IP before the
packet leaves `ens33` — but the packets are dropped by VMware's virtual
switch before MASQUERADE runs.

**Result:** Containers on the default Docker bridge have no internet
access on these VMs.

### Solution: host networking

Use `--network host` when running containers. This makes the container
share the VM's network stack directly — no bridge, no Docker NAT. The
container has the same IP as the VM (`192.168.223.129`) and full internet
access via `ens33`.

```bash
docker run -d --name my-container \
  --network host \
  --init \
  my-image \
  /usr/sbin/sshd -D -p 2222
```

### Host networking constraints

| Constraint | Detail |
|-----------|--------|
| Port conflicts | Port 22 is taken by the VM's sshd. Each container must use a different port (2222, 2223, 2224 ...) |
| Unique ports | All containers on the same VM share the same network stack — each needs a unique SSH port |
| Ghost processes | When a `--network host` container is removed, its processes can survive on the VM and hold ports. Always use `--init` to prevent this |
| No isolation | Containers can reach everything the VM can reach |

### `--init` flag (required)

Without `--init`, when a container is stopped or removed its sshd process
keeps running on the VM and holds the port. The next container trying to
use the same port will fail to start.

`--init` installs `tini` as PID 1 inside the container, which properly
reaps child processes when the container exits.

```bash
# Always use --init with host networking
docker run -d --name test-ssh-1 \
  --network host --init \
  --restart unless-stopped \
  tcflt-debian-ssh:latest \
  /usr/sbin/sshd -D -p 2222
```

### Port assignment convention

| Container | SSH port |
|-----------|---------|
| First container on VM | 2222 |
| Second container | 2223 |
| Third container | 2224 |
| ... | ... |

TcFltPkgMgr's **Containers → 11. Build + run** shows currently used ports
before prompting, so you can pick the next available one.

---

## Docker image builds on VMs

### DNS during build

Docker builds use `--network host` so the build container uses the VM's
DNS (`systemd-resolved` via `ens33`). Without this flag, the build
container uses Docker's default DNS (`8.8.8.8`) which may not be
reachable on isolated networks.

```bash
docker build --network host -t my-image .
```

### Beckhoff apt mirrors

The Beckhoff Debian base image (`debian:bookworm-slim` as configured by
Beckhoff) includes apt sources pointing to `deb.beckhoff.com` and
`deb-mirror.beckhoff.com`. These require myBeckhoff credentials.

TcFltPkgMgr provides two Dockerfiles:

| File | Apt source | Credentials |
|------|-----------|-------------|
| `docker/Dockerfile.debian-ssh` | Standard `deb.debian.org` | None required |
| `docker/Dockerfile.debian-ssh-beckhoff` | Beckhoff + standard fallback | `apt-config/bhf.conf` (BuildKit secret) |

### `apt-get update` in containers

After a container starts, the apt package list is empty (`rm -rf
/var/lib/apt/lists/*` was run during build to keep the image small).
TcFltPkgMgr runs `apt-get update` before every install to refresh the
list. This adds 1–2 seconds to install operations.

---

## Ansible networking requirements

Ansible runs inside the `tcflt-ansible` Docker container on the **operator
PC** (not on the Linux VMs). It connects to Linux targets via SSH using
a key pair generated at container startup.

| Requirement | Detail |
|------------|--------|
| SSH key | Public key must be in `~/.ssh/authorized_keys` on each Linux target |
| Python | `python3` and `python3-apt` must be installed on each Linux target |
| Sudo | `NOPASSWD: ALL` must be configured for the target user |
| Network | Operator PC must be able to reach target on SSH port (22) |

Use **Setup → select Linux target → 4. Prepare target** to configure all
of these automatically.

---

## SSH connectivity summary

| Target type | From | To | Port | Auth |
|------------|------|----|------|------|
| Windows physical | Operator PC | Target IP | 22 | Password |
| Linux VM | Operator PC | Target IP (ens33) | 22 | Password |
| Docker container (host net) | Operator PC | VM IP (ens33) | 2222+ | Password |
| Ansible → Linux VM | tcflt-ansible container | Target IP | 22 | SSH key |

---

## Troubleshooting

### Container can't install packages (apt-get fails)

1. Check `ens34` metric-100 route: `ip route show | grep default`
2. If `ens34` route is present: `sudo ip route del default via 192.168.3.1 dev ens34 metric 100`
3. Verify internet from VM: `curl -I --max-time 5 http://deb.debian.org/ 2>&1 | head -1`
4. Verify internet from container: `docker exec <container> curl -s --max-time 5 http://deb.debian.org/ -o /dev/null -w "%{http_code}"`

### Container won't start (port already in use)

1. Check which process holds the port: `sudo ss -tlnp | grep 222`
2. Kill ghost sshd processes: `sudo pkill -f "sshd.*-p 22[0-9][0-9]"`
3. Restart the container: `docker start <container>`

### docker exec fails immediately

Container is probably restarting. Check:
1. `docker ps | grep <container>` — look for "Restarting"
2. `docker run --rm --network host <image> /usr/sbin/sshd -D -p <port> -e` — run interactively to see error
3. Most common cause: port conflict — use `sudo ss -tlnp | grep <port>`