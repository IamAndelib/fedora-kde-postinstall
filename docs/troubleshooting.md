# Troubleshooting, undo and FAQ

**On this page:**
- [The log](#the-log)
- [Messages and what to do](#messages-and-what-to-do)
- [NVIDIA: black screen or nvidia-smi fails](#nvidia-black-screen-or-nvidia-smi-fails)
- [Undoing changes](#undoing-changes)
- [FAQ](#faq)

## The log

Everything the script did is in `/var/log/fedora-kde-setup.log`. Each command it ran is on a line starting with `$`.

```bash
sudo less /var/log/fedora-kde-setup.log
```

Press `q` to leave. If you report a bug, attach this log, and remove the MOK password line first if there is one.

## Messages and what to do

When a check fails, the script stops **before changing anything**. Fix the cause, then run it again.

| Message | What to do |
|---|---|
| `Only N MiB free on /…` | Free up disk space. Removing old kernels helps: `sudo dnf remove --oldinstallonly`. |
| `Running on battery. Plug in the charger first…` | Plug in the laptop, then run it again. |
| `Another package manager (dnf/rpm) is running…` | Wait for the other update to finish (or reboot), then run it again. |
| `PackageKit (Discover) is still busy after 2 minutes…` | Discover is installing something. Let it finish, then run the script again. The script never interrupts an installation. |
| `This isn't Fedora KDE Plasma…` | The script only supports Fedora KDE Plasma. |
| `This script supports x86_64 only…` | It only supports 64-bit Intel/AMD computers. |
| `Fedora N is too old…` / `dnf5 not found…` | Upgrade to Fedora 41 or newer first. |
| `Can't download https://…rpmfusion…` | Check your internet connection. Right after a new Fedora release, RPM Fusion can take a few days to catch up. |
| `Signature check failed…` / `…isn't in distribution-gpg-keys…` | The script refuses to install packages it can't verify. Run `sudo dnf upgrade --refresh` and try again. If it keeps happening, [open an issue](https://github.com/IamAndelib/fedora-kde-postinstall/issues/new/choose). |
| `The RPM database doesn't respond…` | Run `sudo rpm --rebuilddb`, then try again. |
| `Run this with sudo…` | Start it with `sudo bash fedora-kde-setup.sh`. |
| `Can't tell which user to clean up…` / `Refusing to clean root's home…` | Run it from your normal account with `sudo`, not as root. Or name the user: `--user yourname`. |
| `Choose steps with --only ... or --all` | With `--yes` there's no checklist, so say which steps to run: `--all`, or for example `--only update,codecs`. See `--list-steps`. |
| `No terminal to show the checklist on…` / `No terminal to confirm on…` | You started it without a terminal (for example from a script). Use `--only …` or `--all`, plus `--yes`. |
| `Nothing to do: the selected steps are already done` | Everything you picked is already in place. Use `--force` to redo it anyway. |
| `Step N isn't available: …` | That step doesn't apply to your computer; the reason is shown next to it. |
| `Another run of this script is already in progress` | It's already running in another window. Wait for that one to finish. |
| `Skipped removing KDE PIM…` / `Kept KDE PIM data…` | Removing the apps would have removed something else too, so they and their data were left alone. The message says what, and how to remove them by hand if you still want to. |
| `Kept Fedora's 'fedora' Flatpak source enabled…` | You have apps installed from Fedora's Flatpak source, so it stays on to keep them updated. Flathub is still preferred. |

## NVIDIA: black screen or nvidia-smi fails

1. **With Secure Boot on,** check that the key was enrolled: `mokutil --test-key /etc/pki/akmods/certs/public_key.der`. If it isn't, follow [Secure Boot help](hardware.md#secure-boot).
2. **Check whether the driver build failed:** `ls /var/cache/akmods/nvidia/*.failed.log`. The driver is rebuilt automatically at every boot, so a reboot after updates can fix it.
3. **Fallback:** `nvidia-fallback.service` should have started the open-source driver so you have a desktop to work from.

Other notes:
- **Discover isn't updating:** PackageKit is only paused while the script runs. It's back as soon as the script exits, or after a reboot.

## Undoing changes

Every package change is recorded by DNF. The summary at the end of the run tells you which transactions came from the script.

| To undo | Run |
|---|---|
| A package change | `sudo dnf history list`, then `sudo dnf history undo <ID>` |
| Removal of KDE PIM / LibreOffice | `sudo dnf install @kde-pim @libreoffice` (deleted data doesn't come back) |
| RPM Fusion | Remove the packages you installed from it, then `sudo dnf remove rpmfusion-free-release rpmfusion-nonfree-release` |
| DNF settings | Edit `/etc/dnf/dnf.conf` |
| Journal size cap | `sudo rm /etc/systemd/journald.conf.d/00-size.conf && sudo systemctl restart systemd-journald` |
| Fedora's Flatpak source | `sudo flatpak remote-modify --enable fedora` |
| Flathub as Discover's default | Discover → Settings → pick another source and click "Make default" |
| A Secure Boot key | `sudo mokutil --revoke-import` (before enrolling) or `sudo mokutil --delete /etc/pki/akmods/certs/public_key.der` (after) |

## FAQ

**Can I run it on a system I've been using for a while?**
Only if you don't use KDE PIM or LibreOffice, or you've backed up their data. See [what it deletes](what-it-changes.md#what-it-deletes). Everything else is safe on an existing system.

**Can I keep LibreOffice or KMail?**
Yes. Removing them are optional steps; just don't tick them.

**What is RPM Fusion, and is it safe?**
It's the long-standing community repository for software Fedora can't include, such as full ffmpeg, patented codecs and the NVIDIA driver. Fedora's own documentation points to it. The script checks its signatures before installing it.

**Is it safe to run twice?**
Yes, as often as you like. It shows what's already done, keeps your own settings, and only does what you tick. `--status` shows the overview without changing anything.

**Does it work on Fedora Workstation (GNOME)?**
No. It refuses to run unless the system is Fedora KDE Plasma.

**Can I run it over SSH?**
Yes, but run it inside `tmux` or `screen`. It keeps going if the connection drops, but you'd lose the output and any prompts.
