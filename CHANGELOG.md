# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Security
- Pull-request CI no longer runs repository scripts with `sudo`; root dry-run and blade simulations run only on pushes to `main`
- Release workflow refuses to overwrite assets on an existing tag (`--clobber` removed) and checks the tag commit
- Release job uses job-scoped `contents: write`; workflow default is no token permissions
- Dependabot for GitHub Actions; `CODEOWNERS` for CI/release/script paths; `SECURITY.md`

## [1.4.17] - 2026-09-16

### Added
- `tests/run_real_host.sh` — root tests on a live Ubuntu GPU host (`--check`, timed `--dry-run`, hold leak, held-kernel listing, EFI `grub-pc` skip)

### Fixed
- `--dry-run` no longer runs `dpkg --configure -a`
- Bound live-run `sync` with `timeout 15`; skip `sync` in dry-run (LUKS/LVM stall)
- Residual config purge skips `grub-pc` on EFI so it cannot fight `grub-efi-amd64`

## [1.4.16] - 2026-09-16

### Fixed
- Kernel and GPU hold lists treat `hold ok installed` as installed. Temporary `apt-mark hold` during cleanup made Ubuntu 26.04 look like it had no `linux-image-*` packages (same class of bug as debian_ubuntu_update_clean 1.5.9).

## [Unreleased]

### Security
- Pin GitHub Actions to immutable commit SHAs (`actions/checkout` v4.2.2, `ludeeus/action-shellcheck` 2.0.0) instead of `@master` / floating tags
- `bcm/bcm-hooks.sh` rejects category/status/hostname tokens and strips quotes, `$`, and shell metacharacters from drain reasons before interpolating into `cmsh -c`

### Added
- `source update-clean.sh` loads functions only (CLI does not run) for non-root unit tests
- `kernel_related_grep_ere` shared by kernel purge and `tests/test_shell_units.sh`
- Mocked AMD ROCm harness `tests/simulate_amd_blade.sh` (`GPU_VENDOR_PREFER=rocm`)
- `GPU_VENDOR_PREFER=auto|nvidia|rocm|intel` so mixed nodes and the AMD sim do not always take the NVIDIA CLI first

### Changed
- `tests/last-results.html` labeled for the 1.4.15 harness (same 45 mocked 8× H100 cases)
- README testing section states mocked vs real-host coverage
- README: AMD MI300X harness (13 cases) and when `GPU_VENDOR_PREFER=rocm` is required on mixed nodes
- Share `APT_LOCK_PATHS` and `nvidia_cli_ok`; NVIDIA driver query also supplies GPU count (one `nvidia-smi`, CUDA still a second call)

## [1.4.15] - 2026-09-10

### Added
- `--check` and the weekly log report HuggingFace / torch / pip / uv / go-build cache sizes and `docker system df` **without deleting them**. GPU nodes keep those wheels on purpose; weekly wipe would re-download CUDA stacks and stall jobs.

### Fixed
- Cache inventory always returns 0 so a missing Docker socket cannot abort `--check` under `set -e`.
- Do not use `shopt -p` (it exits 1 when an option is off and aborted the function under `set -e`).

## [1.4.14] - 2026-09-08

### Fixed
- `purge_kernel_related` matches kernel version as a dash-delimited field (no longer purges `6.5.0-140*` when removing `6.5.0-14`)
- `tools/md-to-pdf.sh` uses portable `mktemp TEMPLATE` (GNU `--suffix` broke BSD/macOS mktemp)

### Changed
- `tests/last-results.html` refreshed for the 1.4.14 harness (45 passed)

## [1.4.13] - 2026-09-08

### Fixed
- Root runs no longer `source` `$SUDO_USER` home configs (privilege escalation via `~/.config/update-clean.conf`)
- GPU/critical `apt-mark hold` is temporary: snapshot existing holds, unhold this run's packages on EXIT (before releasing the instance lock)
- `hold_critical_packages` respects `--dry-run` (no longer holds `bash`/`coreutils` on a dry-run)
- `--config` warns when the path is missing (optional default confs stay silent)
- Ansible summary uses `stdout_lines[-30:]` (`last(30)` crashed Jinja2)
- `disk_freed_mb` uses `df -P` and counts each filesystem once when `/var`/`/boot` share `/`
- `tools/md-to-pdf.sh` looks for `SIMULATION_RESULTS.md` in the repo root; executable bit set
- Fleet runner: rename `raw` in `run_one_host` (Bash array/scalar clash)
- Simulation harness fails fast with a sudo reminder when not root
- Simulation harness sets `MIN_DISK_KB`/`BOOT_DISK_KB` so dry-run cases are not skipped on small developer disks

