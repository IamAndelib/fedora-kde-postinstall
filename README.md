# fedora-kde-postinstall

[![CI](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml/badge.svg)](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One command that gets a freshly installed Fedora KDE Plasma ready for everyday use.** It checks your computer, shows what's already set up, and opens a simple checklist with the recommended tweaks already selected. Nothing changes until you confirm.

## What you can choose

| | Tweak | What it does |
|---|---|---|
| ⭐ | Faster DNF downloads | Picks the fastest mirror and downloads 10 files at once. |
| ⭐ | Full system update | Installs all pending security fixes, bug fixes and newer apps. |
| ⭐ | Media codecs | Lets common video and music formats play, using your graphics card. |
| ⭐ | Drivers for your hardware | NVIDIA graphics, Broadcom Wi-Fi, or virtual machine tools (only when needed). |
| ⭐ | Flathub as Discover's app store | Full Flathub catalogue as Discover's default, without Fedora's duplicate apps. |
| ⭐ | Firmware updates | BIOS/UEFI and device updates from your computer's vendor. |
| ○ | Remove KDE PIM | Removes KMail, Kontact, KOrganizer… **and deletes their data**. |
| ○ | Remove LibreOffice | Removes the office suite **and deletes its settings**. |
| ○ | SSD trim + smaller logs | Weekly SSD trim; system logs capped at 500 MB. |

⭐ = **Recommended** for almost everyone · ○ = **Optional**, up to you. Every step is explained in the checklist itself. The two removals are listed separately and are never selected for you.

Want every detail? See [exactly what it changes](docs/what-it-changes.md).

## Is this for you?

✅ **Yes, if:**
- you have **just installed Fedora KDE Plasma** (version 41 or newer);
- on a normal **64-bit Intel or AMD computer**;
- with an **internet connection**, and your laptop is **plugged in**.

❌ **No, if:**
- you're on Fedora Workstation (GNOME), Fedora Atomic/Kinoite, or an ARM computer.

Use KMail or LibreOffice? That's fine: just don't tick those two removal steps.

You don't need to check the technical details yourself. The script checks everything (Fedora version, disk space, power, etc.) and stops if something isn't right.

## Install and run

Open **Konsole** (press the **Meta/Windows key**, type `Konsole`, press **Enter**), paste this line and press **Enter**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/main/install.sh)
```

**That's the only command you need.** It:

1. **Downloads the latest release** into a temporary folder and **verifies it**. Nothing is left in your home folder.
2. **Asks for your password.** Nothing appears while you type it; that's normal.
3. **Checks your computer:** Fedora version, hardware, and what's already set up.
4. **Opens the checklist,** with the **recommended steps already selected:**

```
  Fedora KDE setup: choose what to do
  ✔ Already done: DNF, Codecs
  – Not needed here: Firmware

  RECOMMENDED
  > [x] Full system update  • 12 updates available
        Installs all pending updates: security fixes, bug fixes and newer apps.
    [x] Drivers: NVIDIA GeForce RTX 4060
    [x] Flathub as Discover's app store  ◐ partly done: missing …

  OPTIONAL
    [ ] SSD trim + smaller system logs

  REMOVE APPS YOU DON'T USE  (deletes their data)
    [ ] Remove KDE PIM (KMail, Kontact, KOrganizer...)  • currently installed
    [ ] Remove LibreOffice  • currently installed

    ▶ Continue with 3 selected steps
    Quit without changes

  ↑↓ move · Enter select · r recommended · a all · n none · ? help · q quit
