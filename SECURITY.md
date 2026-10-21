# Security

`fedora-kde-setup.sh` runs as root and changes your system. This page explains how it limits that risk and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. You'll get an answer within a week. Include the script version (`--version`), your Fedora version, and steps to reproduce.

## Verifying the script before you run it

Every tagged version has `fedora-kde-setup.sh` together with its SHA-256 checksum. CI checks that the checksum always matches the script:

```bash
mkdir -p ~/fedora-kde-postinstall && cd ~/fedora-kde-postinstall
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.1.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.1.0/fedora-kde-setup.sh.sha256
sha256sum -c fedora-kde-setup.sh.sha256
```

Read it before running it as root, and run `--dry-run` first. Avoid `curl … | sudo bash`, which leaves you no chance to read or verify what you run.

## What runs as root, and how it's constrained

- **Environment.**
  - `PATH` is fixed to `/usr/sbin:/usr/bin`.
  - `umask` is `022` and the locale is `C.UTF-8`.
  - `BASH_ENV`, `ENV`, `CDPATH` and `GREP_OPTIONS` are cleared.
  - `FKS_*` variables are test hooks only. `sudo` strips them by default, so don't pass them through with `sudo -E`.
- **Downloads.**
  - Every download uses HTTPS only, including redirects, with TLS 1.2 or newer.
  - The RPM Fusion release packages are installed only after `rpmkeys --checksig` reports valid signatures. The keys come from Fedora's own signed `distribution-gpg-keys` package.
  - All later packages come through dnf with GPG checking enabled, from Fedora, RPM Fusion and Cisco OpenH264. No other repositories are added.
- **Your home folder.**
  - Deleting KDE PIM and LibreOffice data runs **as your user** (`runuser`), so root never follows symlinks you control.
  - Only the paths listed in the README are touched.
- **Secrets.**
  - A generated Secure Boot (MOK) one-time password is stored only in `/root/fedora-kde-setup-mok-password.txt` (mode 600). The log is root-only (mode 600).
  - The password is only useful at the next boot's enrollment screen, typed at the physical console. It's briefly visible in the process list while `mokutil --generate-hash` runs, which is an accepted trade-off.
- **Downloaded packages.** Release packages are downloaded into a root-only directory under `/tmp` (not `$TMPDIR`). `rpmkeys --checksig` must exit successfully and report exactly `digests signatures OK`, and the package name must match before it's installed.
- **Processes run as you.** They get no access to root's terminal, log or lock file (`runuser` + `setsid`, inherited descriptors closed).
- **Test hooks.** Run as root, the script refuses test mode (`FKS_ROOT`) unless the fake root directory is owned by root and writable only by root.
- **Temporary files.**
  - Created with `mktemp` (root-only) and removed on exit, including on error or Ctrl-C.
  - The lock file lives in root-owned `/run`.
- **No telemetry.**
  - The script contacts only Fedora's and RPM Fusion's mirrors, Flathub, and LVFS (via `fwupdmgr`).
  - fwupd's report upload is skipped (`--no-unreported-check`).

## Scope

In scope:
- anything that lets an unprivileged user or a network attacker gain root or tamper with installed packages through this script;
- anything that makes the script delete or expose data beyond what the README documents.

Out of scope: vulnerabilities in Fedora, RPM Fusion, NVIDIA, Flathub or other upstream packages themselves.
