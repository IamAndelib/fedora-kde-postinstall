# Contributing

Thanks for helping. This script runs as root on people's fresh installs, so every change must keep it safe and tested.

## Repository layout

```
fedora-kde-setup.sh          the script (a single file)
fedora-kde-setup.sh.sha256   its checksum; CI fails if this doesn't match
docs/                        user documentation
tests/run.sh                 stubbed scenario suite (no real system changes)
tests/fedora-integration.sh  real run inside a Fedora container
.github/workflows/ci.yml     runs all of the above on every push and weekly
```

## Running the tests

```bash
bash tests/run.sh                 # stubbed scenarios; run with sudo to include the "live" and "pty" modes
bash tests/run.sh -l              # list scenarios
bash tests/run.sh -v 'nvidia*'    # run matching scenarios, showing script output on failure
podman run --rm -v "$PWD:/src:Z" -w /src registry.fedoraproject.org/fedora:44 bash tests/fedora-integration.sh
```

**`tests/run.sh`** runs the script against stubbed system commands and a fake `/sys`, across 144 hardware and setup scenarios (215 runs):
- **Hardware:** every NVIDIA generation, hybrid laptops, Secure Boot states, BIOS boot, Broadcom chips, VMs, containers.
- **Environment:** no terminal, PackageKit busy, low disk, battery.
- **Failure handling:** bad signatures, removal guards, re-runs, interrupted runs.

It never changes the host, and two self-check rows prove it.

**`tests/fedora-integration.sh`** runs the script for real in a disposable Fedora container that has Plasma, KMail and LibreOffice installed, then checks the result. CI runs it for Fedora 43, 44 and Rawhide. **Never run it on a real machine.**

## Test hooks

Environment variables starting with `FKS_` (mainly `FKS_ROOT`, which points the script at a fake root directory) exist only for the test suite.
- **Root runs:** as root, the script only accepts `FKS_ROOT` if that directory is owned by root and writable only by root.
- **Real runs:** never set `FKS_*` variables.

## Before opening a pull request

- `shellcheck fedora-kde-setup.sh tests/*.sh tests/lib/*.sh tests/lib/stub` is clean.
- `bash tests/run.sh` passes. Add a scenario for any new behaviour or bug fix.
- Update the checksum: `sha256sum fedora-kde-setup.sh > fedora-kde-setup.sh.sha256`.
- Update the docs (`README.md`, `docs/`) if behaviour visible to users changed.
- Add a line to `CHANGELOG.md`.
