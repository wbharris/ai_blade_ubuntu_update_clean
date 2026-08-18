# Changelog

All notable changes to this project are documented here.

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