```

**Then:**

1. **Happy with the selection?** Press **↓** until **▶ Continue** is highlighted, then press **Enter**. To change something, move to a step with the arrow keys and press **Enter** to select or unselect it. The removals are never selected for you.
2. **Check the summary.** It shows every step, roughly how long it takes, and exactly what any removal deletes. Type **`y`** and press **Enter**.
3. **Answer any last question** (only NVIDIA/Broadcom with Secure Boot asks for a one-time password), then **let it run**. Each step shows `Step 2 of 5` with a progress bar. A full run takes about 15–60 minutes.
4. **Reboot when it asks** (`Reboot now? (recommended) [Y/n]`, press **Enter**).

> [!WARNING]
> Keep the Konsole window open, and keep a laptop **plugged in** until it's finished.

**Run it again any time with the same line.** It shows what's already done and offers only what's left. Nothing is redone or overwritten unless you select it, and your own settings are kept.

<details>
<summary><b>Prefer to download and check the script yourself?</b></summary>

```bash
mkdir -p ~/fedora-kde-postinstall && cd ~/fedora-kde-postinstall
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.2.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.2.0/fedora-kde-setup.sh.sha256
sha256sum -c fedora-kde-setup.sh.sha256      # must print: fedora-kde-setup.sh: OK
less fedora-kde-setup.sh                     # read it (q to quit)
sudo bash fedora-kde-setup.sh --dry-run      # preview; changes nothing
sudo bash fedora-kde-setup.sh                # run it
```

Afterwards, delete the folder: `rm -rf ~/fedora-kde-postinstall`. The one-line installer does the same download and checksum check for you; you can [read it here](install.sh).

</details>

## After the reboot

**Most people:** you're done. Videos should play, and Discover now shows apps from Flathub.

**NVIDIA graphics or Broadcom Wi-Fi with Secure Boot on:** a blue screen titled **"Perform MOK management"** appears once. This is expected; it lets your computer trust the new driver.

1. Press any key within 10 seconds.
2. Choose **Enroll MOK** → **Continue** → **Yes**.
3. Type the one-time password you chose during the setup (or the one the script showed you), then choose **Reboot**.

Missed the screen or forgot the password? See [Secure Boot help](docs/hardware.md#secure-boot).

## Options

Most people never need these; the checklist does everything. Add them to the end of the install line, for example to only see what's done:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/main/install.sh) --status
```

| Option | What it does |
|---|---|
| `--status` | Show what's already done; change nothing |
| `--dry-run` | Show what would happen and every command, but change nothing |
| `--list-steps` | List the step names used by `--only` and `--skip` |
| `--only dnf,codecs` | Run only these steps, without the checklist |
| `--all` | Run every step that applies and isn't done yet, **except the app removals** |
| `--skip pim,libreoffice` | With `--all`: leave these steps out |
| `--yes` | Don't ask questions (needs `--only` or `--all`) |
| `--force` | With `--only`/`--all`: also redo steps that are already done |
| `--no-reboot` | Don't offer to reboot at the end |
| `--user NAME` | Clean up this user's data instead of yours |

Examples:
- Everything except the removals, no questions: `… install.sh) --all --yes`
- Only remove LibreOffice, no questions: `… install.sh) --only libreoffice --yes`

Step names: `dnf`, `update`, `codecs`, `drivers`, `pim`, `libreoffice`, `flathub`, `firmware`, `maintenance`.

## Something went wrong?

- **The script explains what's wrong** and stops before changing anything if a check fails. Fix the problem it names and run it again.
- **Full log:** `/var/log/fedora-kde-setup.log`. View it with `sudo less /var/log/fedora-kde-setup.log`.
- **Common problems and fixes:** [Troubleshooting](docs/troubleshooting.md).
- **Still stuck?** [Open an issue](https://github.com/IamAndelib/fedora-kde-postinstall/issues/new/choose) and include the log.
- **Found a security problem?** Report it privately; see [SECURITY.md](SECURITY.md).

## Learn more

- [What it changes](docs/what-it-changes.md): every step, every file it touches, exactly what gets deleted, and the safety checks
- [Hardware and drivers](docs/hardware.md): NVIDIA, Intel, AMD, Broadcom, virtual machines, Secure Boot
- [Troubleshooting, undo and FAQ](docs/troubleshooting.md)
- [Security](SECURITY.md) · [Contributing and tests](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE)
