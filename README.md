# fedora-kde-postinstall

A one-time setup script for a **freshly installed Fedora KDE Plasma** system. It updates the system, adds the codecs and drivers your hardware needs, removes KDE's PIM suite and LibreOffice, and applies a few sane defaults. It shows you the full plan for your machine and waits for your OK before changing anything.

```bash
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.0.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.0.0/fedora-kde-setup.sh.sha256
sha256sum -c fedora-kde-setup.sh.sha256   # must print "fedora-kde-setup.sh: OK"
sudo bash fedora-kde-setup.sh --dry-run   # shows exactly what it would do; changes nothing
sudo bash fedora-kde-setup.sh             # does it, after asking once
```

---

## Contents

- [Who this is for](#who-this-is-for)
- [Requirements](#requirements)
- [What it does](#what-it-does)
- [What it changes on your system](#what-it-changes-on-your-system)
- [What it deletes](#what-it-deletes)
- [What it does not do](#what-it-does-not-do)
- [Safety measures](#safety-measures)
- [Usage](#usage)
- [Hardware handling](#hardware-handling)
- [Secure Boot (NVIDIA / Broadcom)](#secure-boot-nvidia--broadcom)
- [Undoing changes](#undoing-changes)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [How it's tested](#how-its-tested)
- [Security](#security)
- [License](#license)

## Who this is for

You **just installed** Fedora KDE Plasma and want it ready for daily use without spending an evening on forum posts. Out of the box, Fedora KDE:

- **can't play many common video and audio formats**, because patent-encumbered codecs aren't included;
- **doesn't include proprietary NVIDIA or Broadcom Wi-Fi drivers**;
- **uses conservative DNF settings**, so downloads are slow;
- **preinstalls KDE PIM** (Akonadi, KMail, Kontact, KOrganizer…) and **LibreOffice**, which many people replace with webmail and other office tools;
- **shows a filtered Flathub** in Discover.

This script fixes all of that in one supervised run.

**It is not for:**
- a system you've been using for a while and customized. It deletes KDE PIM and LibreOffice data; see [What it deletes](#what-it-deletes).
- Fedora Workstation (GNOME), Fedora Atomic/Kinoite, or other distributions. It refuses to run there.
- people who use KMail, KOrganizer, KAddressBook or LibreOffice.

## Requirements

The script checks all of these before it changes anything, and stops if one isn't met.

| Requirement | Why |
|---|---|
| **Fedora KDE Plasma 41 or newer**: the KDE Plasma Desktop edition or the KDE spin. CI tests 43 and 44, plus Rawhide (best effort). | It relies on `dnf5`, Fedora's package manager since 41. |
| **x86_64 (Intel/AMD 64-bit) PC** | The drivers and VA-API packages it installs are x86_64 builds. Other architectures are untested. |
| **A regular user account with `sudo`** | Run it as yourself with `sudo`, not from a root login. It needs to know whose home folder to clean. |
| **Internet connection** | It downloads updates, RPM Fusion and Flathub. |
| **At least 6 GB free on `/`** (and `/var`), **300 MB free on `/boot`** | Running out of space mid-upgrade is the most common way an update breaks a system. |
| **Laptops: plugged in** | Losing power during an upgrade or firmware update can leave the machine unbootable. |
| **No other package manager running** | Discover/PackageKit is paused automatically; a running `dnf` must finish first. |
| **15–60 minutes** | Mostly the system update. The NVIDIA module build adds about 5 minutes. |
| **Recommended: a backup** | It's a fresh install, but this is still a root script making system-wide changes. |

## What it does

Here is everything the script does, in order. Run `--dry-run` to see the exact commands for your machine.

1. **Preflight checks.** Fedora version, edition, architecture, free disk space, AC power, RPM database, no other package manager running, internet access, which user to clean up. A lock stops two copies running at once.
2. **Hardware detection.** CPU, every GPU (by PCI ID), Wi-Fi chip, Secure Boot, laptop or desktop, VM or container. You see a summary and **the plan for your machine, then confirm once**.
3. **DNF tuning.** Sets `fastestmirror=True`, `max_parallel_downloads=10` and `defaultyes=True`. PackageKit (Discover's updater) is paused for the run, and any staged offline update is cancelled.
4. **Full system update** with `dnf upgrade --refresh`.
5. **RPM Fusion and OpenH264.** The RPM Fusion free and nonfree release packages are installed **only after their signatures verify** against RPM Fusion's keys as shipped by Fedora (`distribution-gpg-keys`). It also enables Fedora's Cisco OpenH264 repo.
6. **Codecs.** Swaps `ffmpeg-free` for full `ffmpeg`, and installs the GStreamer bad/ugly/libav/OpenH264 plugins, LAME, and video thumbnails in Dolphin.
7. **Hardware video decoding.** Intel: `intel-media-driver`. AMD: `mesa-va-drivers-freeworld` (H.264/HEVC). NVIDIA: `libva-nvidia-driver`.
8. **Drivers** for the hardware it found: NVIDIA, Broadcom Wi-Fi, or VM guest tools (see [Hardware handling](#hardware-handling)).
9. **Removes KDE PIM and LibreOffice** and their now-unused dependencies, then deletes their data from your home folder (see [What it deletes](#what-it-deletes)).
10. **Flathub.** Enables the full Flathub catalogue and installs Discover's Flatpak backend. It removes Fedora's own Flatpak remotes only if nothing is installed from them, so Discover stops listing apps twice.
11. **Firmware.** Applies available firmware updates with `fwupdmgr`; skipped in VMs.
12. **Maintenance.** Enables the weekly SSD trim (`fstrim.timer`) and caps the systemd journal at 500 MB.
13. **Summary.** What was done, any warnings, the log location, how to undo package changes, and Secure Boot steps if needed. Then it offers a reboot.

## What it changes on your system

| What | Where |
|---|---|
| DNF settings | `/etc/dnf/dnf.conf` (`[main]`: `fastestmirror`, `max_parallel_downloads`, `defaultyes`) |
| Package repositories | RPM Fusion free and nonfree (`/etc/yum.repos.d/rpmfusion-*`), and `fedora-cisco-openh264` enabled |
| Packages | System update; codecs; drivers; KDE PIM and LibreOffice removed. Everything is recorded in `dnf history`. |
| Journal size | `/etc/systemd/journald.conf.d/00-size.conf` (`SystemMaxUse=500M`) |
| Services | `fstrim.timer` enabled; `nvidia-fallback.service` enabled if the NVIDIA driver was installed. PackageKit is paused with a *runtime* mask that is lifted when the script exits. |
| Flatpak | `flathub` remote enabled without Fedora's filter; the `fedora` / `fedora-testing` remotes removed if unused |
| Secure Boot | Only with NVIDIA or Broadcom `wl` and Secure Boot on: an akmods signing key in `/etc/pki/akmods/`, queued for MOK enrollment |
| Script state | `/var/lib/fedora-kde-setup/done` (completion marker), `/var/log/fedora-kde-setup.log` (root-only log), `/run/fedora-kde-setup.lock` |
| Generated MOK password | `/root/fedora-kde-setup-mok-password.txt` (root-only); only created when Secure Boot enrollment ran unattended (`--yes` or no terminal) |

## What it deletes

**Packages:**
- **KDE PIM:** everything matching `kmail*`, `kontact*`, `korganizer*`, `kaddressbook*`, `akregator*`, `kalarm*`, `knotes*`, `kjots*`, `ktnef*`, `merkuro*`, `kdepim*`, `akonadi*`, `grantlee-editor*`, `mbox-importer*`, `pim-data-exporter*`, `pim-sieve-editor*`.
- **LibreOffice:** everything matching `libreoffice*`.
- **Dependencies** of the above that nothing else uses anymore.

**Your data. These are deleted for good, with no backup**, and only when the matching suite was actually removed:

```
KDE PIM:
~/.local/share/akonadi*        ~/.config/akonadi*        ~/.cache/akonadi*
~/.local/share/kmail2          ~/.local/share/local-mail  ~/.local/share/emailidentities
~/.local/share/akregator       ~/.local/share/korganizer  ~/.local/share/kontact
~/.local/share/kaddressbook    ~/.local/share/contacts    ~/.local/share/merkuro
~/.local/share/kalarm          ~/.local/share/knotes      ~/.local/share/apps/korganizer
~/.config/{kmail2,kontact,korganizer,korgac,kaddressbook,akregator,kalarm,kalendarac,merkuro,kdepim,knotes,kjots,sieveeditor}*
~/.config/{emaildefaults,emailidentities,specialmailcollectionsrc,mailtransports,foldermailarchiverc}
~/.config/autostart/*{akonadi,kalarm,korgac}*

LibreOffice:
~/.config/libreoffice          ~/.cache/libreoffice
```

On a fresh install these folders are empty or hold only defaults. **If you've already used KMail, KOrganizer, contacts or LibreOffice, back up these folders first.** Nothing else in your home folder is touched, and the deletion runs as your user, not as root.

## What it does not do

- It doesn't change the kernel command line, the bootloader or GRUB. The RPM Fusion NVIDIA package itself blacklists nouveau, as RPM Fusion documents.
- It doesn't install themes, extra apps or browsers, and doesn't change your desktop settings.
- It adds no third-party repositories other than **RPM Fusion** and **Flathub**: no COPRs, no vendor repos.
- It sends no telemetry and contacts nothing beyond Fedora's and RPM Fusion's mirrors, Flathub and LVFS (firmware). It skips fwupd's "upload report" step.
- It doesn't touch other users' home folders.

## Safety measures

- **Dry run.** `--dry-run` prints every command without running any of them.
- **One confirmation.** Nothing changes until you approve the plan. With `--yes` there's no prompt; without a terminal and without `--yes`, it refuses to start.
- **Preflight safety rails.** It refuses to start on low disk space, on battery, on the wrong architecture, with a broken RPM database, or while another package manager is running.
- **Verified downloads.** All downloads use HTTPS only, including redirects. The RPM Fusion release packages must pass `rpmkeys --checksig` against keys shipped by Fedora, or the script stops.
- **Removal guard.** Before removing anything it asks dnf what the removal would take with it.
  - **Core desktop packages:** if that includes Plasma, the login manager, KWin, Dolphin, Konsole, NetworkManager, PipeWire, systemd or the kernel, that removal is skipped.
  - **Other apps:** if it would also remove another app (for example KGpg), you're asked first; with `--yes` the removal is skipped.
  - **Data follows packages:** data is only deleted for a suite that was actually removed.
- **Driver safety.** It never installs an NVIDIA driver that can't run your GPU. If the Secure Boot key can't be queued, it skips the NVIDIA/Broadcom driver rather than install one that wouldn't load. If the NVIDIA module ever fails to load, `nvidia-fallback.service` brings up nouveau instead of a black screen.
- **No double runs.** A lock file stops concurrent runs; a completion marker stops accidental re-runs (`--force` overrides).
- **Hardened environment.** It runs with a fixed `PATH`, `umask` and locale and doesn't trust inherited shell settings. The log and MOK password files are readable only by root.
- **Full log** of every command in `/var/log/fedora-kde-setup.log`.

## Usage

```bash
sudo bash fedora-kde-setup.sh [options]
```

| Option | Meaning |
|---|---|
| `-n`, `--dry-run` | Print every command it would run; change nothing |
| `-y`, `--yes` | Don't ask for confirmation |
| `-f`, `--force` | Run again on a machine where it already completed |
| `--no-reboot` | Don't offer to reboot at the end |
| `-u`, `--user NAME` | User whose KDE PIM and LibreOffice data gets deleted (default: whoever ran `sudo`) |
| `-V`, `--version` | Show the version |
| `-h`, `--help` | Show help |

**Before running it:**
- **Verify the download** with `sha256sum -c fedora-kde-setup.sh.sha256`. The checksum file is in the repo next to the script, and CI checks that it always matches.
- **Read the script** before running it as root. It's one file with comments.
- **Over SSH**, run it inside `tmux` or `screen`. It keeps going if the connection drops, but you'd lose the output.

## Hardware handling

**NVIDIA.** The driver branch is chosen from each NVIDIA GPU's PCI device ID. If there are several NVIDIA GPUs, the oldest one decides.

| GPU generation | What you get |
|---|---|
| Turing and newer (GTX 16xx, RTX 20xx–50xx…) | `akmod-nvidia` + CUDA + power management (suspend/resume) + VA-API |
| Maxwell, Pascal, Volta (GTX 9xx/10xx, Titan X/V…) | `akmod-nvidia-580xx`, the legacy branch that keeps supporting these cards across Fedora upgrades. If it isn't available, the main driver is used where it still supports them, with a reminder to switch before upgrading Fedora. Otherwise it keeps nouveau. |
| Kepler and older (GTX 6xx/7xx, nForce/ION…) | Keeps the open-source nouveau driver. NVIDIA's 470xx legacy driver is end-of-life. |

The kernel module is built right away for the newest installed kernel. Hybrid Intel+NVIDIA and AMD+NVIDIA laptops need nothing extra.

**Intel / AMD graphics** use the in-kernel drivers; only the VA-API video decoders are added.

**Broadcom Wi-Fi.** `broadcom-wl` is installed only for chips that need it (BCM4311–BCM4360 family) and only when no in-kernel driver has already brought the card up.

**Virtual machines** (KVM/QEMU, VMware, VirtualBox, Hyper-V) get guest tools; GPU drivers and firmware updates are skipped. **Containers** skip drivers, firmware and services; that's how CI runs it.

## Secure Boot (NVIDIA / Broadcom)

With Secure Boot on, kernel modules must be signed by a key your firmware trusts. If the NVIDIA or `wl` driver is needed, the script:

1. creates an akmods signing key (`kmodgenca`) and queues it for enrollment with `mokutil --import`;
2. asks you to **choose a one-time password**. With `--yes` or without a terminal, it generates one instead, shows it, and saves it to `/root/fedora-kde-setup-mok-password.txt`;
3. builds the driver; it gets signed with that key automatically.

**On the next boot** a blue **"Perform MOK management"** screen appears:
1. Press a key within 10 seconds.
2. Choose **Enroll MOK** → **Continue** → **Yes**.
3. Type the one-time password, then choose **Reboot**.

If you miss the screen, run `sudo mokutil --import /etc/pki/akmods/certs/public_key.der` and reboot again. If you forgot the password, run `sudo mokutil --revoke-import`, then run the script again with `--force`.

## Undoing changes

| To undo | Run |
|---|---|
| A package transaction | `sudo dnf history list`, then `sudo dnf history undo <ID>`. The summary tells you which transaction IDs belong to this run. |
| KDE PIM / LibreOffice | `sudo dnf install @kde-pim @libreoffice` (your deleted data doesn't come back) |
| RPM Fusion | `sudo dnf remove rpmfusion-free-release rpmfusion-nonfree-release` (remove the packages installed from it first) |
| DNF settings | Edit `/etc/dnf/dnf.conf` |
| Journal cap | `sudo rm /etc/systemd/journald.conf.d/00-size.conf && sudo systemctl restart systemd-journald` |
| Fedora Flatpak remote | `flatpak remote-add --if-not-exists fedora oci+https://registry.fedoraproject.org` |
| A queued Secure Boot key | `sudo mokutil --revoke-import` (before enrolling) or `sudo mokutil --delete /etc/pki/akmods/certs/public_key.der` (after) |
| Let the script run again | `sudo rm /var/lib/fedora-kde-setup/done`, or pass `--force` |

## Troubleshooting

- **Where's the log?** `/var/log/fedora-kde-setup.log`. Every command is listed there, prefixed with `$`. Attach it to bug reports, and remove the MOK password line if there is one.
- **"Only N MiB free"**: free up space, or remove old kernels with `sudo dnf remove --oldinstallonly`.
- **"Running on battery"**: plug in the charger.
- **"Another package manager is running" / "PackageKit (Discover) is still busy"**: wait for Discover or `dnf` to finish, then run the script again. It never interrupts a running package transaction; it stops before changing anything.
- **"Signature check failed" / "signing key isn't in distribution-gpg-keys"**: the script refuses to install packages it can't verify. Update the system (`sudo dnf upgrade --refresh`) and try again. Right after a new Fedora release, RPM Fusion and its keys can lag a few days.
- **NVIDIA: black screen or `nvidia-smi` fails after reboot**:
  - Check that the MOK key was enrolled: `mokutil --test-key /etc/pki/akmods/certs/public_key.der`.
  - Check the module build: `/var/cache/akmods/nvidia/*.failed.log`.
  - `nvidia-fallback.service` should have brought you up on nouveau.
- **Discover isn't updating**: PackageKit is only paused while the script runs; it's back after the script exits or after a reboot.

## FAQ

**Can I run it on a system I've been using for months?**
Only if you don't use KDE PIM or LibreOffice, or you've backed up their data. Everything else is safe to apply to an existing system.

**Can I keep LibreOffice or KMail?**
Not with this script as-is; removing them is one of its purposes. Install them again afterwards from Discover or Flathub if you change your mind.

**Why RPM Fusion?**
It's the standard, long-running community repository for software Fedora can't ship: full ffmpeg, patented codecs, NVIDIA drivers. Fedora's own documentation points to it.

**Is it safe to run twice?**
Yes. Every step is idempotent. The completion marker just stops accidental re-runs; use `--force` to run it deliberately.

**Does it work on Fedora Workstation (GNOME)?**
No. It refuses to run unless the system is Fedora KDE, or at least has `plasma-workspace` installed.

## How it's tested

- **`tests/run.sh`**: 144 hardware and setup scenarios (215 test runs) against stubbed system commands and a fake `/sys`.
  - **Covers:** every NVIDIA generation, hybrid laptops, Secure Boot states, BIOS boot, Broadcom chips, VMs, containers, no terminal, PackageKit busy, low disk, battery, bad signatures, removal guards, re-runs, interrupted runs.
  - **Modes:** dry-run, plus a sandboxed "live" mode under root/sudo that proves nothing outside the sandbox is touched.
- **`tests/fedora-integration.sh`**: runs the script **for real** inside a Fedora container on a system with Plasma, KMail and LibreOffice installed, then checks the result. GitHub Actions runs it for Fedora 43, 44 and Rawhide on every push and weekly.
- `shellcheck`-clean.

```bash
bash tests/run.sh       # use sudo for the live modes
podman run --rm -v "$PWD:/src:Z" -w /src registry.fedoraproject.org/fedora:44 bash tests/fedora-integration.sh
```

Environment variables starting with `FKS_` exist only for the test suite. Never set them on a real run.

## Security

See [SECURITY.md](SECURITY.md) for what runs as root, how downloads are verified, and how to report a vulnerability privately.

## License

[MIT](LICENSE)
