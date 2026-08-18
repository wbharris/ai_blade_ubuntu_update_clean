# ai_blade_ubuntu_update_clean

One **update and cleanup** script for **Ubuntu AI / GPU compute blades** and other apt-based GPU servers.

Same apt safety model as [`debian_ubuntu_update_clean`](https://github.com/wbharris/debian_ubuntu_update_clean), plus GPU-host health checks, vendor-package holds, firmware caution, and container cleanup.

**Version:** `VERSION` file, or `./update-clean.sh --version`. See `CHANGELOG.md` for history.

Vendor-agnostic: not affiliated with any GPU or cluster vendor. Optional tools (a vendor GPU CLI, fabric units, `cmsh`) are used only when already installed.

## What it does

**Update:** fix interrupted installs, then `apt update` / `upgrade` / `full-upgrade` and `apt-get check`.

**Cleanup:** purge autoremove, autoclean, residual configs, old kernels (running + `KERNEL_KEEP` older), Snap/Flatpak when present, journal vacuum, partial apt lists, man/locate DBs, GRUB after kernel changes.

**GPU blade extras (when the tools exist):**
- Host detection and a GPU health report (inventory, driver, utilization, busy processes)
- Hold common GPU/accelerator packages during cleanup
- Block auto-reboot while GPU compute jobs are running
- Docker prune of dangling images (safe default)
- Firmware updates **off** (`SKIP_FIRMWARE=true`) — use site/vendor procedures on managed fleets
- Low-space warning on `/var` (typical container-image volume)

## Usage

```bash
sudo ./update-clean.sh
```

```bash
sudo ./update-clean.sh --dry-run
sudo ./update-clean.sh --check                 # pre-flight + GPU health (needs apt-get/dpkg)
sudo ./update-clean.sh --last
sudo ./update-clean.sh --no-kernel
sudo ./update-clean.sh --with-firmware         # fwupd is off by default
sudo ./update-clean.sh --reboot-if-required    # still blocked if GPUs are busy
sudo ./update-clean.sh --quiet
sudo ./update-clean.sh --verbose
sudo ./update-clean.sh --offline
```

`--dry-run` skips `apt-get update` and logs planned apt commands. It may still use the network for read-only listings.

Everything else (kernels to keep, docker prune, GPU holds, log retention, …) is config, not extra flags. See `update-clean.conf.example`.

Requires **Bash 4+** (`#!/usr/bin/env bash`). Do not run under `/bin/sh`. Package work uses **`apt-get`**, not `apt(8)`.

Run weekly during a maintenance window after draining workloads. Do not use `--reboot-if-required` on multi-tenant blades unless orchestration has already drained GPUs.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | One or more steps failed (count is `FAILURES` in the last-run record) |
| `2` | Update finished; reboot was requested but **deferred** because GPU jobs are still running |

Exit `2` is not a failed update. Monitoring should treat it as “drain GPUs and reboot,” not as a broken run.

### Dependencies

**Required:** `bash` 4+, `apt-get`, `dpkg`, `awk`, `sed`, `grep`, `tar`, `mktemp`, `flock`.

**Recommended (install these):**

| Package / tool | Why |
|----------------|-----|
| `psmisc` (`fuser`) or `lsof` | APT lock-holder detection. Without either, leftover lock files are **not** treated as held (best-effort; `apt-get` still fails if a real lock exists). |
| `jq` | Writes machine-readable `/var/lib/update-clean/last-run.json`. Text last-run is always written. |
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
| `KERNEL_KEEP` | `2` | **Additional** old kernels to keep besides the running one (default: running + 2 older) |
| `REBOOT_IF_REQUIRED` | `false` | Auto-reboot; blocked if GPU jobs are active |

Further keys (`VERBOSITY`, `JOURNAL_VACUUM_TIME`, kernel exclude regexes, …) are documented in `update-clean.conf.example`.

## Logging

- Logs: `/var/log/update-clean/` (directory mode `700`, files `600`). A second instance is refused before a log is created. `--dry-run` still writes a log.
- Last run: `/var/lib/update-clean/last-run`
- JSON (when `jq` is installed): `/var/lib/update-clean/last-run.json` — `schema_version` **2**, plus `gpu_driver`, `gpu_runtime`, counts; `status` may be `success` / `failure` / `reboot_deferred`
- `sudo ./update-clean.sh --last` prints the record and the last 80 log lines
- Tests: `UPDATE_CLEAN_SKIP_LOGS=true` (or `CI=true`) writes under `$TMPDIR` instead of `/var/log`

## Safety

- Root required except `--check` / `--version` / `--last`. `--check` still needs `apt-get`, `dpkg`, and the other required commands.
- Needs at least 2 GB free on `/`, `/var`, `/boot`; warns if `/var` has less than 10 GB
- Keeps the running kernel plus `KERNEL_KEEP` older images (default 2). Purge is skipped unless `dpkg` owns `/boot/vmlinuz-$(uname -r)` — custom/unsigned kernels are left alone.
- Holds the GPU stack during autoremove/purge by default (`HOLD_GPU=true`)
- Non-critical steps do not abort the run
- Auto-reboot refuses while GPU compute processes are active
- APT lock-holder detection needs `fuser` (psmisc) or `lsof`; without them leftover lock files are not treated as held

## Scheduling

Weekly, Sunday 04:00:

```bash
0 4 * * 0 /path/to/update-clean.sh
```

Or the bundled timer:

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

# Inspect
./fleet/update-clean-fleet.sh -f fleet/hosts -- --check

# Deploy + dry-run, 4 nodes at a time; skip busy GPUs
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --parallel 4 -- --dry-run

# Wait up to 1h for GPUs to go idle, then update
./fleet/update-clean-fleet.sh -f fleet/hosts --deploy --drain-mode wait --drain-wait 3600 --
```

Drain modes: `skip` (default), `wait`, `force`. Per-run logs and `summary.tsv` land in `fleet-runs/<timestamp>/` (gitignored).

## Cluster manager hooks

Optional `cmsh` / `pdsh` helpers (Bright-style or compatible):

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

Busy nodes are skipped when `skip_if_gpu_busy=true` (default).

## Supported systems

Ubuntu LTS (and interim) GPU servers, other apt-based Debian derivatives used as AI/ML hosts, and multi-GPU rack blades.

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
.github/workflows/       # ShellCheck + smoke
```

## License

Copyright (C) 2026 wbharris

[GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