### Added
- `--config FILE` (repeatable; root-owned when EUID=0)

### Changed
- Config docs: production path is `/etc` and `/root` only under sudo

## [1.4.12] - 2026-08-18

### Changed
- README: `/boot` hard abort is 100 MB (2 GB still applies to `/` and `/var`); install pin example follows latest; dedicated Testing section
- `SIMULATION_RESULTS.md` marked as a historical 1.4.5 write-up

### Added
- `tests/last-results.html` — last 8× H100 harness report (31 passed)

## [1.4.11] - 2026-08-18

### Fixed
- Kernel purge keeps the **newest** `KERNEL_KEEP` extras by version (oldest prefix removed), not an opaque list-length slice
- Firmware branch polarity documented: `SKIP_FIRMWARE=true` skips fwupd; `--with-firmware` is the allow path
- `/boot` kernel-skip log now says the update continues (hard abort is still `BOOT_DISK_KB` at preflight)
- Summary disk figure is labeled as `/` `/var` `/boot` only

## [1.4.10] - 2026-08-17

### Fixed
- Single-file install no longer warns about a missing sidecar `VERSION` file
- Install docs use `/releases/latest/download/ai_blade_ubuntu_update_clean.tar.gz` (no version pin)

## [1.4.9] - 2026-08-17

### Fixed
- `--version` no longer prints `unknown` after `install` to `/usr/local/sbin` (version is embedded in the script)

## [1.4.8] - 2026-08-17

### Fixed
- `/boot` hard abort is 100 MB (`BOOT_DISK_KB`), not 2 GB — matches small `/boot` on blades and CI runners

### Changed
- `tests/simulate_nvidia_blade.sh` is a real harness (runs `update-clean.sh` against mocked 8× H100 tools)
- First GitHub Release (`v1.4.8`) with a versioned tarball + SHA-256

## [1.4.7] - 2026-08-17

### Changed
- `--quiet` GPU health is one line when idle; full report if jobs are running
- `SKIP_IF_GPU_BUSY=true` (default): abort before apt when GPU jobs are running (**exit 3**). Override with `--no-skip-if-gpu-busy`. Fleet `--drain-mode force` passes the override
- Warn when a vendor GPU CLI is present but no apt packages match the hold list
- Dry-run reports disk freed as `n/a` (no fake negative reclaim)
- Dry-run prints one upgrade preview, not two

## [1.4.6] - 2026-08-17

### Changed
- README matches 1.4.5 behavior: `apt-get`, instance lock, exit 2, inspect modes, fleet/Ansible status
- Fleet `--help` documents `reboot_deferred` and fleet exit codes
- Ansible treats update-clean exit 2 as success (reboot deferred), not a failed task

## [1.4.5] - 2026-08-17

### Fixed / hardened
- Instance cleanup closes the lock fd and leaves `LOCKFILE` in place (no unlink TOCTOU)
- Clearer lock-open errors (missing vs unwritable directory)
- `last-run.json` is written with a builtin encoder when `jq` is missing

### Changed
- Log `Acquired instance lock` after flock
- `--check` help notes apt-get/dpkg and that it does not take the instance lock

## [1.4.4] - 2026-08-17

### Fixed / hardened
- Instance `flock` is taken before log files and preflight, so two runs cannot race
- Warn once if `timeout(1)` is missing (GPU CLIs can hang)

### Changed
- `KERNEL_KEEP` wording: additional old kernels besides the running one (default running + 2)
- Stronger APT lock-probe warning when `fuser`/`lsof` are absent

## [1.4.3] - 2026-08-17

