# What the script changes

This page lists everything `fedora-kde-setup.sh` does, every file it touches, and exactly what it deletes. To see the precise commands for *your* computer, run `sudo bash fedora-kde-setup.sh --dry-run`.

**On this page:**
- [How a run works](#how-a-run-works)
- [The steps](#the-steps)
- [Already set up? What each step does then](#already-set-up-what-each-step-does-then)
- [Files and settings it changes](#files-and-settings-it-changes)
- [What it deletes](#what-it-deletes)
- [What it does not do](#what-it-does-not-do)
- [Safety checks](#safety-checks)
- [Requirements in detail](#requirements-in-detail)

## How a run works

1. **Checks.** Fedora version, KDE edition, 64-bit Intel/AMD CPU, and which user's data it may clean up.
2. **Hardware detection.** CPU, every graphics card (by PCI ID), the Wi-Fi chip, Secure Boot, laptop or desktop, virtual machine or container.
3. **What's already done.** Each step is checked against your real system (see [below](#already-set-up-what-each-step-does-then)), including things you set up yourself.
4. **Checklist.** You tick the steps you want. Nothing is ticked by default; `r` ticks all recommended ones. Steps that don't apply to your computer are greyed out with the reason.
5. **More checks, only for what you picked.**
   - **For steps that change packages:** free disk space, AC power, a healthy package database and no other package manager running.
   - **For steps that download:** internet access.
   - **Always:** a lock stops two copies running at once.
6. **Confirm once,** then the steps run with a progress bar. Discover's updater (PackageKit) is paused while packages change. An update waiting to install at the next reboot is cancelled, because the script installs updates itself.
7. **Summary.** What was done, skipped or not completed, any warnings, where the log is, how to undo package changes, and Secure Boot steps if needed. If a reboot is recommended, it offers one.

## The steps

| Step (ID) | Tag | What it does |
|---|---|---|
| Faster DNF downloads (`dnf`) | Recommended | Sets `fastestmirror=True`, `max_parallel_downloads=10` and `defaultyes=True` in `/etc/dnf/dnf.conf`. Keeps settings that are already there, and never lowers a higher `max_parallel_downloads`. |
| Full system update (`update`) | Recommended | `dnf upgrade --refresh`. |
| Media codecs and video acceleration (`codecs`) | Recommended | Adds RPM Fusion. Its free and nonfree release packages are installed **only after their signatures verify** against RPM Fusion's keys as shipped by Fedora (`distribution-gpg-keys`). Also: enables Fedora's Cisco OpenH264 repository; swaps `ffmpeg-free` for the full `ffmpeg`; installs the GStreamer bad/ugly/libav/OpenH264 plugins, LAME (MP3) and video thumbnails in Dolphin; installs hardware video decoding (Intel: `intel-media-driver`; AMD: `mesa-va-drivers-freeworld`). |
| Drivers (`drivers`) | Recommended | Only when your hardware needs them: NVIDIA, Broadcom Wi-Fi, or virtual machine guest tools. See [Hardware and drivers](hardware.md). NVIDIA and Broadcom drivers come from RPM Fusion and need an up-to-date system, so the system update is ticked automatically along with them. |
| Remove KDE PIM (`pim`) | Optional | Removes KMail, Kontact, KOrganizer, Akonadi and friends, plus dependencies nothing else uses, then deletes their data. See [What it deletes](#what-it-deletes). |
| Remove LibreOffice (`libreoffice`) | Optional | Removes LibreOffice and dependencies nothing else uses, then deletes its settings. |
| Flathub as Discover's app store (`flathub`) | Recommended | See the list below the table. |
| Firmware updates (`firmware`) | Recommended | Installs available firmware updates with `fwupdmgr`. Not offered in virtual machines. |
| SSD trim + smaller system logs (`maintenance`) | Optional | Enables the weekly SSD trim (`fstrim.timer`) and caps the system log (journal) at 500 MB. |

What the Flathub step does:
- installs Flatpak and Discover's Flatpak support if missing;
- enables the full Flathub catalogue (Fedora ships a filtered one) and gives it the highest priority;
- makes Flatpak/Flathub **Discover's default source**, the same as Discover's own "Make default" button;
- **disables** Fedora's own Flatpak sources (`fedora`, `fedora-testing`), so apps aren't listed twice. If you already have apps installed from them, they stay enabled at a lower priority so those apps keep getting updates.

## Already set up? What each step does then

The script looks at your system, not just at its own earlier runs, and shows each step as ✔ done, ◐ partly done, or not done. Running a step that is already done is safe; it only fills in what's missing.

| Step | Counts as done when | Running it again |
|---|---|---|
| `dnf` | `fastestmirror` and `defaultyes` are on and `max_parallel_downloads` is 10 or more | Leaves matching settings untouched and keeps your higher values |
| `update` | `dnf check-upgrade` finds no updates | Installs whatever is new |
| `codecs` | RPM Fusion, full ffmpeg, the GStreamer plugins and your GPU's video driver are installed | Installs only what's missing |
| `drivers` | The driver packages are installed and the module is built for your running kernel | Doesn't rebuild modules that already exist |
| `pim` / `libreoffice` | The apps aren't installed | If the apps are gone but their data is still in your home folder, the step becomes "Remove leftover … data". It's never ticked by `r`, `a` or `--all`, so leftover data is only deleted when you tick it yourself. |
| `flathub` | Flathub is enabled without a filter, Fedora's duplicate source is off, and Flatpak is Discover's default | Fixes only what's missing |
| `firmware` | Can't be known without asking the vendor server; shows when it was last checked | Checks again |
| `maintenance` | `fstrim.timer` is enabled and the journal size cap is in place | Writes the same settings again |

The script also remembers which steps it finished, in `/var/lib/fedora-kde-setup/done`.

## Files and settings it changes

| What | Where |
|---|---|
| DNF settings | `/etc/dnf/dnf.conf` (`[main]` section: `fastestmirror`, `max_parallel_downloads`, `defaultyes`) |
| Package sources | RPM Fusion free and nonfree (`/etc/yum.repos.d/rpmfusion-*`); `fedora-cisco-openh264` enabled |
| Packages | System update, codecs and drivers added, KDE PIM and LibreOffice removed. Everything is recorded in `dnf history`. |
| Journal size | `/etc/systemd/journald.conf.d/00-size.conf` (`SystemMaxUse=500M`) |
| Services | `fstrim.timer` enabled; `nvidia-fallback.service` enabled with the NVIDIA driver. PackageKit is paused only while the script runs (a temporary "runtime" mask). |
| Flatpak | `flathub` enabled without Fedora's filter, with priority 10; the `fedora` / `fedora-testing` sources disabled if unused (or set to priority 1 if apps are installed from them) |
| Discover | `~/.config/discoverrc`: `currentApplicationBackend=flatpak-backend` (Flathub is the default source) |
| Secure Boot | Only with NVIDIA or Broadcom `wl` and Secure Boot on: a driver signing key in `/etc/pki/akmods/`, queued for enrollment |
| Script's own files | `/var/lib/fedora-kde-setup/done` (which steps finished, and when), `/var/log/fedora-kde-setup.log` (log, readable only by root), `/run/fedora-kde-setup.lock` |
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
- **You choose:** nothing is ticked by default, and nothing changes until you confirm your choice. `--yes` needs an explicit `--only` or `--all`.
- **Stops before starting if something's off:** wrong CPU architecture; and, when you picked steps that change packages, low disk space, running on battery, a broken package database, or another package manager already running.
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
- **Safe to run again:** a lock stops two copies running at once. Steps that are already done are shown as done and not ticked; your own settings are kept.
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
