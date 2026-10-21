# shellcheck shell=bash
# Fake-system builders. They write into the current scenario's directories:
#   $R  fake root (FKS_ROOT)        $S  stub state (FKS_STATE)
#   $H  home of user "tester"       $T  scenario temp dir
# Variables set by lib/harness.sh before each scenario.
# shellcheck disable=SC2154

readonly FX_KERNEL=6.11.4-301.fc41.x86_64
readonly FX_UID=4242

# Packages installed on the base system.
readonly FX_PIM=(kmail kontact korganizer kaddressbook akregator kalarm merkuro ktnef
    akonadi-server akonadi-import-wizard kdepim-runtime kdepim-addons)
readonly FX_OFFICE=(libreoffice-core libreoffice-writer libreoffice-calc libreoffice-langpack-en)
# Look-alikes and PIM libraries that must not be named in the removal (dnf takes the
# libraries as unused dependencies).
readonly FX_KEEP_PKGS=(kate okular kf6-kcontacts kf6-kcalendarcore kmahjongg kpim6-akonadi-mime kgpg)
readonly FX_SYSTEM_PKGS=(plasma-desktop plasma-workspace sddm kwin dolphin konsole
    plasma-discover plasma-discover-flatpak kernel-core ffmpeg-free systemd dnf5 dnf5-plugins
    rpm distribution-gpg-keys sudo NetworkManager pipewire)

# Entries the script must delete from a home (relative paths, top-level match of each
# PIM_JUNK / OFFICE_JUNK pattern), and look-alikes it must leave alone.
readonly FX_PIM_JUNK=(
    .local/share/akonadi .local/share/akonadi_migration_agent .config/akonadi
    .config/akonadi_ews_resource_0rc .cache/akonadi
    .local/share/kmail2 .local/share/local-mail .local/share/emailidentities
    .local/share/akregator .local/share/korganizer .local/share/kontact
    .local/share/kaddressbook .local/share/contacts .local/share/merkuro
    .local/share/kalarm .local/share/knotes .local/share/apps/korganizer
    .config/kmail2rc .config/kmail2.notifyrc .config/kontactrc .config/korganizerrc
    .config/korgacrc .config/kaddressbookrc .config/akregatorrc .config/kalarmrc
    .config/kalendaracrc .config/merkurorc .config/kdepim-runtimerc .config/knotesrc
    .config/kjotsrc .config/sieveeditorrc
    .config/emaildefaults .config/emailidentities .config/specialmailcollectionsrc
    .config/mailtransports .config/foldermailarchiverc
    .config/autostart/org.kde.akonadi.desktop .config/autostart/kalarm.autostart.desktop
    .config/autostart/org.kde.korgac.desktop
)
readonly FX_OFFICE_JUNK=(.config/libreoffice .cache/libreoffice)
readonly FX_JUNK=("${FX_PIM_JUNK[@]}" "${FX_OFFICE_JUNK[@]}")
readonly FX_DECOYS=(
    .config/keepme Documents/report.odt Documents/kmail2 .config/kdeglobals
    .config/autostart/keep.desktop .local/share/kmail2-backup/mail
    .local/share/apps/other/data .cache/thumbnails/x.png .local/share/plasma/look
)

fx_os_release() {  # KEY=VALUE... (replaces the file)
    mkdir -p "$R/etc"
    printf '%s\n' "$@" > "$R/etc/os-release"
}

fx_conf() {  # KEY=VALUE... stub settings (see lib/stub)
    local kv
    for kv in "$@"; do
        printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >> "$S/conf"
    done
}

fx_add() {  # STATEFILE ITEM...  (append lines)
    local f=$S/$1
    shift
    touch "$f"
    (( $# )) && printf '%s\n' "$@" >> "$f"
    return 0
}

fx_del() {  # STATEFILE ITEM...  (remove exact lines)
    local f=$S/$1 item rest
    shift
    for item in "$@"; do
        rest=$(grep -vxF -- "$item" "$f" || true)
        if [[ -n $rest ]]; then printf '%s\n' "$rest" > "$f"; else : > "$f"; fi
    done
}

fx_missing() {  # COMMAND... absent from PATH for this scenario
    MISSING+=("$@")
}

# PCI devices are laid out like the kernel's sysfs: the real directory lives under
# sys/devices/pci0000:00/ and sys/bus/pci/devices/SLOT is a relative symlink to it.
fx_pci_dir() { printf '%s' "$R/sys/devices/pci0000:00/$1"; }

fx_pci() {  # SLOT CLASS VENDOR DEVICE NAME [DRIVER]
    local slot=$1 class=$2 vendor=$3 device=$4 name=$5 driver=${6:-} desc d
    d=$(fx_pci_dir "$slot")
    mkdir -p "$d" "$R/sys/bus/pci/devices"
    ln -s "../../../devices/pci0000:00/$slot" "$R/sys/bus/pci/devices/$slot"
    printf '%s\n' "$class" > "$d/class"
    printf '%s\n' "$vendor" > "$d/vendor"
    printf '%s\n' "$device" > "$d/device"
    if [[ -n $driver ]]; then
        mkdir -p "$R/sys/bus/pci/drivers/$driver"
        ln -s "../../../bus/pci/drivers/$driver" "$d/driver"
    fi
    case $class in
        0x0300*) desc="VGA compatible controller" ;;
        0x0302*) desc="3D controller" ;;
        0x0380*) desc="Display controller" ;;
        0x0280*) desc="Network controller" ;;
        *)       desc="Device" ;;
    esac
    printf '%s|%s|%s\n' "$slot" "$desc" "$name" >> "$S/lspci"
}