### Changed
- Reboot blocked by busy GPUs is exit **2** (`STATUS=reboot_deferred`), not a generic failure (`1`)
- README lists required/recommended/optional tools, APT lock-probe limits, and exit-code meanings
- Kernel-map miss logs whether `/boot/vmlinuz-$(uname -r)` exists and how many image candidates were seen

## [1.4.2] - 2026-08-17

### Fixed
- `check_debian_based` and `--check` accept `apt-get` without the `apt` wrapper (minimal/container images)

## [1.4.1] - 2026-08-17

### Fixed / hardened (code review)
- `apt_lock_held` no longer treats leftover lock files as held when `fuser`/`lsof` are missing (unknown ≠ locked)
- `LOG_DIR` chmod 700 is required; do not fall back to 755
- `err_trap` only diagnoses; the EXIT trap owns lock teardown and exit
- Clearer proxy logs (redacted URL) when `http(s)_proxy` or apt-config proxy is in use
- Unmatched running kernel always skips purge (covers `uname -r` failure, unsigned/custom images)
- `write_last_run_json` skips cleanly when `jq` is missing
- Read-only upgrade previews use `apt-get -s` instead of `apt list`
- CI / `UPDATE_CLEAN_SKIP_LOGS` writes logs under a private temp dir instead of `/var/log`

## [1.4.0] - 2026-08-17

### Changed
- Slimmer CLI: `--help` and the README list the flags you actually type
- `--check` now includes the GPU health report (the documented inspect command)
- `--last`, `--check`, and `--version` run after config load so they honor config paths
- Kernel keep count, docker prune, GPU holds, console line cap, and `--debug` stay in config (or as hidden compatibility flags)

### Notes
- Still accepted, no longer advertised: `--gpu-only`, `--no-gpu-check`, `--keep-kernels`, `--no-firmware`, `--no-hold-gpu`, `--docker-prune`, `--console-lines`, `--debug`, and the aliases `--status`, `--doctor`, `--no-hold-nvidia`

## [1.3.2] - 2026-08-04

### Security / robustness (review follow-up)
- Config files: `bash -n` syntax check + reject world-writable configs before `source`
- `safe_mktemp` requires real `mktemp` success (no predictable `/tmp/name.$$` fallback)
- Vendor GPU CLIs wrapped with `timeout` (`GPU_CLI_TIMEOUT_SECS`, default 10s)
- Docker prune preview (dangling/total image counts) including dry-run estimates
- Kernel skip paths log clearer reasons (low `/boot`, invalid delcount)
- Kernel exclude regexes validated at startup via `ere_is_valid`

## [1.3.1] - 2026-08-04

### Fixed / hardened (review follow-up)
- CLI overrides and all booleans use `truthy()` instead of executing `$FLAG` as a command
- `dump_debug_state` returns 0 when debug is off (was aborting script under `set -e`)
- `safe_mktemp` prefers `LOG_DIR` / `TMPDIR` with mode 0600 (avoids predictable `/tmp` paths)
- Log directory mode `700` (files remain `600`)
- Kernel list regex character-class fix; empty `grep` pipelines no longer trip ERR trap
- ShellCheck clean at error severity; CI runs `bash -n`, CLI smoke, and root `--dry-run`

## [1.3.0] - 2026-08-04

### Changed (vendor-agnostic rebrand)
- Messaging and docs no longer position the project as vendor-specific (no product branding claims)
- Primary config/CLI: `HOLD_GPU` / `--no-hold-gpu` (`HOLD_NVIDIA` / `--no-hold-nvidia` kept as deprecated aliases)
- last-run fields: `gpu_driver`, `gpu_runtime` (`schema_version` → **2**)
- Platform labels: `gpu-host` / `gpu-server` / `gpu-appliance` instead of vendor product names
- GPU health uses vendor CLIs opportunistically when present; hold list covers multiple common stacks
- Cluster hooks described as optional cmsh/pdsh helpers (not a product integration)

## [1.2.0] - 2026-08-04

