# Changelog

## v1.2.0

- **One command to install and run:** `bash <(curl -fsSL …/main/install.sh)`. The launcher downloads the pinned release into a temporary folder, verifies its checksum, asks for your password and opens the checklist. Nothing is left behind. The script also asks for `sudo` by itself when started without it.
- **Smart defaults:** recommended steps that aren't done yet start selected, so a first run is: Continue, `y`, done.
- **Choose what to do:**
  - A colored checklist with a one-line explanation and a ⭐ Recommended / Optional tag for every step.
  - Nothing is ticked by default; `r` ticks the recommended steps.
  - For scripts: `--only`, `--all`, `--skip` and `--list-steps`.
- **Knows what's already done:**
  - Every step is checked against the real system, including things set up by hand, and marked ✔ done, ◐ partly done or not done.
  - `--status` shows this without changing anything.
- **Safe to run again any time:**
  - The "already completed, use --force" refusal is gone.
  - Existing DNF settings are kept, and a higher `max_parallel_downloads` is never lowered.
  - NVIDIA/Broadcom modules aren't rebuilt when they already exist.
  - Leftover KDE PIM/LibreOffice data is only deleted when that step is picked explicitly.
- **KDE PIM and LibreOffice:** removing each one is a separate, optional step.
- **Flathub:** Flathub becomes Discover's default source with the highest priority. Fedora's duplicate Flatpak sources are disabled instead of deleted, and kept at lower priority if apps are installed from them.
- **Checklist menu:**
  - Arrow keys and Enter/Space to select.
  - Already-done and not-needed steps are shown separately at the top.
  - Steps are grouped into Recommended, Optional and Remove apps.
  - Fits any terminal size (scrolls on small windows) and uses the alternate screen.
  - `?` shows help.
- **Removals are never implied:** `r`, `a` and `--all` don't select them. The review screen shows what each one deletes (with sizes) and which other apps would go too. Real mail or contacts need you to type `delete`.
- **Review screen before starting:** steps, rough total time, data deleted, reboot needed. Questions such as the Secure Boot password are asked before the long part, and keys typed while it runs are discarded, so a stray Enter can't trigger a reboot.
- **Progress:** each step shows `Step 2 of 5 · … · usually 5-30 min` with a progress bar (also in the terminal title) and ends with `✔ Step 2 of 5 done (12 min)`.
- **Summary:** opens with a verdict line, and errors are in plain language. If the script stops early, it says what had already finished and that running it again is safe.
- **Reboot:** recommended at the end only when it's useful (new kernel, drivers, firmware, updates), with the reason.
- **`--help`:** starts with examples.
- **Safety checks:** disk, power and network checks now only run for the steps that need them.

## v1.1.0

First public release. (The script in this release reports `--version` as 1.0.0.)

- One-shot setup for Fedora KDE Plasma 41+ (dnf5, x86_64):
  - DNF tuning and a full system update
  - RPM Fusion with signature verification
  - codecs and hardware video decoding
  - NVIDIA, Broadcom `wl` and VM guest drivers chosen by hardware
  - KDE PIM and LibreOffice removal, including their user data
  - unfiltered Flathub, firmware updates, fstrim and a journal size cap
- Safety:
  - dry-run mode and a single confirmation
  - preflight rails: disk space, AC power, architecture, RPM database, competing package managers
  - removal guards for core desktop packages and dependent apps
  - PackageKit paused during the run
  - a lock and a completion marker
  - a hardened environment and a root-only log
- Secure Boot:
  - akmods signing key with MOK enrollment, interactive or with a generated password
  - drivers are skipped if enrollment can't be queued
- Tests:
  - 144 stubbed hardware and setup scenarios
  - real runs in Fedora 43, 44 and Rawhide containers in CI
