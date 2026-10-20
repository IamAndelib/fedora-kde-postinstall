# fedora-kde-postinstall

[![CI](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml/badge.svg)](https://github.com/IamAndelib/fedora-kde-postinstall/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**One script that gets a freshly installed Fedora KDE Plasma ready for everyday use.** You run it once, right after installing Fedora. It shows you what it's going to do and asks before changing anything.

## What it does

- **Updates your system**, and makes future downloads faster.
- **Adds the media codecs** Fedora can't ship, so videos and music just play.
- **Installs the right drivers for your hardware**: NVIDIA graphics, Broadcom Wi-Fi, or virtual machine tools.
- **Removes KDE's email/calendar apps (KDE PIM) and LibreOffice**, along with their data.
- **Enables the full Flathub app store** in Discover, updates your firmware, and turns on a few maintenance settings.

Want every detail? See [exactly what it changes](docs/what-it-changes.md).

## Is this for you?

✅ **Yes, if:**
- you have **just installed Fedora KDE Plasma** (version 41 or newer);
- on a normal **64-bit Intel or AMD computer**;
- with an **internet connection**, and your laptop is **plugged in**.

❌ **No, if:**
- you use **KMail, KOrganizer, KAddressBook or LibreOffice**. They are removed, and **their data is deleted**.
- you're on Fedora Workstation (GNOME), Fedora Atomic/Kinoite, or an ARM computer.

You don't need to check the technical details yourself. The script checks everything (Fedora version, disk space, power, etc.) and stops if something isn't right.

## How to install

### 1. Open a terminal

Press the **Meta/Windows key**, type **`Konsole`**, and press **Enter**.

### 2. Download the script

Copy these two lines into Konsole and press **Enter**:

```bash
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.0.0/fedora-kde-setup.sh
curl -fLO https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.0.0/fedora-kde-setup.sh.sha256
```

### 3. Check the download

This makes sure the file arrived complete and unmodified:

```bash
sha256sum -c fedora-kde-setup.sh.sha256
```

You should see `fedora-kde-setup.sh: OK`. **If you don't, stop.** Delete both files and download them again.

### 4. Preview what it will do

This is a dry run: it only shows the plan for your computer and **changes nothing**.

```bash
sudo bash fedora-kde-setup.sh --dry-run
```

> [!NOTE]
> `sudo` asks for **your own password**. Nothing appears on screen while you type it; that's normal. Just type it and press **Enter**.

You'll see your hardware (CPU, graphics, Wi-Fi…) and a numbered list of the steps it would take.

### 5. Run it

```bash
sudo bash fedora-kde-setup.sh
```

1. It shows the same plan and asks `Proceed? [y/N]`. Type **`y`** and press **Enter**.
2. It then works on its own for **about 15–60 minutes**, depending on your internet speed and hardware.

> [!WARNING]
> Keep the Konsole window open, and keep a laptop **plugged in** until it's finished.

### 6. Reboot

At the end it shows a summary and asks `Reboot now? [Y/n]`. Press **Enter** to restart.

## After the reboot

**Most people:** you're done. Videos should play, and Discover now shows apps from Flathub.

**NVIDIA graphics or Broadcom Wi-Fi with Secure Boot on:** a blue screen titled **"Perform MOK management"** appears once. This is expected; it lets your computer trust the new driver.

1. Press any key within 10 seconds.
2. Choose **Enroll MOK** → **Continue** → **Yes**.
3. Type the one-time password you chose during the setup (or the one the script showed you), then choose **Reboot**.

Missed the screen or forgot the password? See [Secure Boot help](docs/hardware.md#secure-boot).

## Options

| Option | What it does |
|---|---|
| `--dry-run` | Show the plan and every command, but change nothing |
| `--yes` | Don't ask for confirmation (for unattended runs) |
| `--no-reboot` | Don't offer to reboot at the end |
| `--force` | Run again on a computer where it already finished |
| `--user NAME` | Clean up this user's data instead of yours |

Example: `sudo bash fedora-kde-setup.sh --yes --no-reboot`

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