### Added (complete remaining code-review items)
- **Verbosity levels**: `quiet` | `normal` | `verbose` via `--quiet`/`-q`, `--verbose`, or `VERBOSITY=`
- **Console apt line cap**: `CONSOLE_APT_MAX_LINES` (default 80; `0` = unlimited) and `--console-lines N`
- Full apt/dpkg output always archived to `APT_LOG`; console may truncate in normal mode
- `run_logged_cmd` / `emit_cmd_output` for consistent capture and failure detail
- **Configurable kernel filters**: `KERNEL_SUFFIX_EXCLUDE_REGEX`, `KERNEL_META_EXCLUDE_REGEX`
- `safe_run` now captures stderr/stdout, shows tails on failure, archives to APT_LOG

### Changed
- `apt_run` / `apt-get update` / autoclean / clean use logged command helper (no silent stderr discard on failures)

## [1.1.1] - 2026-08-04

### Fixed / hardened (code review)
- `write_last_run_json()`: stable `schema_version: 1`, numeric `--argjson` guards, jq errors logged (no silent `2>/dev/null`)
- Explicit `chmod 600` on `LOG_FILE` and `APT_LOG` (and last-run JSON)
- Rename preferred lock helper to `apt_lock_held` (keep `is_apt_locked` alias); report lock holder PIDs via fuser/lsof/ps
- Configurable APT lock wait (`APT_LOCK_WAIT_SECS` / `APT_LOCK_POLL_SECS`)
- Connectivity honors `http_proxy`/`https_proxy` and loads apt `Acquire::*::Proxy` when env unset
- Document kernel meta-package exclusions; `--gpu-only` non-root note
- Configurable `JOURNAL_VACUUM_TIME` (default `30d`)
- Header documents required/optional commands and last-run JSON schema

## [1.1.0] - 2026-08-04

### Added
- `fleet/update-clean-fleet.sh` — multi-node SSH runner with parallel execution, deploy, and GPU drain policies (`skip` / `wait` / `force`)
- `fleet/hosts.example` — inventory template
- `bcm/bcm-hooks.sh` — Base Command Manager helpers (`cmsh` / `pdsh` / Slurm `scontrol`): list category, drain/undrain, maintenance window
- `bcm/cmsh-maintenance.example` — annotated cmsh session notes for SuperPOD windows
- `ansible/update-clean.yml` + `ansible/inventory.example.ini` — optional Ansible deploy/run with busy-GPU skip
- Fleet run summaries under `fleet-runs/<timestamp>/` (gitignored)

### Notes
- BCM command syntax varies by site; hooks are best-effort and support env overrides (`CMSH_BIN`, `BCM_WLM_USE`, etc.)

## [1.0.0] - 2026-08-04

### Added
- Initial release mirrored from `debian_ubuntu_update_clean` 1.4.8
- AI platform detection: DGX OS (`/etc/dgx-release`), HGX/Grace/Hopper/Blackwell DMI, SuperPOD product names, generic NVIDIA GPU hosts
- GPU health report via `nvidia-smi` (inventory, driver, CUDA, utilization, compute apps)
- Service status for `nvidia-fabricmanager`, `nvidia-persistenced`, `nvidia-dcgm` when present
- Optional DCGM discovery (`dcgmi`) and InfiniBand summary (`ibstat` / `ibv_devinfo`)
- `HOLD_NVIDIA` (default true): holds installed NVIDIA/CUDA/fabric/DCGM packages during cleanup
- `SKIP_FIRMWARE` (default true): skips `fwupd` unless `--with-firmware`
- `DOCKER_PRUNE` modes: `none` | `dangling` (default) | `unused` | `all`
- `--gpu-only`, `--no-gpu-check`, `--no-firmware`, `--with-firmware`, `--no-hold-nvidia`, `--docker-prune MODE`
- Auto-reboot guard: refuses reboot when GPU compute processes are active
- Low `/var` free-space warning for container-heavy blades
- Last-run record fields: `AI_PLATFORM`, `NVIDIA_DRIVER`, `CUDA_VERSION`, `GPU_COUNT`, `GPU_BUSY`, `GPU_PROCESS_COUNT`

### Notes
- Core apt update/cleanup, kernel safety, logging, locks, and config model inherited from `debian_ubuntu_update_clean`
- Not a substitute for NVIDIA DGX OS / SuperPOD fabric firmware upgrade procedures
