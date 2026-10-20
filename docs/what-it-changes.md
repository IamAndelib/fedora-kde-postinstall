# What the script changes

This page lists everything `fedora-kde-setup.sh` does, every file it touches, and exactly what it deletes. To see the precise commands for *your* computer, run `sudo bash fedora-kde-setup.sh --dry-run`.

**On this page:**
- [Step by step](#step-by-step)
- [Files and settings it changes](#files-and-settings-it-changes)
- [What it deletes](#what-it-deletes)
- [What it does not do](#what-it-does-not-do)
- [Safety checks](#safety-checks)
- [Requirements in detail](#requirements-in-detail)

## Step by step

1. **Checks.** Fedora version, KDE edition, 64-bit Intel/AMD CPU, free disk space, AC power, a healthy package database, no other package manager running, internet access, and which user's data to clean up. A lock stops two copies running at once.
2. **Hardware detection.** CPU, every graphics card (by PCI ID), the Wi-Fi chip, Secure Boot, laptop or desktop, virtual machine or container. You see a summary and **the plan for your computer, then confirm once**.
3. **Faster DNF.** Sets `fastestmirror=True`, `max_parallel_downloads=10` and `defaultyes=True`. Discover's updater (PackageKit) is paused while the script runs, and any update waiting to install at the next reboot is cancelled, because the script installs those updates now.
4. **Full system update** with `dnf upgrade --refresh`.
5. **RPM Fusion and OpenH264.** RPM Fusion is the community repository for software Fedora can't ship.
   - Its free and nonfree release packages are installed **only after their signatures verify** against RPM Fusion's keys as shipped by Fedora (`distribution-gpg-keys`).
   - It also enables Fedora's Cisco OpenH264 repository.
6. **Codecs.** Swaps `ffmpeg-free` for the full `ffmpeg`, and installs the GStreamer bad/ugly/libav/OpenH264 plugins, LAME (MP3), and video thumbnails in Dolphin.
7. **Hardware video decoding.** Intel: `intel-media-driver`. AMD: `mesa-va-drivers-freeworld` (H.264/HEVC). NVIDIA: `libva-nvidia-driver`.
8. **Drivers** for the hardware it found: NVIDIA, Broadcom Wi-Fi, or virtual machine guest tools. See [Hardware and drivers](hardware.md).
9. **Removes KDE PIM and LibreOffice**, plus dependencies nothing else uses, then deletes their data from your home folder. See [What it deletes](#what-it-deletes).
10. **Flathub.**
    - Enables the full Flathub catalogue (Fedora shows a filtered one) and installs Discover's Flatpak support.
    - Removes Fedora's own Flatpak sources if nothing is installed from them, so Discover stops listing apps twice.
11. **Firmware.** Installs available firmware updates with `fwupdmgr`. Skipped in virtual machines.
12. **Maintenance.** Enables the weekly SSD trim (`fstrim.timer`) and caps the system log (journal) at 500 MB.
13. **Summary.** What was done, any warnings, where the log is, how to undo package changes, and Secure Boot steps if needed. Then it offers to reboot.

## Files and settings it changes

| What | Where |
|---|---|
| DNF settings | `/etc/dnf/dnf.conf` (`[main]` section: `fastestmirror`, `max_parallel_downloads`, `defaultyes`) |
| Package sources | RPM Fusion free and nonfree (`/etc/yum.repos.d/rpmfusion-*`); `fedora-cisco-openh264` enabled |
| Packages | System update, codecs and drivers added, KDE PIM and LibreOffice removed. Everything is recorded in `dnf history`. |
| Journal size | `/etc/systemd/journald.conf.d/00-size.conf` (`SystemMaxUse=500M`) |
| Services | `fstrim.timer` enabled; `nvidia-fallback.service` enabled with the NVIDIA driver. PackageKit is paused only while the script runs (a temporary "runtime" mask). |
| Flatpak | `flathub` enabled without Fedora's filter; the `fedora` / `fedora-testing` sources removed if unused |
| Secure Boot | Only with NVIDIA or Broadcom `wl` and Secure Boot on: a driver signing key in `/etc/pki/akmods/`, queued for enrollment |
| Script's own files | `/var/lib/fedora-kde-setup/done` (marks a finished run), `/var/log/fedora-kde-setup.log` (log, readable only by root), `/run/fedora-kde-setup.lock` |
| Generated MOK password | `/root/fedora-kde-setup-mok-password.txt` (readable only by root). Only created when Secure Boot setup ran unattended (`--yes` or no terminal). |

## What it deletes

**Packages:**
- **KDE PIM:** everything matching `kmail*`, `kontact*`, `korganizer*`, `kaddressbook*`, `akregator*`, `kalarm*`, `knotes*`, `kjots*`, `ktnef*`, `merkuro*`, `kdepim*`, `akonadi*`, `grantlee-editor*`, `mbox-importer*`, `pim-data-exporter*`, `pim-sieve-editor*`.
- **LibreOffice:** everything matching `libreoffice*`.
- **Dependencies** of the above that nothing else uses anymore.

**Your data.** These folders and files in your home folder are **deleted for good, with no backup**. They are only deleted if the matching apps were actually removed.

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

On a fresh install these hold nothing important. **If you've already used KMail, KOrganizer, contacts or LibreOffice, back these folders up first.** Nothing else in your home folder is touched, and the deletion runs as your user, not as root.

## What it does not do

- It doesn't change the bootloader (GRUB) or kernel options. The NVIDIA package from RPM Fusion disables the open-source nouveau driver by itself, as RPM Fusion documents.
- It doesn't install themes, browsers or extra apps, and doesn't touch your desktop settings.
- It adds no software sources other than **RPM Fusion** and **Flathub**: no COPRs and no vendor repositories.
- It sends no telemetry. It only contacts Fedora's and RPM Fusion's mirrors, Flathub, and LVFS (firmware), and skips fwupd's "upload report" step.
- It doesn't touch other users' home folders.

## Safety checks

- **Dry run:** `--dry-run` prints every command without running any.
- **One confirmation:** nothing changes until you approve the plan. With `--yes` there's no question; without a terminal and without `--yes`, it refuses to start.
- **Stops before starting if something's off:** low disk space, running on battery, wrong CPU architecture, a broken package database, or another package manager already running.
- **Verified downloads:**
  - Everything is downloaded over HTTPS only, including redirects.
  - The RPM Fusion release packages must pass a signature check (`rpmkeys --checksig`) against keys shipped by Fedora, and must have the right package name, or the script stops.
- **Removal guard:** before removing anything, it asks DNF what else would be removed.
  - **Core desktop:** if that includes core desktop parts (Plasma, the login screen, KWin, Dolphin, Konsole, NetworkManager, PipeWire, systemd, the kernel), the removal is skipped.
  - **Other apps:** if it includes another app (for example KGpg), you're asked first; with `--yes` it's skipped.
  - **Data follows packages:** data is only deleted for apps that were actually removed.
- **Driver safety:**
  - **Supported drivers only:** it never installs an NVIDIA driver that can't run your card.
  - **Secure Boot:** if the Secure Boot key can't be set up, it skips the driver rather than install one that wouldn't load.
  - **Fallback:** `nvidia-fallback.service` falls back to the open-source driver instead of a black screen.
- **PackageKit (Discover):** if it's busy installing something, the script waits up to 2 minutes, then stops without changing anything. It never interrupts a running installation.
- **No double runs:** a lock stops two copies running at once, and a completion marker stops accidental re-runs (`--force` overrides it).
- **Hardened:** fixed `PATH`, `umask` and locale; inherited shell settings aren't trusted; the log and the password file are readable only by root. See [SECURITY.md](../SECURITY.md).
- **Full log:** every command it ran is in `/var/log/fedora-kde-setup.log`.

## Requirements in detail

| Requirement | Why |
|---|---|
| **Fedora KDE Plasma 41 or newer** (KDE Plasma Desktop edition or KDE spin). CI tests 43, 44 and Rawhide. | It relies on `dnf5`, Fedora's package manager since 41. |
| **64-bit Intel/AMD (x86_64)** | The driver and video packages it installs are x86_64 builds. |
| **A regular user account with `sudo`** | Run it as yourself with `sudo`, not from a root login, so it knows whose home folder to clean up. |
| **Internet connection** | Updates, RPM Fusion and Flathub are downloaded. |
| **6 GB free on `/` (and `/var`), 300 MB free on `/boot`** | Running out of space mid-update is the most common way an update breaks a system. |
| **Laptops: plugged in** | Losing power during an update or firmware flash can leave the computer unable to start. |
| **No other package manager running** | Discover is paused automatically; a running `dnf` must finish first. |
| **15–60 minutes** | Mostly the system update. Building the NVIDIA driver adds about 5 minutes. |
| **Recommended: a backup** | It's a fresh install, but this is still a script making system-wide changes as root. |
