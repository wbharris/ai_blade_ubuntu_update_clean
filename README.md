# ai_blade_ubuntu_update_clean

One **update and cleanup** script for **Ubuntu AI / GPU compute blades** and other apt-based GPU servers.

Same apt safety model as [`debian_ubuntu_update_clean`](https://github.com/wbharris/debian_ubuntu_update_clean), plus GPU-host health checks, vendor-package holds, firmware caution, and container cleanup.

**Version:** `VERSION` file, or `./update-clean.sh --version`. See `CHANGELOG.md` for history.

Vendor-agnostic: not affiliated with any GPU or cluster vendor. Optional tools (a vendor GPU CLI, fabric units, `cmsh`) are used only when already installed.

## What it does

**Update:** fix interrupted installs, then `apt-get update` / `upgrade` / `full-upgrade` and `apt-get check`. Mutating work uses **`apt-get`**, not `apt(8)`.

**Cleanup:** purge autoremove, autoclean, residual configs, old kernels (running + `KERNEL_KEEP` older), Snap/Flatpak when present, journal vacuum, partial apt lists, man/locate DBs, GRUB after kernel changes.

**GPU blade extras (when the tools exist):**
- Host detection and a GPU health report (inventory, driver, utilization, busy processes)
- Hold common GPU/accelerator packages during cleanup (`HOLD_GPU=true`)
- Block auto-reboot while GPU compute jobs are running (process **exit 2**, not 1)
- Docker prune of dangling images (safe default)
- Firmware updates **off** (`SKIP_FIRMWARE=true`) — use site/vendor procedures on managed fleets
- Low-space warning on `/var` (typical container-image volume)

## Usage

```bash
sudo ./update-clean.sh
```

```bash
sudo ./update-clean.sh --dry-run
sudo ./update-clean.sh --check                 # pre-flight + GPU health (needs apt-get/dpkg; no lock)
sudo ./update-clean.sh --last
sudo ./update-clean.sh --no-kernel
sudo ./update-clean.sh --with-firmware         # fwupd is off by default
sudo ./update-clean.sh --reboot-if-required    # still blocked if GPUs are busy (exit 2)
sudo ./update-clean.sh --quiet
sudo ./update-clean.sh --verbose
sudo ./update-clean.sh --offline
```

`--dry-run` skips `apt-get update` and logs planned apt commands. It may still use the network for read-only listings, and it still writes a log.

Inspect modes (`--check`, `--last`, `--version`) do **not** take the instance lock. A full run takes `/run/update-clean.lock` **before** creating logs so two copies cannot race.

Everything else (kernels to keep, docker prune, GPU holds, log retention, …) is config, not extra flags. See `update-clean.conf.example`.

Requires **Bash 4+** (`#!/usr/bin/env bash`). Do not run under `/bin/sh`.

## Install

**From the latest [GitHub Release](https://github.com/wbharris/ai_blade_ubuntu_update_clean/releases/latest)** (no version pin):

```bash
curl -fsSL -o ai_blade_ubuntu_update_clean.tar.gz \
  https://github.com/wbharris/ai_blade_ubuntu_update_clean/releases/latest/download/ai_blade_ubuntu_update_clean.tar.gz
tar -xzf ai_blade_ubuntu_update_clean.tar.gz
cd ai_blade_ubuntu_update_clean
sudo install -m 755 update-clean.sh /usr/local/sbin/update-clean.sh
sudo cp systemd/update-clean.service systemd/update-clean.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-clean.timer
```

To pin a version, use `.../releases/download/v1.4.10/ai_blade_ubuntu_update_clean-1.4.10.tar.gz` instead.

**From git (development):**

```bash
git clone https://github.com/wbharris/ai_blade_ubuntu_update_clean.git
cd ai_blade_ubuntu_update_clean
sudo install -m 755 update-clean.sh /usr/local/sbin/update-clean.sh
```

This is a host script, not an apt/npm/PyPI package. The published artifact is the versioned tarball on the release.

Run weekly during a maintenance window after draining workloads. Do not use `--reboot-if-required` on multi-tenant blades unless orchestration has already drained GPUs.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | One or more steps failed (count is `FAILURES` in the last-run record) |
| `2` | Update finished; reboot was requested but **deferred** because GPU jobs are still running |
| `3` | Update **skipped** — GPU compute jobs were running (`SKIP_IF_GPU_BUSY`, default true) |

Exit `2` and `3` are not failed updates. Fleet and Ansible treat them as skip / reboot-later, not `fail`.

`--quiet` prints a one-line GPU summary unless jobs are running. `--check` (normal verbosity) still prints the full health report.

### Dependencies

**Required:** `bash` 4+, `apt-get`, `dpkg`, `awk`, `sed`, `grep`, `tar`, `mktemp`, `flock`. `--check` needs the same tools.

**Recommended (install these):**

| Package / tool | Why |
|----------------|-----|
| `psmisc` (`fuser`) or `lsof` | APT lock-holder detection. Without either, leftover lock files are **not** treated as held (`apt-get` still fails if a real lock exists). |
| `jq` | Preferred encoder for `/var/lib/update-clean/last-run.json`. A builtin encoder is used if `jq` is missing. |
| `coreutils` (`timeout`) | Caps vendor GPU CLI hangs. Without it, `nvidia-smi` / `rocm-smi` can block the run. |

**Optional (used only when already installed):** `nvidia-smi` / `rocm-smi` (GPU health and busy-job checks), `fwupdmgr`, `docker`, `flatpak`, `snap`, `needrestart`, `curl` or `wget`, `logger`.

## Configuration

Sourced in order if present:

- `/etc/update-clean.conf` (must be root-owned)
- As root: `/root/.config/update-clean.conf`, `/root/.update-clean.conf`
- Via `sudo`: also the invoking user's `~/.config/update-clean.conf` and `~/.update-clean.conf`

```bash
KERNEL_KEEP=2
SKIP_FIRMWARE=true
HOLD_GPU=true
SKIP_IF_GPU_BUSY=true          # abort before apt if jobs are running (exit 3)
DOCKER_PRUNE=dangling          # none | dangling | unused
REBOOT_IF_REQUIRED=false
```

`/etc/update-clean.conf` must be owned by root and not world-writable. User-level configs are sourced without ownership checks — only use files you trust.

Config loads after CLI parsing; explicit flags win.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SKIP_FIRMWARE` | `true` | Skip `fwupd` |
| `HOLD_GPU` | `true` | Hold GPU/accelerator packages during cleanup (`HOLD_NVIDIA` is a deprecated alias) |
| `DOCKER_PRUNE` | `dangling` | `none` / `dangling` / `unused` |
| `KERNEL_KEEP` | `2` | **Additional** old kernels besides the running one (default: running + 2 older) |
| `REBOOT_IF_REQUIRED` | `false` | Auto-reboot; blocked if GPU jobs are active (exit **2**) |
| `SKIP_IF_GPU_BUSY` | `true` | Do not start apt while GPU jobs are running (exit **3**). Hidden override: `--no-skip-if-gpu-busy` |

Further keys (`VERBOSITY`, `JOURNAL_VACUUM_TIME`, `APT_LOCK_WAIT_SECS`, kernel exclude regexes, …) are documented in `update-clean.conf.example`.

## Logging

- Logs: `/var/log/update-clean/` (directory mode `700`, files `600`)
- Instance lock: `/run/update-clean.lock` (fd is closed on exit; the file is left in place)
- Last run: `/var/lib/update-clean/last-run` (`STATUS` may be `success` / `failure` / `reboot_deferred`)
- JSON: `/var/lib/update-clean/last-run.json` — `schema_version` **2**, plus `gpu_driver`, `gpu_runtime`, counts. Written with `jq` when present, otherwise a builtin encoder
- `sudo ./update-clean.sh --last` prints the record and the last 80 log lines
- Tests: `UPDATE_CLEAN_SKIP_LOGS=true` (or `CI=true`) writes under `$TMPDIR` instead of `/var/log`

## Safety

- Root required except `--check` / `--version` / `--last`
- Needs at least 2 GB free on `/`, `/var`, `/boot`; warns if `/var` has less than 10 GB
- Keeps the running kernel plus `KERNEL_KEEP` older images. Purge is skipped unless `dpkg` owns `/boot/vmlinuz-$(uname -r)` — custom/unsigned kernels are left alone
- Holds the GPU stack during autoremove/purge by default
- Non-critical steps do not abort the run
- Auto-reboot refuses while GPU compute processes are active
- APT lock-holder detection needs `fuser` (psmisc) or `lsof`; without them leftover lock files are not treated as held

## Scheduling

Weekly, Sunday 04:00:

```bash
0 4 * * 0 /path/to/update-clean.sh
```

Or the bundled timer (does **not** pass `--reboot-if-required`):

```bash
sudo cp update-clean.sh /usr/local/sbin/update-clean.sh
sudo cp systemd/update-clean.service systemd/update-clean.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-clean.timer
```

On multi-node fleets, use the fleet runner, `cmsh`/`pdsh`, or Ansible — not unattended reboots.

## Fleet

`fleet/update-clean-fleet.sh` runs the script over SSH with a GPU drain policy.

```bash
cp fleet/hosts.example fleet/hosts

# Inspect (no instance lock on the node)
./fleet/update-clean-fleet.sh -f fleet/hosts -- --check

# Deploy + dry-run, 4 nodes at a time; skip busy GPUs
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --parallel 4 -- --dry-run

# Wait up to 1h for GPUs to go idle, then update
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --drain-mode wait --drain-wait 3600 --
```

Drain modes: `skip` (default), `wait`, `force`. Per-run logs and `summary.tsv` land in `fleet-runs/<timestamp>/` (gitignored).

| Node / row status | Meaning |
|-------------------|---------|
| `ok` / `dry_run` | Succeeded |
| `skipped_busy` | Drain policy skipped the node, or the node script exited **3** (`SKIP_IF_GPU_BUSY`) |
| `reboot_deferred` | Node update finished; reboot blocked (update-clean **exit 2**) |
| `fail` / `deploy_fail` / `drain_error` | Real failure |

Fleet process exits: **0** if nothing failed, **1** if any node failed, **2** if every node was `skipped_busy`. `reboot_deferred` is not a fleet failure.

## Cluster manager hooks

Optional `cmsh` / `pdsh` helpers (Bright-style or compatible). They drain/undrain only; they do not run update-clean themselves.

```bash
./bcm/bcm-hooks.sh list-category gpu
./bcm/bcm-hooks.sh maintenance gpu "weekly update-clean" start
./fleet/update-clean-fleet.sh --from-bcm-category gpu --deploy --parallel 4 --
./bcm/bcm-hooks.sh maintenance gpu end
```

See `bcm/cmsh-maintenance.example`. Overrides: `CMSH_BIN`, `BCM_WLM_USE`, `BCM_DEVICE_CLOSED_STATUS`, `BCM_DEVICE_OPEN_STATUS`.

## Ansible

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml -e dry_run=true
ansible-playbook -i ansible/inventory.ini ansible/update-clean.yml -e 'extra_args=--check'
```

Busy nodes are skipped when `skip_if_gpu_busy=true` (default). update-clean **exit 2** (reboot deferred) is treated as success, not a failed task.

## Supported systems

Ubuntu LTS (and interim) GPU servers, other apt-based Debian derivatives used as AI/ML hosts, and multi-GPU rack blades. Minimal images need `apt-get` (the `apt` wrapper is optional).

Not a replacement for vendor OS major upgrades or fabric/firmware procedures. This is host package hygiene and visibility between site maintenance windows.

| Repo | Focus |
|------|--------|
| `update_clean` | Kali |
| `debian_ubuntu_update_clean` | General Debian/Ubuntu |
| **`ai_blade_ubuntu_update_clean`** | Ubuntu AI / GPU blades |

```
update-clean.sh          # per-node script
VERSION / CHANGELOG.md / README.md / LICENSE
update-clean.conf.example
systemd/                 # optional weekly timer
fleet/                   # SSH runner
bcm/                     # optional cmsh/pdsh hooks
ansible/                 # optional playbook
.github/workflows/       # ShellCheck + release
tests/                   # NVIDIA blade simulation harness
scripts/package-release.sh
```

`./tests/simulate_nvidia_blade.sh` mocks an 8× H100 node and runs the real script (quiet/busy/skip/lock).

## License

Copyright (C) 2026 wbharris

[GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
