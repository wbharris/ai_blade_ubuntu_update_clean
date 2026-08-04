# ai_blade_ubuntu_update_clean

One clean **update and cleanup** script for **Ubuntu AI compute blades** — NVIDIA **DGX**, **HGX**, **SuperPOD** nodes, and other apt-based GPU servers.

**Derived from** [`debian_ubuntu_update_clean`](https://github.com/wbharris/debian_ubuntu_update_clean) (same core apt safety model), with SuperPOD-oriented GPU health, driver holds, firmware caution, and container cleanup.

**Version:** See the `VERSION` file (or run `./update-clean.sh --version`)

## Main Script

**`update-clean.sh`** — System update + cleanup, with AI blade awareness.

### What it does

**Update (same solid base as debian_ubuntu_update_clean):**
- Fixes interrupted installs and broken packages
- `apt update` / `apt upgrade` / `apt full-upgrade`
- Package cache check (`apt-get check`)

**Cleanup:**
- `apt --purge autoremove`, `autoclean`, `clean`
- Purge residual config files (`apt purge '~c'`)
- Remove old kernels (keeps current + previous for safety)
- Snap / Flatpak cleanup when present
- Vacuum journal logs (last 30 days)
- Clean partial apt lists, rebuild man/locate DBs, update GRUB after kernel changes

**AI blade / SuperPOD extras:**
- Detects **DGX OS**, **HGX**, **SuperPOD**, or generic NVIDIA GPU hosts
- **GPU health report**: `nvidia-smi` inventory, driver/CUDA versions, utilization snapshot
- Detects **busy GPUs** (active compute processes) and **blocks auto-reboot** while jobs run
- Holds installed **NVIDIA / CUDA / fabricmanager / DCGM** packages during cleanup (configurable)
- Status of `nvidia-fabricmanager`, `nvidia-persistenced`, `nvidia-dcgm` when installed
- Optional **DCGM** discovery (`dcgmi`) and **InfiniBand** peek (`ibstat` / `ibv_devinfo`)
- **Docker prune** modes for training image cache (`dangling` default — safe)
- **Firmware updates off by default** (`SKIP_FIRMWARE=true`) — prefer NVIDIA / BCM maintenance windows on SuperPOD
- Low-space warning on `/var` (container image volume)

### Usage

```bash
sudo ./update-clean.sh
```

Options:

```bash
sudo ./update-clean.sh --dry-run
sudo ./update-clean.sh --gpu-only              # health report only
sudo ./update-clean.sh --check                 # pre-flight doctor
sudo ./update-clean.sh --no-kernel
sudo ./update-clean.sh --keep-kernels 3
sudo ./update-clean.sh --no-gpu-check
sudo ./update-clean.sh --with-firmware         # enable fwupd (off by default)
sudo ./update-clean.sh --no-hold-nvidia
sudo ./update-clean.sh --docker-prune dangling # none|dangling|unused|all
sudo ./update-clean.sh --reboot-if-required    # still blocked if GPUs busy
sudo ./update-clean.sh --offline
sudo ./update-clean.sh --last
sudo ./update-clean.sh --debug
```

**Dry-run:** skips `apt-get update` and logs planned `apt-get` commands. It may still use the network for read-only listings.

**SuperPOD tip:** drain workloads (or cordon/drain the node) first, then run during a maintenance window. Prefer **not** using `--reboot-if-required` on multi-tenant blades unless orchestration has already drained GPUs.

Run periodically (recommended weekly), coordinated with cluster job schedules.

### Configuration

Optional config files (sourced in order if present):

- `/etc/update-clean.conf` (must be root-owned)
- When run as root: `/root/.config/update-clean.conf`, `/root/.update-clean.conf`
- When run via `sudo`: also the invoking user's `~/.config/update-clean.conf` and `~/.update-clean.conf`

Example for a SuperPOD compute blade:

```bash
LOG_RETENTION=10
KERNEL_KEEP=2
SKIP_FIRMWARE=true
HOLD_NVIDIA=true
DOCKER_PRUNE=dangling
BACKUP_MODE=false
REBOOT_IF_REQUIRED=false
ADMIN_EMAIL=hpc-ops@example.com
CRITICAL_PACKAGES=(base-files base-passwd bash coreutils util-linux)
```

**Config security:** `/etc/update-clean.conf` must be owned by root. User-level configs are sourced without ownership checks — only use configs you trust.

**Precedence:** Config files load after CLI parsing; explicit flags override config values.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SKIP_FIRMWARE` | `true` | Skip `fwupd` (use NVIDIA/BCM workflows instead) |
| `HOLD_NVIDIA` | `true` | `apt-mark hold` NVIDIA/CUDA-related packages during cleanup |
| `DOCKER_PRUNE` | `dangling` | `none` / `dangling` / `unused` / `all` |
| `JOURNAL_VACUUM_TIME` | `30d` | Passed to `journalctl --vacuum-time` |
| `KERNEL_KEEP` | `2` | Extra kernels kept besides the running one |
| `REBOOT_IF_REQUIRED` | `false` | Auto-reboot; blocked if GPU compute jobs are active |

**last-run.json** includes `schema_version` (currently `1`) plus driver/GPU fields for fleet scrapers.

### Logging & Records

- Detailed logs: `/var/log/update-clean/`
- Last run record: `/var/lib/update-clean/last-run` (includes AI platform, driver, GPU count, busy process count)
- Machine-readable: `/var/lib/update-clean/last-run.json` (when `jq` is installed)
- `sudo ./update-clean.sh --last` shows the record plus the last 80 log lines

### Safety

- Must run as root
- Requires at least 2 GB free on `/`, `/var`, `/boot`
- Warns if `/var` has less than 10 GB free (typical for container hosts)
- Keeps current + previous kernel as fallback
- Holds NVIDIA stack during autoremove/purge by default
- Non-critical steps do not stop the script
- Auto-reboot refuses to run while GPU compute processes are active

### Scheduling

**Cron example (weekly, Sunday 04:00):**

```bash
0 4 * * 0 /path/to/update-clean.sh
```

Or use the included systemd timer:

```bash
sudo cp update-clean.sh /usr/local/sbin/update-clean.sh
sudo cp systemd/update-clean.service systemd/update-clean.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-clean.timer
```

On SuperPOD, prefer fleet orchestration (Base Command Manager, Ansible, etc.) over unattended reboots.

## Fleet (multi-node)

**`fleet/update-clean-fleet.sh`** runs update-clean over SSH across many blades with GPU drain policy and optional parallel deploy.

```bash
# Edit inventory
cp fleet/hosts.example fleet/hosts
# node001 / node002 / ...

# Health only
./fleet/update-clean-fleet.sh -f fleet/hosts -- --gpu-only

# Deploy script + dry-run on 4 nodes at a time; skip busy GPUs
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --parallel 4 --drain-mode skip -- --dry-run

# Wait up to 1h for GPUs to drain, then update
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --drain-mode wait --drain-wait 3600 --

# Comma list
./fleet/update-clean-fleet.sh -H node001,node002 -u ubuntu --deploy -- --check
```

Per-run logs and `summary.tsv` land in `fleet-runs/<timestamp>/` (gitignored).

Drain modes: `skip` (default), `wait`, `force`.

## Base Command Manager (BCM)

On SuperPOD head nodes with **BCM** (`cmsh` / `pdsh`):

```bash
# List category nodes
./bcm/bcm-hooks.sh list-category gpu

# Start maintenance: close devices + WLM drain (Slurm via cmsh or scontrol)
./bcm/bcm-hooks.sh maintenance gpu "weekly update-clean" start

# Fleet update using BCM inventory
./fleet/update-clean-fleet.sh --from-bcm-category gpu --deploy --parallel 4 --drain-mode skip --

# End maintenance
./bcm/bcm-hooks.sh maintenance gpu end
```

See `bcm/cmsh-maintenance.example` for raw `cmsh` notes. Site-specific overrides:

| Env | Default | Purpose |
|-----|---------|---------|
| `CMSH_BIN` | `cmsh` | Path to cmsh |
| `BCM_WLM_USE` | `wlm; use slurm` | cmsh WLM preamble (empty = skip WLM) |
| `BCM_DEVICE_CLOSED_STATUS` | `closed` | Device status while drained |
| `BCM_DEVICE_OPEN_STATUS` | `ok` | Device status after undrain |

## Ansible (optional)

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
# edit [gpu] hosts
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml -e dry_run=true
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml -e 'extra_args=--gpu-only'
```

Busy nodes are skipped when `skip_if_gpu_busy=true` (default).

### Supported systems

- **NVIDIA DGX** (DGX OS — Ubuntu-based)
- **HGX / multi-GPU** Ubuntu blades
- **SuperPOD** compute nodes running Ubuntu
- Standard Ubuntu LTS GPU servers (and other apt derivatives)

Not a replacement for NVIDIA’s official upgrade paths for DGX OS major versions or SuperPOD fabric firmware. Use this for **host package hygiene** and **visibility** between vendor maintenance windows.

### Relation to other repos

| Repo | Focus |
|------|--------|
| `update_clean` | Kali |
| `debian_ubuntu_update_clean` | General Debian/Ubuntu |
| **`ai_blade_ubuntu_update_clean`** | Ubuntu AI blades / SuperPOD |

### Versioning

- Version is in the `VERSION` file
- Script supports `--version`
- See `CHANGELOG.md` for history

### Repository layout

```
update-clean.sh          # main per-node script
VERSION / CHANGELOG.md / README.md / LICENSE
update-clean.conf.example
systemd/                 # optional weekly timer (single node)
fleet/                   # multi-node SSH runner + hosts.example
bcm/                     # Base Command Manager hooks + cmsh examples
ansible/                 # optional playbook + inventory example
.github/workflows/       # CI (ShellCheck)
```

### License

Copyright (C) 2026 wbharris

This project is licensed under the [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
