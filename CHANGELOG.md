# Changelog

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