fx_wifi_phy() {  # SLOT [SUBDIR]: a kernel Wi-Fi driver registered a wiphy for it
    mkdir -p "$(fx_pci_dir "$1")/${2:+$2/}ieee80211/phy0"
}

fx_gpu_intel()  { fx_pci 0000:00:02.0 0x030000 0x8086 0x46a6 "Intel Corporation Alder Lake-P GT2 [Iris Xe Graphics] (rev 0c)" i915; }
fx_gpu_amd()    { fx_pci "${1:-0000:03:00.0}" 0x030000 0x1002 0x73ff "Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6600/6600 XT/6600M] (rev c7)" amdgpu; }
fx_gpu_nvidia() {  # DEVICE_ID NAME [CLASS] [SLOT]
    fx_pci "${4:-0000:01:00.0}" "${3:-0x030000}" 0x10de "$1" "$2" nouveau
}
fx_wifi_intel() { fx_pci 0000:00:14.3 0x028000 0x8086 0x51f0 "Intel Corporation Alder Lake-P PCH CNVi WiFi (rev 01)" iwlwifi; }
fx_wifi_broadcom() {  # [DEVICE_ID] [DRIVER]
    fx_pci 0000:02:00.0 0x028000 0x14e4 "${1:-0x43a0}" "Broadcom Inc. and subsidiaries BCM4360 802.11ac Dual Band Wireless Network Adapter (rev 03)" "${2:-}"
}

# Power supplies, as in sysfs: class/power_supply/NAME links to the device directory.
fx_supply() {  # NAME TYPE [KEY=VALUE...]
    local name=$1 type=$2 d kv
    d=$R/sys/devices/LNXSYSTM:00/LNXSYBUS:00/power_supply/$name
    mkdir -p "$d" "$R/sys/class/power_supply"
    ln -sfn "../../devices/LNXSYSTM:00/LNXSYBUS:00/power_supply/$name" "$R/sys/class/power_supply/$name"
    printf '%s\n' "$type" > "$d/type"
    shift 2
    for kv in "$@"; do printf '%s\n' "${kv#*=}" > "$d/${kv%%=*}"; done
}

# A laptop on its charger (the safety rails refuse to run on battery).
fx_battery() {  # [BATTERY_STATUS] [AC_ONLINE]
    fx_supply BAT0 Battery "status=${1:-Charging}" capacity=80
    fx_supply AC Mains "online=${2:-1}"
}

fx_efivar_secureboot() {  # 0|1
    local dir=$R/sys/firmware/efi/efivars
    mkdir -p "$dir"
    # 4 bytes of attributes, then the value byte.
    if [[ $1 == 1 ]]; then
        printf '\x06\x00\x00\x00\x01'
    else
        printf '\x06\x00\x00\x00\x00'
    fi > "$dir/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
}

fx_marker() {  # DATE
    mkdir -p "$R/var/lib/fedora-kde-setup"
    printf '%s\n' "$1" > "$R/var/lib/fedora-kde-setup/done"
}

fx_session_bus() {  # creates $R/run/user/$FX_UID/bus as a real unix socket
    local dir=$R/run/user/$FX_UID
    mkdir -p "$dir"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$dir/bus"
}

fx_home_junk() {  # HOME_DIR
    local home=$1 p
    for p in "${FX_JUNK[@]}"; do
        case $p in
            .config/libreoffice)
                # A symlink: rm -rf must remove the link, never the target.
                mkdir -p "$T/outside/lo-profile" "$home/.config"
                printf 'keep\n' > "$T/outside/lo-profile/registrymodifications.xcu"
                ln -s "$T/outside/lo-profile" "$home/$p"
                ;;
            *rc|*.desktop|.config/emaildefaults|.config/emailidentities|.config/mailtransports|.local/share/emailidentities|.local/share/akonadi_migration_agent)
                mkdir -p "$home/${p%/*}"
                printf 'junk\n' > "$home/$p"
                ;;
            *)
                mkdir -p "$home/$p/sub"
                printf 'junk\n' > "$home/$p/sub/data"
                ;;
        esac
    done
    for p in "${FX_DECOYS[@]}"; do
        mkdir -p "$home/${p%/*}"
        printf 'keep\n' > "$home/$p"
    done
}

