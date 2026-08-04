# Changelog

All notable changes to this project are documented here.

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
