# Hardware and drivers

The script detects your hardware and installs only what it needs. Run `sudo bash fedora-kde-setup.sh --dry-run` to see what it found and what it would install.

**On this page:**
- [NVIDIA graphics](#nvidia-graphics)
- [Intel and AMD graphics](#intel-and-amd-graphics)
- [Broadcom Wi-Fi](#broadcom-wi-fi)
- [Virtual machines and containers](#virtual-machines-and-containers)
- [Secure Boot](#secure-boot)

## NVIDIA graphics

The driver is chosen from your graphics card's PCI ID, not its marketing name. With two NVIDIA cards, the older one decides.

| Your card | What you get |
|---|---|
| **Turing and newer:** GTX 16xx, RTX 20xx–50xx and later | The NVIDIA driver (`akmod-nvidia`) plus CUDA, suspend/resume support and hardware video decoding |
| **Maxwell, Pascal, Volta:** GTX 9xx, GTX 10xx, Titan X/V… | The legacy driver `akmod-nvidia-580xx`, which keeps supporting these cards when you upgrade Fedora. If it isn't available, the main driver is used where it still supports the card, with a reminder to switch before upgrading Fedora. Otherwise it keeps the open-source driver. |
| **Kepler and older:** GTX 6xx/7xx, nForce, ION… | Keeps the open-source **nouveau** driver. NVIDIA's last driver for these cards (470xx) is no longer maintained. |

- **Driver build:** the driver is built right away for the newest kernel, so it's ready after the reboot.
- **Laptops with two GPUs:** Intel+NVIDIA and AMD+NVIDIA laptops need nothing extra.
- **Fallback:** if the NVIDIA driver ever fails to load, `nvidia-fallback.service` starts the open-source driver, so you still get a desktop instead of a black screen.

## Intel and AMD graphics

These use the drivers built into Linux; nothing extra is needed. The script only adds full hardware video decoding:
- **Intel:** `intel-media-driver`
- **AMD:** `mesa-va-drivers-freeworld` (H.264/HEVC)

## Broadcom Wi-Fi

`broadcom-wl` is installed only if both are true:
- your chip is one that needs it (the BCM4311–BCM4360 family);
- no built-in driver has already brought the card up.

If your Wi-Fi already works, nothing changes.

## Virtual machines and containers

- **Virtual machines** (KVM/QEMU, VMware, VirtualBox, Hyper-V) get guest tools for better integration. GPU drivers and firmware updates are skipped.
- **Containers** skip drivers, firmware and services. This is how the automated tests run it.

## Secure Boot

Secure Boot only lets the computer load drivers signed with a trusted key. The NVIDIA and Broadcom `wl` drivers are built on your computer, so they need your own key. If Secure Boot is on and one of these drivers is needed, the script does this for you:

1. **Creates a signing key** (`kmodgenca`) and asks your computer's firmware to trust it (`mokutil --import`).
2. **Asks you to choose a one-time password.**
   - It's only used once, on the next boot.
   - Nothing appears on screen while you type it.
   - With `--yes` or without a terminal, the script makes one up instead, shows it at the end, and saves it in `/root/fedora-kde-setup-mok-password.txt`.
3. **Builds the driver.** It's signed with that key automatically.

If the key can't be set up, the script skips the driver rather than install one that wouldn't load.

### On the next boot

A blue screen titled **"Perform MOK management"** appears once:

1. Press any key **within 10 seconds**.
2. Choose **Enroll MOK** → **Continue** → **Yes**.
3. Type the one-time password and press **Enter**.
4. Choose **Reboot**.

### If something went wrong

| Problem | Fix |
|---|---|
| **The blue screen didn't appear, or you missed it** | Run `sudo mokutil --import /etc/pki/akmods/certs/public_key.der`, choose a new password, and reboot. |
| **You forgot the password** | Run `sudo mokutil --revoke-import`, then `sudo bash fedora-kde-setup.sh --force` to queue the key again. |
| **Check whether the key is enrolled** | Run `mokutil --test-key /etc/pki/akmods/certs/public_key.der`. It says "is already enrolled" when it is. |
| **NVIDIA still not working** | See [Troubleshooting](troubleshooting.md#nvidia-black-screen-or-nvidia-smi-fails). |