# The default machine: Fedora 41 KDE, PIM + LibreOffice installed, SB off, bare metal,
# PackageKit present but idle, no PCI devices (scenarios add their own), user "tester"
# (home path has a space).
fx_base() {
    mkdir -p "$R/etc/dnf" "$R/run" "$R/sys/bus/pci/devices" "$R/sys/devices/pci0000:00" \
        "$R/sys/class/power_supply" "$R/var/lib" "$R/var/log" "$S/pool" "$T/tmp" "$T/cwd" \
        "$T/hostlog" "$T/invoker-home" "$T/home/root" "$T/home/alice" "$H"
    : > "$S/conf"
    : > "$S/lspci"
    fx_os_release 'NAME="Fedora Linux"' 'VERSION="41 (KDE Plasma)"' ID=fedora VERSION_ID=41 \
        'PRETTY_NAME="Fedora Linux 41 (KDE Plasma)"' 'VARIANT="KDE Plasma"' VARIANT_ID=kde \
        REDHAT_SUPPORT_PRODUCT_VERSION=41
    printf '[main]\ngpgcheck=True\ninstallonly_limit=3\nclean_requirements_on_remove=True\nbest=False\nskip_if_unavailable=True\n' \
        > "$R/etc/dnf/dnf.conf"
    fx_add installed "${FX_SYSTEM_PKGS[@]}" "${FX_PIM[@]}" "${FX_OFFICE[@]}" "${FX_KEEP_PKGS[@]}"
    fx_add available
    fx_add unavailable
    fx_add repos fedora updates
    fx_add kernels "$FX_KERNEL"
    fx_add owned
    fx_add desktop_pkgs kgpg kate okular kmail kontact
    fx_add remove_extra 'kmail kpim6-akonadi-mime libkgapi'
    fx_add units packagekit.service fstrim.timer
    fx_add flatpak_remotes fedora
    fx_add flatpak_origins
    mkdir -p "$R/var/lib/flatpak/repo"
    printf '[core]\nrepo_version=1\nmode=bare-split-xattrs\n[remote "fedora"]\nurl=oci+https://registry.fedoraproject.org\n' \
        > "$R/var/lib/flatpak/repo/config"
    fx_add enabled_units
    fx_add modules
    local repo rel keydir=$R/usr/share/distribution-gpg-keys/rpmfusion
    mkdir -p "$keydir"
    for repo in free nonfree; do
        for rel in 41 42 43 44 rawhide; do
            echo "stub key" > "$keydir/RPM-GPG-KEY-rpmfusion-$repo-fedora-$rel"
        done
    done
    mkdir -p "$T/home/daemon"
    printf '%s\n' "root:x:0:0:root:$T/home/root:/bin/bash" \
        "daemon:x:2:2:daemon:$T/home/daemon:/sbin/nologin" \
        "tester:x:$FX_UID:$FX_UID:Tester:$H:/bin/bash" \
        "alice:x:4343:4343:Alice:$T/home/alice:/bin/bash" \
        "John:x:4401:4401:John:$T/home/John:/bin/bash" \
        "2bob:x:4402:4402:Bob:$T/home/2bob:/bin/bash" \
        ".anna:x:4403:4403:Anna:$T/home/.anna:/bin/bash" \
        "123:x:4404:4404:Digits:$T/home/123:/bin/bash" > "$S/passwd"
    mkdir -p "$T/home/John" "$T/home/2bob" "$T/home/.anna" "$T/home/123"
    fx_conf FKS_CPU_VENDOR=GenuineIntel "FKS_CPU_MODEL=12th Gen Intel(R) Core(TM) i7-1260P"
    fx_home_junk "$H"
}

# A KVM guest where every applicable step is already done (firmware doesn't apply in a VM).
fx_fully_configured() {
    fx_conf FKS_VIRT=kvm FKS_UPDATES=0
    fx_pci 0000:00:01.0 0x030000 0x1af4 0x1050 "Red Hat, Inc. Virtio 1.0 GPU (rev 01)" virtio-pci
    printf '[main]\nfastestmirror=True\nmax_parallel_downloads=10\ndefaultyes=True\n' > "$R/etc/dnf/dnf.conf"
    fx_del installed "${FX_PIM[@]}" "${FX_OFFICE[@]}"
    fx_add installed rpmfusion-free-release rpmfusion-nonfree-release ffmpeg gstreamer1-plugins-bad-freeworld \
        gstreamer1-plugins-ugly gstreamer1-plugin-libav gstreamer1-plugin-openh264 qemu-guest-agent spice-vdagent
    fx_del installed ffmpeg-free
    rm -rf "${FX_JUNK[@]/#/$H/}"
    printf '[core]\nmode=bare-split-xattrs\n[remote "fedora"]\nurl=oci+https://registry.fedoraproject.org\nxa.disable=true\n[remote "flathub"]\nurl=https://dl.flathub.org/repo/\n' \
        > "$R/var/lib/flatpak/repo/config"
    mkdir -p "$H/.config"
    printf '[ResourcesModel]\ncurrentApplicationBackend=flatpak-backend\n' > "$H/.config/discoverrc"
    fx_add enabled_units fstrim.timer
    mkdir -p "$R/etc/systemd/journald.conf.d"
    printf '[Journal]\nSystemMaxUse=500M\n' > "$R/etc/systemd/journald.conf.d/00-size.conf"
}
