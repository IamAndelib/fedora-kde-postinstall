# fedora-kde-postinstall

[![CI](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml/badge.svg)](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One script that gets a freshly installed Fedora KDE Plasma ready for everyday use.** It shows what's already set up on your computer, lets you **tick the tweaks you want** from a simple checklist, and asks before changing anything.

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

## How to install

### 1. Open a terminal

Press the **Meta/Windows key**, type **`Konsole`**, and press **Enter**.

### 2. Download the script into its own folder

Copy these lines into Konsole and press **Enter**. They make a folder called `fedora-kde-postinstall` in your home folder, go into it, and download the script and its checksum there:

```bash
mkdir -p ~/fedora-kde-postinstall && cd ~/fedora-kde-postinstall
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.1.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.1.0/fedora-kde-setup.sh.sha256
```

### 3. Check the download

This makes sure the file arrived complete and unmodified:

```bash
sha256sum -c fedora-kde-setup.sh.sha256
```

You should see `fedora-kde-setup.sh: OK`. **If you don't, stop.** Delete the folder (see [Clean up](#clean-up)) and start again from step 2.

> [!TIP]
> Closed Konsole in between? Open it again and run `cd ~/fedora-kde-postinstall` first, so the next commands find the script.

### 4. Preview what it will do

This is a dry run: it only shows the plan for your computer and **changes nothing**.

```bash
sudo bash fedora-kde-setup.sh --dry-run
```

> [!NOTE]
> `sudo` asks for **your own password**. Nothing appears on screen while you type it; that's normal. Just type it and press **Enter**.

You'll see your hardware (CPU, graphics, Wi-Fi…), what's already done, and the commands each step would run.

### 5. Run it

```bash
sudo bash fedora-kde-setup.sh
```

It opens a checklist. What's already done is listed at the top; below it are only the steps you can still choose, grouped. Nothing is selected at first:

```
  Fedora KDE setup: choose what to do
  ✔ Already done: DNF, Codecs
  – Not needed here: Firmware

  RECOMMENDED
  > [ ] Full system update  • 12 updates available
        Installs all pending updates: security fixes, bug fixes and newer apps.
    [ ] Drivers: NVIDIA GeForce RTX 4060
    [ ] Flathub as Discover's app store  ◐ partly done: missing …

  OPTIONAL
    [ ] SSD trim + smaller system logs

  REMOVE APPS YOU DON'T USE  (deletes their data)
    [ ] Remove KDE PIM (KMail, Kontact, KOrganizer...)  • currently installed
    [ ] Remove LibreOffice  • currently installed

    ▶ Continue with 0 selected steps
    Quit without changes

  ↑↓ move · Enter select · r recommended · a all · n none · ? help · q quit
```

1. **Select what you want.**
   - Press **`r`** to select all recommended steps.
   - Use the **arrow keys** to move, and **Enter** (or Space) to select or unselect a step.
   - The removals are never selected for you: `a` ("all") skips them too.
   - Press **`?`** for help, or **`q`** to quit without changing anything.
2. **Move down to `▶ Continue` and press Enter.** A review screen shows:
   - every step, and roughly how long it takes;
   - for removals, exactly how much data gets deleted and which other apps would go too;
   - whether a reboot will be needed.

   Type **`y`** to start. If you chose to remove KDE PIM and there's real mail or contacts in your home folder, you'll also be asked to type `delete`.
3. **Answer anything else now.** Questions such as the Secure Boot password come right after this, before the long part, so you can walk away.
4. **Let it run.** Each step shows `Step 2 of 5 · …` with a progress bar, and ends with `✔ Step 2 of 5 done (12 min)`. A full run takes **about 15–60 minutes**, depending on your internet speed and hardware.

> [!WARNING]
> Keep the Konsole window open, and keep a laptop **plugged in** until it's finished.

### 6. Reboot

At the end it shows a summary. If a reboot is recommended (new kernel, drivers or firmware), it asks `Reboot now? (recommended) [Y/n]`. Press **Enter** to restart.

## Clean up

When you're finished (after the reboot), delete the folder. The script doesn't need it anymore; it keeps nothing important there:

```bash
rm -rf ~/fedora-kde-postinstall
```

Want to run it again later? Just repeat steps 1–3; it always downloads into the same folder.

## Running it again

Run it again any time, as often as you like:
- **It checks your system** and marks what's already done (✔), partly done (◐) or not done yet. This includes things you set up yourself.
- **Done steps** are simply not ticked. You can still tick them to redo them; that's safe.
- **Nothing is undone or overwritten.** Your own settings are kept. For example, if you've set more than 10 parallel downloads, the script keeps your value.

To only see what's done without changing anything: `sudo bash fedora-kde-setup.sh --status`

## After the reboot

**Most people:** you're done. Videos should play, and Discover now shows apps from Flathub.

**NVIDIA graphics or Broadcom Wi-Fi with Secure Boot on:** a blue screen titled **"Perform MOK management"** appears once. This is expected; it lets your computer trust the new driver.

1. Press any key within 10 seconds.
2. Choose **Enroll MOK** → **Continue** → **Yes**.
3. Type the one-time password you chose during the setup (or the one the script showed you), then choose **Reboot**.

Missed the screen or forgot the password? See [Secure Boot help](docs/hardware.md#secure-boot).

## Options

Most people never need these; the checklist does everything.

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
- Everything except the removals, no questions: `sudo bash fedora-kde-setup.sh --all --yes`
- Also remove LibreOffice: `sudo bash fedora-kde-setup.sh --all --yes` then `sudo bash fedora-kde-setup.sh --only libreoffice --yes`

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
