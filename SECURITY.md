# Security

`fedora-kde-setup.sh` runs as root and changes your system. This page explains how it limits that risk and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. You'll get an answer within a week. Include the script version (`--version`), your Fedora version, and steps to reproduce.

## Verifying the script before you run it

**The one-line installer** (`bash <(curl -fsSL …/main/install.sh)`) is a short, readable [launcher](install.sh). It:
1. downloads the **release the launcher names** (a tested version tag, not the moving `main` branch) over HTTPS;
2. checks its SHA-256 checksum, and stops if it doesn't match. The checksum comes from the same place as the script, so it catches incomplete or damaged downloads, not a compromised repository: for that, read the script yourself (below);
3. only then runs it with `sudo`, from a temporary folder that is removed afterwards.

Nothing runs as root before the checksum check. `bash <(curl …)` is used instead of `curl … | sudo bash`: the launcher itself runs as your user, and your keyboard stays connected for the menu.

**To check everything yourself first:**

```bash
mkdir -p ~/fedora-kde-postinstall && cd ~/fedora-kde-postinstall
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.2.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.2.0/fedora-kde-setup.sh.sha256
sha256sum -c fedora-kde-setup.sh.sha256
```

Read it, then run `sudo bash fedora-kde-setup.sh --dry-run` first. CI checks that the checksum file always matches the script.

## What runs as root, and how it's constrained

- **Environment.**
  - `PATH` is fixed to `/usr/sbin:/usr/bin`.
  - `umask` is `022` and the locale is `C.UTF-8`.
  - `CDPATH` and `GREP_OPTIONS` are cleared. Variables bash reads at startup (`BASH_ENV`, `SHELLOPTS`) can't be undone from inside the script; `sudo`'s default environment reset removes them.
  - `FKS_*` variables are test hooks only. `sudo` strips them by default, so don't pass them through with `sudo -E`.
- **Downloads.**
  - Every download uses HTTPS only, including redirects, with TLS 1.2 or newer.
  - The RPM Fusion release packages are installed only after `rpmkeys --checksig` reports valid signatures, checked in a separate keyring that holds only RPM Fusion's key (so no other key you may have imported can vouch for them). The key comes from Fedora's own signed `distribution-gpg-keys` package.
  - All later packages come through dnf with GPG checking enabled, from Fedora, RPM Fusion and Cisco OpenH264. No other repositories are added.
- **Your home folder.**
  - Deleting KDE PIM and LibreOffice data runs **as your user** (`runuser`), so root never deletes through symlinks you control. (Root only reads in your home: it checks which of those folders exist and their size.)
  - Discover's setting (`discoverrc`) is written by `kwriteconfig6` running as you, so your files stay yours.
  - Only the paths listed in the README are touched.
- **Secrets.**
  - A generated Secure Boot (MOK) one-time password (only with `--yes` or without a terminal) is saved in `/root/fedora-kde-setup-mok-password.txt` (mode 600) and shown on the terminal, but never written to the log. The file is deleted once a later run sees the key enrolled. The log is root-only (mode 600).
  - The password is only useful at the next boot's enrollment screen, typed at the physical console. It's briefly visible in the process list while `mokutil --generate-hash` runs, which is an accepted trade-off.
- **Downloaded packages.** Release packages are downloaded into a root-only directory under `/tmp` (not `$TMPDIR`). `rpmkeys --checksig` must exit successfully and report exactly `digests signatures OK`, and the package name must match before it's installed.
- **Processes run as you.** They get no access to root's terminal, log or lock file (`runuser` + `setsid`, inherited descriptors closed).
- **Test hooks.** Run as root, the script refuses test mode (`FKS_ROOT`) unless the fake root directory and every folder above it are owned by root and writable only by root.
- **Output.** File names and other text shown in messages have control characters replaced, so a crafted file name can't send escape sequences to your terminal.
- **Temporary files.**
  - Created with `mktemp` (root-only) and removed on exit, including on error or Ctrl-C. (`--status` and `--dry-run` without root keep their log in your temp folder so you can read it.)
  - The lock file lives in root-owned `/run`.
- **No telemetry.**
  - The script contacts only Fedora's and RPM Fusion's mirrors, Cisco's OpenH264 repository, Flathub, and LVFS (via `fwupdmgr`).
  - fwupd's report upload is skipped (`--no-unreported-check`).

## Scope

In scope:
- anything that lets an unprivileged user or a network attacker gain root or tamper with installed packages through this script;
- anything that makes the script delete or expose data beyond what the README documents.

Out of scope: vulnerabilities in Fedora, RPM Fusion, NVIDIA, Flathub or other upstream packages themselves.
