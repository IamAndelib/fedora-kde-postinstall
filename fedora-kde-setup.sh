#!/usr/bin/env bash
# fedora-kde-setup.sh - one-shot post-install setup for Fedora KDE Plasma.
#
# Run it once on a fresh install (Fedora 41 or newer). It:
#   1. tunes DNF (fastest mirror, parallel downloads) and fully updates the system
#   2. detects CPU, GPU(s), Wi-Fi, Secure Boot, laptop/VM
#   3. adds RPM Fusion and installs non-free codecs, VA-API and drivers for that hardware
#   4. removes KDE PIM (Akonadi, KMail, Kontact...) and LibreOffice, including user data
#   5. enables unfiltered Flathub, applies firmware updates and maintenance defaults
#
# Usage: sudo ./fedora-kde-setup.sh [options]    (see --help)

set -Eeuo pipefail
shopt -s nullglob

# Runs as root: don't trust the caller's environment. Command output is parsed, so use a
# fixed locale. (Test runs set FKS_ROOT and keep PATH so stub commands can stand in.)
umask 022
unset CDPATH BASH_ENV ENV GREP_OPTIONS
export LC_ALL=C.UTF-8
if [[ -z ${FKS_ROOT:-} ]]; then
    export PATH=/usr/sbin:/usr/bin
elif (( EUID == 0 )); then
    # Test mode as root: only accept a fake root that nobody else could have prepared.
    if [[ $(stat -c '%u' -- "$FKS_ROOT" 2>/dev/null) != 0 ]] \
        || (( 8#$(stat -c '%a' -- "$FKS_ROOT" 2>/dev/null || echo 777) & 8#022 )); then
        echo "FKS_ROOT is a test-only setting and must be a root-owned directory nobody else can write to." >&2
        exit 1
    fi
    echo "TEST MODE: FKS_ROOT=$FKS_ROOT" >&2
fi

readonly SCRIPT_VERSION=1.0.0

# FKS_ROOT prefixes every file the script reads or writes directly, so tests can fake a system.
readonly ROOT=${FKS_ROOT:-}
readonly STATE_DIR=$ROOT/var/lib/fedora-kde-setup
readonly MARKER=$STATE_DIR/done
readonly LOCK_FILE=$ROOT/run/fedora-kde-setup.lock
readonly DNF_CONF=$ROOT/etc/dnf/dnf.conf
readonly MOK_CERT=$ROOT/etc/pki/akmods/certs/public_key.der
readonly MOK_PASSWORD_FILE=$ROOT/root/fedora-kde-setup-mok-password.txt
readonly DNF=dnf5
LOG=$ROOT/var/log/fedora-kde-setup.log

# Preflight limits: running out of space or power mid-upgrade is how systems end up broken.
readonly MIN_FREE_ROOT_MIB=6144
readonly MIN_FREE_BOOT_MIB=300

ASSUME_YES=0
DRY_RUN=0
FORCE=0
OFFER_REBOOT=1
TARGET_USER=""
TARGET_HOME=""

# KDE PIM apps, Akonadi and its libraries. dnf removes their now-unused dependencies too.
readonly PIM_REGEX='^(kmail|kontact|korganizer|kaddressbook|akregator|kalarm|knotes|kjots|ktnef|merkuro|kdepim|grantlee-editor|mbox-importer|pim-data-exporter|pim-sieve-editor|akonadi)'
readonly OFFICE_REGEX='^libreoffice'
# A removal that would take any of these with it is skipped.
readonly PROTECTED_REGEX='^(plasma-(workspace|workspace-wayland|desktop|login-manager|systemsettings|nm|pa|discover)|kwin(-wayland|-common|-libs)?|kscreen|powerdevil|bluedevil|polkit-kde|xdg-desktop-portal-kde|kde-settings-plasma|sddm(-wayland-plasma)?|dolphin|konsole|systemd|dnf5?|sudo|kernel(-core)?|glibc|NetworkManager(-wifi)?|pipewire|wireplumber)$'
# Broadcom PCI IDs that only the proprietary wl driver fully supports.
readonly WL_DEVICE_REGEX='^0x(4311|4312|4313|4315|4328|4329|432[a-d]|4331|4353|4357|4358|4359|4360|4365|43a0|43b1|4727)$'

# Relative to the target user's home; globs allowed.
readonly PIM_JUNK=(
    '.local/share/akonadi*' '.config/akonadi*' '.cache/akonadi*'
    .local/share/kmail2 .local/share/local-mail .local/share/emailidentities
    .local/share/akregator .local/share/korganizer .local/share/kontact
    .local/share/kaddressbook .local/share/contacts .local/share/merkuro
    .local/share/kalarm .local/share/knotes .local/share/apps/korganizer
    '.config/kmail2*' '.config/kontact*' '.config/korganizer*' '.config/korgac*'
    '.config/kaddressbook*' '.config/akregator*' '.config/kalarm*' '.config/kalendarac*'
    '.config/merkuro*' '.config/kdepim*' '.config/knotes*' '.config/kjots*' '.config/sieveeditor*'
    .config/emaildefaults .config/emailidentities .config/specialmailcollectionsrc
    .config/mailtransports .config/foldermailarchiverc
    '.config/autostart/*akonadi*' '.config/autostart/*kalarm*' '.config/autostart/*korgac*'
)
readonly OFFICE_JUNK=(.config/libreoffice .cache/libreoffice)

# Filled in by preflight and detect_system.
FEDORA_VER="" FEDORA_NAME="" FEDORA_RAWHIDE=0 OS_ID="" OS_VARIANT="" OS_VERSION_ID=""
CPU_MODEL="" CPU_VENDOR="" RAM_GB="" VIRT=none IN_CONTAINER=0
IS_LAPTOP=0 SECURE_BOOT=0
HAS_NVIDIA=0 HAS_AMD=0 HAS_INTEL=0 NVIDIA_GEN="" NVIDIA_NAME=""
NEEDS_BROADCOM_WL=0
GPU_NAMES=() WIFI_NAMES=()

# Filled in while running.
KERNEL_BEFORE="" NEWEST_KERNEL="" KERNEL_UPDATED=0
MOK_PENDING=0 MOK_PREVIOUS=0 MOK_GENERATED_PASSWORD=""
NVIDIA_INSTALLED=0 WL_INSTALLED=0 PK_MASKED=0 LOG_PID="" DELETED_COUNT=0 LAST_CMD=""
HISTORY_START="" WORK_DIR=""
DONE=() WARNINGS=()

# ---------------------------------------------------------------------------
# Output helpers

if [[ -t 1 ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_BLUE=$'\e[34m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_DIM=$'\e[2m'
else
    C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM=""
fi

STEP=0
section() { STEP=$((STEP + 1)); printf '\n%s==> [%d] %s%s\n' "$C_BOLD$C_BLUE" "$STEP" "$*" "$C_RESET"; }
info()    { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; DONE+=("$*"); }
warn()    { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; WARNINGS+=("$*"); }
die()     { printf '%s  xx %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
# fd 3 is the terminal/log, so a command's own redirections never hide its log line.
log_cmd() { printf '%s  $ %s%s\n' "$C_DIM" "$*" "$C_RESET" >&3; }

on_error() {
    local rc=$1 line=$2 cmd=$3
    # A failing $(...) is reported once, by the shell that uses its result.
    (( BASH_SUBSHELL == 0 )) || return 0
    # Drop on_error itself and bash's implicit outermost "main" frame.
    local where=${FUNCNAME[*]:1:${#FUNCNAME[@]}-2}
    if [[ $cmd == '"$@"' && -n $LAST_CMD ]]; then
        cmd=$LAST_CMD
    fi
    printf '%s  xx Failed (exit %s) at line %s in %s: %s%s\n' \
        "$C_RED" "$rc" "$line" "${where// / <- }" "$cmd" "$C_RESET" >&2
    printf '     Full log: %s\n' "$LOG" >&2
}

cleanup() {
    local rc=$?
    if (( PK_MASKED )); then
        systemctl unmask --runtime packagekit.service &>/dev/null || true
    fi
    if [[ -n $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
    if [[ -n $LOG_PID ]]; then
        # Let tee flush everything before the terminal goes away.
        exec >&- 2>&- 3>&-
        wait "$LOG_PID" 2>/dev/null || true
    fi
    exit "$rc"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'die "Interrupted"' INT TERM
# Keep going if an SSH session drops; dnf inherits this too.
trap '' HUP

# Runs a command, or only prints it under --dry-run.
run() {
    log_cmd "$*"
    LAST_CMD="$*"
    if (( DRY_RUN )); then
        return 0
    fi
    "$@"
}

# Runs a command as the target user without root's terminal, log pipe or lock fd.
run_as_user() {
    log_cmd "runuser -u $TARGET_USER -- $*"
    LAST_CMD="runuser -u $TARGET_USER -- $*"
    if (( DRY_RUN )); then
        return 0
    fi
    runuser -u "$TARGET_USER" -- setsid -w "$@" </dev/null >/dev/null 2>&1 3>&- 9>&-
}

# systemctl doesn't work in containers (CI); skip it there.
run_systemctl() {
    if (( IN_CONTAINER )); then
        info "Container: skipping systemctl $*"
        return 0
    fi
    run systemctl "$@"
}

write_file() {
    local path=$1 content=$2
    log_cmd "write $path"
    if (( DRY_RUN )); then
        return 0
    fi
    install -d -m 0755 "${path%/*}"
    printf '%s\n' "$content" > "$path"
}

# Dies normally, but only warns under --dry-run so the plan can be previewed anywhere.
require() {
    if (( DRY_RUN )); then
        warn "(dry-run) $*"
    else
        die "$*"
    fi
}

# /dev/tty is world-readable even without a controlling terminal, so try opening it.
have_tty() { { : </dev/tty; } 2>/dev/null; }

ask_yes_no() {  # $1 = prompt, $2 = default (y/n)
    local answer=""
    printf '%s%s%s ' "$C_BOLD" "$1" "$C_RESET"
    read -r answer </dev/tty || answer=""
    answer=${answer:-$2}
    [[ $answer =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Package helpers

is_installed() { rpm -q --quiet "$1" 2>/dev/null; }
is_available() { "$DNF" -q list --available "$1" &>/dev/null; }

dnf_install() { run "$DNF" install -y --skip-unavailable "$@"; }

# Succeeds if every package is installed; --skip-unavailable doesn't fail on missing ones.
check_installed() {
    if (( DRY_RUN )); then
        return 0
    fi
    local p missing=()
    for p in "$@"; do
        is_installed "$p" || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        warn "Not installed (unavailable or failed): ${missing[*]}"
        return 1
    fi
}

installed_matching() {  # $1 = regex; prints installed package names that match
    rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E "$1" | sort -u || true
}

newest_kernel() {
    rpm -q --quiet kernel-core 2>/dev/null || return 0
    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | sort -V | tail -n1
}

fedora_release_name() {  # "rawhide" or the version number
    if (( FEDORA_RAWHIDE )); then
        echo rawhide
    else
        echo "$FEDORA_VER"
    fi
}

rpmfusion_url() {  # $1 = free | nonfree, $2 = host (default: the mirror redirector)
    printf 'https://%s/%s/fedora/rpmfusion-%s-release-%s.noarch.rpm' \
        "${2:-mirrors.rpmfusion.org}" "$1" "$1" "$(fedora_release_name)"
}

# HTTPS only, also across redirects.
download() {  # $1 = URL, $2 = destination file
    log_cmd "download $1"
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 --max-time 180 -o "$2" "$1"
}

# ---------------------------------------------------------------------------
# Setup

usage() {
    cat <<'EOF'
Usage: sudo ./fedora-kde-setup.sh [options]

One-shot post-install setup for Fedora KDE Plasma (Fedora 41 or newer).

Options:
  -y, --yes          don't ask for confirmation
  -n, --dry-run      print what would be done without changing anything
  -f, --force        run even if the script already completed on this machine
      --no-reboot    don't offer to reboot at the end
  -u, --user NAME    user whose home gets cleaned of PIM/LibreOffice data
                     (default: the user who ran sudo)
  -h, --help         show this help
  -V, --version      show the version
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            -y|--yes)     ASSUME_YES=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -f|--force)   FORCE=1 ;;
            --no-reboot)  OFFER_REBOOT=0 ;;
            -u|--user)    TARGET_USER=${2:-}; [[ -n $TARGET_USER ]] || die "--user needs a name"; shift ;;
            --user=*)     TARGET_USER=${1#--user=}; [[ -n $TARGET_USER ]] || die "--user needs a name" ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "fedora-kde-setup $SCRIPT_VERSION"; exit 0 ;;
            *)            usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done
}

setup_logging() {
    if (( EUID != 0 )); then
        LOG=$(mktemp "${TMPDIR:-/tmp}/fedora-kde-setup.XXXXXX.log" 2>/dev/null || echo /dev/null)
    fi
    if ! { (umask 077; : >> "$LOG") && chmod 600 "$LOG"; } 2>/dev/null; then
        LOG=/dev/null
    fi
    # Terminal keeps colors; the log file gets plain text. The logger ignores Ctrl-C and
    # hangups so it outlives the script's last line, and tee -p survives a vanished terminal.
    exec > >(trap - ERR; trap '' INT TERM HUP
             exec tee -p >(trap '' INT TERM HUP; exec sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1
    LOG_PID=$!
    exec 3>&1
    printf '\n===== %s  fedora-kde-setup %s %s =====\n' "$(date '+%F %T')" "$SCRIPT_VERSION" "$*" >> "$LOG"
}

read_os_release() {
    local file=$ROOT/etc/os-release
    if [[ ! -r $file ]]; then
        require "$file not found"
        return 0
    fi
    local fields
    # Sourced in a subshell so its variables (VERSION, NAME...) can't clobber the script's.
    # shellcheck source=/dev/null
    mapfile -t fields < <(set +eu; source "$file" >/dev/null 2>&1
        printf '%s\n' "${ID:-}" "${VARIANT_ID:-}" "${PRETTY_NAME:-}" "${VERSION_ID:-}" "${REDHAT_SUPPORT_PRODUCT_VERSION:-}")
    OS_ID=${fields[0]:-} OS_VARIANT=${fields[1]:-} FEDORA_NAME=${fields[2]:-unknown}
    OS_VERSION_ID=${fields[3]:-}
    if [[ ${fields[4]:-} == rawhide || $OS_VERSION_ID == rawhide ]]; then
        FEDORA_RAWHIDE=1
    fi
}

resolve_target_user() {
    if [[ -z $TARGET_USER ]]; then
        if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            TARGET_USER=$SUDO_USER
        elif [[ -n ${PKEXEC_UID:-} ]]; then
            TARGET_USER=$(id -nu "$PKEXEC_UID" 2>/dev/null || true)
        elif (( DRY_RUN )); then
            TARGET_USER=$(id -nu)
        fi
    fi
    [[ -n $TARGET_USER ]] \
        || die "Can't tell which user to clean up. Run it with sudo from your own account, or pass --user NAME."
    if [[ $TARGET_USER == root ]]; then
        require "Refusing to clean root's home. Run it with sudo from your own account, or pass --user NAME."
    fi
    # Same character set Fedora's installer allows; never all digits, "." or "..".
    if [[ ! $TARGET_USER =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*\$?$ || $TARGET_USER =~ ^[0-9]+$ \
          || $TARGET_USER == . || $TARGET_USER == .. ]]; then
        require "'$TARGET_USER' isn't a valid user name"
        TARGET_USER="" TARGET_HOME=""
        return 0
    fi
    if ! id -u "$TARGET_USER" &>/dev/null; then
        require "User '$TARGET_USER' doesn't exist"
        TARGET_HOME=""
        return 0
    fi
    local uid
    uid=$(id -u "$TARGET_USER")
    if (( uid < 1000 )) && [[ $TARGET_USER != root ]]; then
        require "'$TARGET_USER' is a system account (UID $uid); pass the desktop user with --user NAME"
    fi
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
    if [[ -z $TARGET_HOME || ! -d $TARGET_HOME || $TARGET_HOME == / ]]; then
        require "Home directory for user '$TARGET_USER' not found"
        TARGET_HOME=""
    fi
}

free_mib() {  # $1 = path; prints free MiB on its filesystem, or nothing if unknown
    df -Pm -- "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }' || true
}

read_sysfs() {  # $1 = file; prints its content, or nothing if unreadable
    if [[ -r $1 ]]; then
        printf '%s' "$(<"$1")"
    fi
}

on_ac_power() {
    local supply seen=0
    for supply in "$ROOT"/sys/class/power_supply/*; do
        case $(read_sysfs "$supply/type") in
            Mains|USB*)
                seen=1
                if [[ $(read_sysfs "$supply/online") == 1 ]]; then
                    return 0
                fi
                ;;
        esac
    done
    if (( seen )); then
        return 1
    fi
    # No AC adapter reported: trust the battery status instead.
    for supply in "$ROOT"/sys/class/power_supply/BAT*; do
        if [[ $(read_sysfs "$supply/status") == Discharging ]]; then
            return 1
        fi
    done
    return 0
}

# Refuses to start when the system could be left half-upgraded.
check_safety_rails() {
    local arch
    arch=$(uname -m)
    if [[ $arch != x86_64 ]]; then
        require "This script supports x86_64 only (found: $arch)"
    fi

    local path free need
    for path in / /var /boot; do
        need=$MIN_FREE_ROOT_MIB
        [[ $path == /boot ]] && need=$MIN_FREE_BOOT_MIB
        free=$(free_mib "$ROOT$path")
        if [[ -n $free ]] && (( free < need )); then
            require "Only $free MiB free on $path; need at least $need MiB. Free up space first."
        fi
    done

    if compgen -G "$ROOT/sys/class/power_supply/BAT*" >/dev/null && ! on_ac_power; then
        require "Running on battery. Plug in the charger first: losing power mid-upgrade can leave the system unbootable."
    fi

    if ! rpm -q --quiet rpm 2>/dev/null; then
        require "The RPM database doesn't respond; fix it first (sudo rpm --rebuilddb)"
    fi
    if pgrep -x 'dnf5|dnf|rpm|dnf-automatic' &>/dev/null; then
        require "Another package manager (dnf/rpm) is running; wait for it to finish"
    fi
}

take_lock() {
    if (( DRY_RUN )) || ! command -v flock &>/dev/null; then
        return 0
    fi
    if ! { exec 9>"$LOCK_FILE"; } 2>/dev/null; then
        warn "Couldn't create $LOCK_FILE; not guarding against a second run"
        return 0
    fi
    flock -n 9 || die "Another run of this script is already in progress"
}

preflight() {
    section "Preflight checks"

    if (( EUID != 0 )); then
        require "Run this with sudo: sudo bash $0"
    fi

    if [[ -f $MARKER ]] && (( ! FORCE )); then
        if (( DRY_RUN )); then
            warn "Setup already completed on $(<"$MARKER"); a real run would need --force"
        else
            die "Setup already completed on $(<"$MARKER"). Use --force to run it again."
        fi
    fi

    read_os_release
    [[ $OS_ID == fedora ]] || require "This script is for Fedora (found: ${OS_ID:-unknown})"
    if [[ -e $ROOT/run/ostree-booted ]]; then
        require "Fedora Atomic (Kinoite) uses rpm-ostree; this script is for the regular KDE edition"
    fi

    FEDORA_VER=$(rpm -E %fedora 2>/dev/null || true)
    [[ $FEDORA_VER =~ ^[0-9]+$ ]] || FEDORA_VER=$OS_VERSION_ID
    if [[ $FEDORA_VER =~ ^[0-9]+$ ]] && (( FEDORA_VER < 41 )); then
        require "Fedora $FEDORA_VER is too old; this script needs Fedora 41 or newer"
    fi
    command -v "$DNF" &>/dev/null || require "dnf5 not found; this script needs Fedora 41 or newer"
    if [[ $OS_VARIANT != kde ]] && ! is_installed plasma-workspace; then
        require "This isn't Fedora KDE Plasma (VARIANT_ID=${OS_VARIANT:-none}, plasma-workspace not installed)"
    fi

    resolve_target_user
    check_safety_rails
    take_lock

    local url
    url=$(rpmfusion_url free)
    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsIL --max-time 20 -o /dev/null "$url" \
        && ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsIL --max-time 20 -o /dev/null \
            "$(rpmfusion_url free download1.rpmfusion.org)"; then
        require "Can't download $url. Check the internet connection; right after a new Fedora release RPM Fusion can lag a few days."
    fi

    ok "${FEDORA_NAME}, cleaning up for user '$TARGET_USER'"
}

# ---------------------------------------------------------------------------
# Detection

pci_name() {  # $1 = sysfs dir of a PCI device
    local slot=${1##*/} name=""
    if command -v lspci &>/dev/null; then
        name=$(lspci -s "$slot" 2>/dev/null | cut -d: -f3- | sed 's/^ *//' || true)
    fi
    printf '%s' "${name:-vendor $(<"$1/vendor") device $(<"$1/device")}"
}

# By PCI device ID: current = Turing and newer; legacy = Maxwell, Pascal, Volta (last
# supported by the 580 driver series); unsupported = Kepler, Fermi and older, incl. nForce IGPs.
classify_nvidia() {  # $1 = device ID like 0x1b80
    if [[ ! $1 =~ ^0x[0-9a-fA-F]{1,4}$ ]]; then
        echo current
        return 0
    fi
    local id=$(( $1 ))
    if (( id >= 0x1e00 )); then
        echo current
    elif (( id >= 0x1340 )); then
        echo legacy
    else
        echo unsupported
    fi
}

nvidia_rank() {
    case $1 in
        unsupported) echo 2 ;;
        legacy)      echo 1 ;;
        *)           echo 0 ;;
    esac
}

has_wireless_phy() {  # $1 = sysfs dir; true if a kernel driver already registered a Wi-Fi device
    # The trailing slash makes find descend into the sysfs symlink.
    [[ -n $(find "$1/" -maxdepth 4 \( -name ieee80211 -o -name phy80211 \) -print -quit 2>/dev/null) ]]
}

detect_system() {
    section "Detecting hardware"

    CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/^Model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' || true)
    CPU_VENDOR=$(lscpu 2>/dev/null | awk -F: '/^Vendor ID/ { sub(/^[ \t]+/, "", $2); print $2; exit }' || true)
    RAM_GB=$(awk '/^MemTotal/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo 2>/dev/null || true)
    VIRT=$(systemd-detect-virt --vm 2>/dev/null || true)
    VIRT=${VIRT:-none}
    if [[ -e $ROOT/run/.containerenv || -e $ROOT/.dockerenv ]] \
        || systemd-detect-virt --container --quiet 2>/dev/null; then
        IN_CONTAINER=1
    fi

    if compgen -G "$ROOT/sys/class/power_supply/BAT*" >/dev/null; then
        IS_LAPTOP=1
    fi

    if command -v mokutil &>/dev/null; then
        if [[ $(mokutil --sb-state 2>/dev/null || true) == *"SecureBoot enabled"* ]]; then
            SECURE_BOOT=1
        fi
    else
        local var
        for var in "$ROOT"/sys/firmware/efi/efivars/SecureBoot-*; do
            if [[ $(od -An -t u1 "$var" 2>/dev/null | awk '{ print $NF }') == 1 ]]; then
                SECURE_BOOT=1
            fi
        done
    fi

    local dev class vendor device name gen
    for dev in "$ROOT"/sys/bus/pci/devices/*; do
        [[ -r $dev/class && -r $dev/vendor && -r $dev/device ]] || continue
        class=$(<"$dev/class") vendor=$(<"$dev/vendor") device=$(<"$dev/device")
        case $class in
            0x0300*|0x0302*|0x0380*)
                name=$(pci_name "$dev")
                GPU_NAMES+=("$name")
                case $vendor in
                    0x10de)
                        HAS_NVIDIA=1
                        # With several NVIDIA GPUs, the oldest one decides the driver branch.
                        gen=$(classify_nvidia "$device")
                        if [[ -z $NVIDIA_GEN ]] || (( $(nvidia_rank "$gen") > $(nvidia_rank "$NVIDIA_GEN") )); then
                            NVIDIA_GEN=$gen NVIDIA_NAME=$name
                        fi
                        ;;
                    0x1002) HAS_AMD=1 ;;
                    0x8086) HAS_INTEL=1 ;;
                esac
                ;;
            0x0280*)
                name=$(pci_name "$dev")
                WIFI_NAMES+=("$name")
                if [[ $vendor == 0x14e4 && $device =~ $WL_DEVICE_REGEX ]] && ! has_wireless_phy "$dev"; then
                    NEEDS_BROADCOM_WL=1
                fi
                ;;
        esac
    done

    if [[ $VIRT != none ]] || (( IN_CONTAINER )); then
        HAS_NVIDIA=0 NEEDS_BROADCOM_WL=0
    fi

    local gpus wifi virt_label=$VIRT
    gpus=$(IFS=';'; echo "${GPU_NAMES[*]:-none detected}")
    wifi=$(IFS=';'; echo "${WIFI_NAMES[*]:-none detected}")
    if (( IN_CONTAINER )); then
        virt_label="container"
    fi

    printf '\n'
    printf '  %-12s %s\n' \
        "System"      "$FEDORA_NAME" \
        "Kernel"      "$(uname -r)" \
        "CPU"         "${CPU_MODEL:-unknown} (${CPU_VENDOR:-?})" \
        "RAM"         "${RAM_GB:-?} GiB" \
        "Form factor" "$( ((IS_LAPTOP)) && echo laptop || echo desktop)" \
        "Virtual"     "$virt_label" \
        "Secure Boot" "$( ((SECURE_BOOT)) && echo enabled || echo disabled)" \
        "GPU(s)"      "${gpus//;/ | }" \
        "Wi-Fi"       "${wifi//;/ | }"
}

print_plan() {
    section "Planned actions"
    local plan=(
        "Set DNF fastestmirror=True, max_parallel_downloads=10, defaultyes=True"
        "Full system upgrade (PackageKit/Discover paused meanwhile)"
        "Enable RPM Fusion (free + nonfree) and Cisco OpenH264"
        "Swap ffmpeg-free for full ffmpeg; install GStreamer bad/ugly/libav/openh264 codecs"
    )
    ((HAS_INTEL)) && plan+=("Intel: full intel-media-driver (VA-API) + legacy i965 driver")
    ((HAS_AMD)) && plan+=("AMD: mesa-va-drivers-freeworld (H.264/HEVC hardware decode)")
    if ((HAS_NVIDIA)); then
        case $NVIDIA_GEN in
            current)     plan+=("NVIDIA: akmod-nvidia + CUDA + power management + VA-API ($NVIDIA_NAME)") ;;
            legacy)      plan+=("NVIDIA: driver branch that still supports this card, 580xx where needed ($NVIDIA_NAME)") ;;
            unsupported) plan+=("NVIDIA: card too old for maintained drivers, keeping nouveau ($NVIDIA_NAME)") ;;
        esac
    fi
    if ((SECURE_BOOT)) && { { ((HAS_NVIDIA)) && [[ $NVIDIA_GEN != unsupported ]]; } || ((NEEDS_BROADCOM_WL)); }; then
        plan+=("Secure Boot: create an akmods signing key and queue it for MOK enrollment (one-time password)")
    fi
    ((NEEDS_BROADCOM_WL)) && plan+=("Broadcom Wi-Fi: broadcom-wl driver")
    if ((IN_CONTAINER)); then
        plan+=("Container: skip drivers, firmware and services")
    elif [[ $VIRT != none ]]; then
        plan+=("Virtual machine ($VIRT): install guest tools, skip GPU drivers and firmware")
    fi
    plan+=(
        "Remove KDE PIM (Akonadi, KMail, Kontact, KOrganizer...) and LibreOffice with their unused dependencies"
        "Delete PIM and LibreOffice data/config/cache in ${TARGET_HOME:-the user home}"
        "Enable unfiltered Flathub with Discover's Flatpak backend"
    )
    if [[ $VIRT == none ]] && (( ! IN_CONTAINER )); then
        plan+=("Apply firmware updates with fwupd")
    fi
    plan+=("Enable fstrim.timer, cap journal at 500M")

    local i
    for i in "${!plan[@]}"; do
        printf '  %2d. %s\n' "$((i + 1))" "${plan[i]}"
    done
    printf '\n'

    if (( DRY_RUN )); then
        info "Dry run: commands below are printed, not executed."
        return 0
    fi
    if (( ! ASSUME_YES )); then
        have_tty || die "No terminal to confirm on; re-run with --yes"
        ask_yes_no "Proceed? [y/N]" n || die "Aborted, nothing was changed."
    fi
}

# ---------------------------------------------------------------------------
# Steps

set_dnf_option() {  # $1 = key, $2 = value; edits [main] in dnf.conf
    local conf=$DNF_CONF key=$1 value=$2
    log_cmd "set $key=$value in $conf"
    if (( DRY_RUN )); then
        return 0
    fi
    if [[ ! -s $conf ]]; then
        install -d -m 0755 "${conf%/*}"
        printf '[main]\n' > "$conf"
    elif ! grep -q '^\[main\]' "$conf"; then
        sed -i '1i [main]' "$conf"
    fi
    if [[ -n $(tail -c1 "$conf") ]]; then
        printf '\n' >> "$conf"
    fi
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$conf"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$conf"
    else
        sed -i "/^\[main\]/a ${key}=${value}" "$conf"
    fi
}

# PackageKit (Discover) holds the package lock on first boot and may have an offline update staged.
pause_packagekit() {
    if (( IN_CONTAINER )); then
        return 0
    fi
    if (( DRY_RUN )) || systemctl cat packagekit.service &>/dev/null; then
        run_systemctl mask --runtime packagekit.service
        if (( ! DRY_RUN )); then
            PK_MASKED=1
        fi
        if (( ! DRY_RUN )) && systemctl is-active --quiet packagekit.service; then
            info "Waiting for PackageKit to finish what it's doing"
            run pkcon quit >/dev/null 2>&1 || true
            local i
            for (( i = 0; i < 60; i++ )); do
                systemctl is-active --quiet packagekit.service || break
                sleep 2
            done
            # Stopping it now could interrupt a package transaction; give up instead.
            # (The runtime mask is lifted on exit, so this really changes nothing.)
            if systemctl is-active --quiet packagekit.service; then
                die "PackageKit (Discover) is still busy after 2 minutes. Let it finish, then run this again. Nothing was changed."
            fi
        fi
        ok "PackageKit paused until the script finishes"
    fi
    # Only once PackageKit is idle: drop a staged offline update so it doesn't run on the next boot.
    if [[ -e $ROOT/system-update || -L $ROOT/system-update ]]; then
        info "Cancelling a staged offline update; this script installs the same updates now"
        run pkcon offline-cancel >/dev/null 2>&1 || run rm -f "$ROOT/system-update"
    fi
}

last_transaction_id() {
    "$DNF" history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1 }' | sort -n | tail -n1 || true
}

prepare_dnf() {
    section "Preparing DNF"
    HISTORY_START=$(last_transaction_id)
    pause_packagekit
    set_dnf_option fastestmirror True
    set_dnf_option max_parallel_downloads 10
    set_dnf_option defaultyes True
    ok "DNF: fastest mirror, 10 parallel downloads"
}

update_system() {
    section "Updating the whole system (this can take a while)"
    KERNEL_BEFORE=$(newest_kernel)
    run "$DNF" upgrade --refresh -y
    NEWEST_KERNEL=$(newest_kernel)
    if [[ $NEWEST_KERNEL != "$KERNEL_BEFORE" ]]; then
        KERNEL_UPDATED=1
    fi
    ok "System upgraded${NEWEST_KERNEL:+ (newest kernel: $NEWEST_KERNEL)}"
}

# Downloads the RPM Fusion release packages and installs them only if their signatures
# check out against RPM Fusion's keys as shipped (and signed) by Fedora.
install_rpmfusion() {
    local repo repos=()
    for repo in free nonfree; do
        is_installed "rpmfusion-$repo-release" || repos+=("$repo")
    done
    if (( ${#repos[@]} == 0 )); then
        info "RPM Fusion already installed"
        return 0
    fi

    is_installed distribution-gpg-keys || run "$DNF" install -y distribution-gpg-keys
    local release keydir=$ROOT/usr/share/distribution-gpg-keys/rpmfusion
    release=$(fedora_release_name)
    if (( ! DRY_RUN )); then
        # Not $TMPDIR: the caller's environment mustn't choose where root keeps the downloads.
        install -d -m 1777 "$ROOT/tmp"
        WORK_DIR=$(mktemp -d "$ROOT/tmp/fedora-kde-setup.XXXXXX")
    fi

    local key file out files=()
    for repo in "${repos[@]}"; do
        key=$keydir/RPM-GPG-KEY-rpmfusion-$repo-fedora-$release
        file=$WORK_DIR/rpmfusion-$repo-release.noarch.rpm
        if (( DRY_RUN )); then
            log_cmd "rpmkeys --import $key"
            log_cmd "download $(rpmfusion_url "$repo")"
            log_cmd "rpmkeys --checksig rpmfusion-$repo-release.noarch.rpm"
            continue
        fi
        [[ -r $key ]] || key=$keydir/RPM-GPG-KEY-rpmfusion-$repo-fedora-latest
        [[ -r $key ]] || die "RPM Fusion's signing key for Fedora $release isn't in distribution-gpg-keys ($keydir), so its packages can't be verified. Try again after the next Fedora update."
        run rpmkeys --import "$key"
        download "$(rpmfusion_url "$repo")" "$file" \
            || download "$(rpmfusion_url "$repo" download1.rpmfusion.org)" "$file" \
            || die "Couldn't download the RPM Fusion $repo release package"
        if ! out=$(rpmkeys --checksig -- "$file" 2>&1) || [[ $out != "$file: digests signatures OK" ]]; then
            die "Signature check failed for the RPM Fusion $repo release package, refusing to install it: $out"
        fi
        if [[ $(rpm -qp --qf '%{NAME}' -- "$file" 2>/dev/null) != "rpmfusion-$repo-release" ]]; then
            die "The downloaded file isn't the rpmfusion-$repo-release package, refusing to install it"
        fi
        ok "RPM Fusion $repo release package signature verified"
        files+=("$file")
    done
    if (( DRY_RUN )); then
        log_cmd "$DNF install -y <verified rpmfusion-*-release packages>"
    else
        run "$DNF" install -y "${files[@]}"
    fi
}

enable_repos() {
    section "Enabling RPM Fusion and OpenH264"
    install_rpmfusion

    local enabled
    enabled=$("$DNF" repolist --enabled 2>/dev/null || true)
    if [[ $enabled == *fedora-cisco-openh264* ]]; then
        info "Cisco OpenH264 repo already enabled"
    else
        is_installed dnf5-plugins || dnf_install dnf5-plugins || true
        run "$DNF" config-manager setopt fedora-cisco-openh264.enabled=1 \
            || warn "Couldn't enable the fedora-cisco-openh264 repo"
    fi

    # Lets Discover show RPM Fusion apps.
    dnf_install rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data \
        || warn "Couldn't install RPM Fusion AppStream data (Discover may not list RPM Fusion apps)"
    ok "RPM Fusion free/nonfree and Cisco OpenH264 enabled"
}

install_codecs() {
    section "Installing multimedia codecs"
    if is_installed ffmpeg-free; then
        run "$DNF" swap -y ffmpeg-free ffmpeg --allowerasing || warn "Couldn't swap ffmpeg-free for ffmpeg"
    else
        dnf_install ffmpeg --allowerasing || warn "Couldn't install ffmpeg"
    fi

    run "$DNF" upgrade -y @multimedia --setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin \
        || info "Multimedia group not installed; codecs are installed individually below"

    dnf_install --allowerasing \
        gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-libav \
        gstreamer1-plugin-openh264 mozilla-openh264 lame ffmpegthumbs libva-utils \
        || warn "Some codec packages failed to install"
    if check_installed ffmpeg gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-libav; then
        ok "Codecs: ffmpeg, GStreamer bad/ugly/libav, OpenH264, LAME"
    fi

    if (( HAS_INTEL )); then
        if is_installed libva-intel-media-driver; then
            run "$DNF" swap -y libva-intel-media-driver intel-media-driver --allowerasing \
                || warn "Couldn't swap libva-intel-media-driver for intel-media-driver"
        else
            dnf_install intel-media-driver --allowerasing || warn "Couldn't install intel-media-driver"
        fi
        dnf_install libva-intel-driver || true
        if check_installed intel-media-driver; then
            ok "Intel VA-API: intel-media-driver"
        fi
    fi

    if (( HAS_AMD )); then
        # mesa-freeworld dropped VDPAU; VA-API is the only one left to swap.
        if is_installed mesa-va-drivers; then
            run "$DNF" swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing \
                || warn "Couldn't swap mesa-va-drivers for mesa-va-drivers-freeworld"
        else
            dnf_install mesa-va-drivers-freeworld || warn "Couldn't install mesa-va-drivers-freeworld"
        fi
        if check_installed mesa-va-drivers-freeworld; then
            ok "AMD VA-API: mesa-va-drivers-freeworld"
        fi
    fi
}

# Returns 1 if module signing couldn't be set up (drivers would then fail to load).
setup_secure_boot_signing() {
    info "Secure Boot is on: setting up akmods module signing"
    dnf_install akmods kmodtool mokutil openssl || true
    if [[ ! -f $MOK_CERT ]]; then
        run kmodgenca -a || true
    fi

    if (( DRY_RUN )); then
        log_cmd "mokutil --import $MOK_CERT"
        MOK_PENDING=1
        return 0
    fi
    if [[ ! -f $MOK_CERT ]]; then
        warn "kmodgenca didn't create $MOK_CERT"
        return 1
    fi

    local state
    state=$(mokutil --test-key "$MOK_CERT" 2>&1 || true)
    case $state in
        *"already enrolled"*|*"already in"*"db"*)
            ok "akmods signing key already enrolled"
            return 0
            ;;
        *"enrollment request"*)
            MOK_PENDING=1 MOK_PREVIOUS=1
            if [[ -s $MOK_PASSWORD_FILE ]]; then
                MOK_GENERATED_PASSWORD=$(<"$MOK_PASSWORD_FILE")
            fi
            info "akmods signing key is already queued for enrollment"
            return 0
            ;;
    esac

    if have_tty && (( ! ASSUME_YES )); then
        info "Create a one-time password (8+ characters). You'll type it once more on the blue MOK screen after reboot."
        local tries=0
        # mokutil doesn't flush its prompts, so talk to the terminal directly.
        until mokutil --import "$MOK_CERT" </dev/tty >/dev/tty 2>&1; do
            tries=$((tries + 1))
            if (( tries >= 3 )); then
                warn "MOK import failed 3 times"
                return 1
            fi
            warn "Passwords didn't match or import failed, try again"
        done
    else
        # Unattended (--yes or no terminal): generate a password and save it for the user.
        local hash_file=$ROOT/root/.fedora-kde-setup-mok.hash
        MOK_GENERATED_PASSWORD=$(openssl rand -hex 4)
        [[ -d ${hash_file%/*} ]] || install -d -m 0700 "${hash_file%/*}"
        if ! { mokutil --generate-hash="$MOK_GENERATED_PASSWORD" > "$hash_file" \
               && mokutil --import "$MOK_CERT" --hash-file "$hash_file"; }; then
            rm -f "$hash_file"
            MOK_GENERATED_PASSWORD=""
            warn "MOK import failed"
            return 1
        fi
        rm -f "$hash_file"
        (umask 077; printf '%s\n' "$MOK_GENERATED_PASSWORD" > "$MOK_PASSWORD_FILE")
        warn "MOK one-time password: $MOK_GENERATED_PASSWORD (saved in $MOK_PASSWORD_FILE); you'll need it on the next boot"
    fi
    MOK_PENDING=1
    ok "akmods signing key queued for enrollment"
}

# Returns 1 if no driver was installed.
install_nvidia() {
    local pkgs=()
    case $NVIDIA_GEN in
        current)
            pkgs=(akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power)
            ;;
        legacy)
            # The main driver dropped Maxwell/Pascal/Volta in the 590 series. The 580xx branch
            # keeps working across Fedora upgrades, so prefer it even where main is still 580.
            local main_ver
            main_ver=$("$DNF" -q repoquery --latest-limit=1 --qf '%{version}\n' xorg-x11-drv-nvidia 2>/dev/null | head -n1 || true)
            if is_available akmod-nvidia-580xx || (( DRY_RUN )); then
                pkgs=(akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda xorg-x11-drv-nvidia-580xx-power)
            elif [[ $main_ver =~ ^[0-9]+\. ]] && (( ${main_ver%%.*} < 590 )); then
                pkgs=(akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power)
                warn "Installed the main NVIDIA driver ($main_ver) for $NVIDIA_NAME. Before upgrading Fedora, run: sudo dnf swap akmod-nvidia akmod-nvidia-580xx --allowerasing"
            else
                warn "No NVIDIA driver branch for $NVIDIA_NAME found in RPM Fusion; keeping nouveau"
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    info "Installing NVIDIA driver: ${pkgs[*]}"
    dnf_install "${pkgs[@]}" libva-nvidia-driver || { warn "NVIDIA driver installation failed"; return 1; }
    check_installed "${pkgs[0]}" || return 1

    # Loads nouveau if the nvidia module fails, so the desktop still comes up.
    if (( DRY_RUN )) || systemctl cat nvidia-fallback.service &>/dev/null; then
        run_systemctl enable nvidia-fallback.service || true
    fi
    ok "NVIDIA driver installed (${pkgs[0]})"
}

install_broadcom() {
    dnf_install broadcom-wl || { warn "broadcom-wl installation failed"; return 1; }
    check_installed broadcom-wl || return 1
    ok "Broadcom wl Wi-Fi driver installed"
}

install_vm_tools() {
    local pkgs=()
    case $VIRT in
        kvm|qemu)  pkgs=(qemu-guest-agent spice-vdagent) ;;
        vmware)    pkgs=(open-vm-tools-desktop) ;;
        oracle)    pkgs=(virtualbox-guest-additions) ;;
        microsoft) pkgs=(hyperv-daemons) ;;
        *)         info "No guest tools known for '$VIRT'"; return 0 ;;
    esac
    dnf_install "${pkgs[@]}" || warn "Couldn't install VM guest tools"
    ok "VM guest tools: ${pkgs[*]}"
}

# Builds kernel modules now instead of on first boot, and checks they exist.
build_kmods() {
    [[ -n $NEWEST_KERNEL ]] || NEWEST_KERNEL=$(newest_kernel)
    if [[ -z $NEWEST_KERNEL ]]; then
        warn "Couldn't determine the newest kernel; akmods will build modules at next boot"
        return 0
    fi
    info "Building kernel modules for $NEWEST_KERNEL (a few minutes)"
    dnf_install "kernel-devel-$NEWEST_KERNEL" || warn "Couldn't install kernel-devel-$NEWEST_KERNEL"
    run akmods --force --kernels "$NEWEST_KERNEL" || warn "akmods reported a problem"
    if (( DRY_RUN )); then
        return 0
    fi

    local mod mods=()
    (( NVIDIA_INSTALLED )) && mods+=(nvidia)
    (( WL_INSTALLED )) && mods+=(wl)
    for mod in "${mods[@]}"; do
        if ! modinfo -k "$NEWEST_KERNEL" "$mod" &>/dev/null; then
            warn "Kernel module '$mod' isn't built yet; akmods retries at boot (logs: /var/cache/akmods/)"
        elif (( SECURE_BOOT )) && [[ -z $(modinfo -k "$NEWEST_KERNEL" -F signer "$mod" 2>/dev/null || true) ]]; then
            warn "Kernel module '$mod' is built but not signed; it won't load with Secure Boot on"
        else
            ok "Kernel module '$mod' built for $NEWEST_KERNEL"
        fi
    done
}

install_drivers() {
    section "Installing drivers for this hardware"
    if (( IN_CONTAINER )); then
        info "Container: skipping drivers"
        return 0
    fi
    if [[ $VIRT != none ]]; then
        install_vm_tools
        return 0
    fi

    local want_nvidia=0 want_wl=$NEEDS_BROADCOM_WL
    if (( HAS_NVIDIA )); then
        if [[ $NVIDIA_GEN == unsupported ]]; then
            warn "NVIDIA $NVIDIA_NAME is Kepler or older; RPM Fusion's 470xx driver is end-of-life, so keeping nouveau"
        else
            want_nvidia=1
        fi
    fi

    if (( (want_nvidia || want_wl) && SECURE_BOOT )); then
        if ! setup_secure_boot_signing; then
            warn "Secure Boot signing isn't set up, so the NVIDIA/Broadcom drivers were skipped (they couldn't load). Fix it, then re-run with --force."
            want_nvidia=0 want_wl=0
        fi
    fi
    if (( want_nvidia )) && install_nvidia; then
        NVIDIA_INSTALLED=1
    fi
    if (( want_wl )) && install_broadcom; then
        WL_INSTALLED=1
    fi
    if (( NVIDIA_INSTALLED || WL_INSTALLED )); then
        build_kmods
    fi

    case $CPU_VENDOR in
        GenuineIntel|AuthenticAMD) info "CPU microcode for $CPU_VENDOR ships with linux-firmware/microcode_ctl, nothing to add" ;;
    esac
    if (( ! HAS_NVIDIA && ! NEEDS_BROADCOM_WL )); then
        ok "Intel/AMD graphics use the in-kernel drivers; no extra driver needed"
    fi
}

# Stops Akonadi and the PIM apps of the target user, which could otherwise restart it.
stop_pim_processes() {
    local uid runtime pattern='^(akonadi|kalendarac|korgac|kontact|kmail|korganizer|kaddressbook|akregator|kalarm|merkuro)'
    uid=$(id -u "$TARGET_USER" 2>/dev/null) || return 0
    runtime=$ROOT/run/user/$uid
    if [[ -S $runtime/bus ]] && command -v akonadictl &>/dev/null; then
        run_as_user env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
            akonadictl stop >/dev/null 2>&1 || true
    fi
    if pgrep -u "$TARGET_USER" "$pattern" &>/dev/null || pgrep -u "$TARGET_USER" -f 'akonadi/(mysql\.conf|db_data)' &>/dev/null; then
        run pkill -u "$TARGET_USER" "$pattern" || true
        run pkill -u "$TARGET_USER" -f 'akonadi/(mysql\.conf|db_data)' || true
        if (( ! DRY_RUN )); then
            local i
            for (( i = 0; i < 10; i++ )); do
                pgrep -u "$TARGET_USER" "$pattern" &>/dev/null || break
                sleep 1
            done
        fi
    fi
}

# Removes one group of packages after checking what else the transaction would take.
# Returns 1 if the removal was skipped or failed.
remove_batch() {  # $1 = label, rest = package names
    local label=$1
    shift
    local pkgs=("$@")
    info "Removing $label: ${pkgs[*]}"

    local out
    out=$(LC_ALL=C "$DNF" remove "${pkgs[@]}" --assumeno 2>&1 || true)
    if [[ $out != *"Transaction Summary"* && $out != *"Operation aborted"* ]]; then
        warn "Skipped removing $label: dnf couldn't plan it ($(tail -n 3 <<<"$out" | tr '\n' ' '))"
        return 1
    fi

    local -A installed=()
    local n names=() hits=() apps=() files
    while IFS= read -r n; do installed[$n]=1; done < <(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)
    mapfile -t names < <(awk 'NF >= 4 && $1 ~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/ { print $1 }' <<<"$out" | sort -u)
    for n in "${names[@]}"; do
        [[ -n ${installed[$n]:-} ]] || continue
        if [[ $n =~ $PROTECTED_REGEX ]]; then
            hits+=("$n")
        elif [[ ! $n =~ $PIM_REGEX && ! $n =~ $OFFICE_REGEX ]]; then
            files=$(rpm -ql "$n" 2>/dev/null || true)
            if [[ $files == *"/usr/share/applications/"*".desktop"* ]]; then
                apps+=("$n")
            fi
        fi
    done

    if (( ${#hits[@]} )); then
        warn "Skipped removing $label: it would also remove core desktop packages (${hits[*]})"
        return 1
    fi
    if (( ${#apps[@]} )); then
        warn "Removing $label also removes these apps, which use its libraries: ${apps[*]}"
        if (( DRY_RUN )); then
            info "(dry-run) a real run asks before removing them, or skips with --yes"
        elif (( ASSUME_YES )) || ! have_tty; then
            warn "Skipped removing $label to keep those apps. To remove it anyway: sudo dnf remove ${pkgs[*]}"
            return 1
        elif ! ask_yes_no "Remove them too? [y/N]" n; then
            warn "Skipped removing $label"
            return 1
        fi
    fi

    if ! run "$DNF" remove -y "${pkgs[@]}"; then
        warn "Removing $label failed"
        return 1
    fi
    ok "Removed $label"
}

# Deletes paths (globs relative to the target home) as the target user, so root never
# follows symlinks the user controls.
delete_user_paths() {
    local pattern path removed=0 matches
    for pattern in "$@"; do
        # Unquoted on purpose so globs expand inside the user's home.
        # shellcheck disable=SC2206
        matches=("$TARGET_HOME"/$pattern)
        for path in "${matches[@]}"; do
            [[ -e $path || -L $path ]] || continue
            run_as_user rm -rf -- "$path" || warn "Couldn't delete $path"
            removed=$((removed + 1))
        done
    done
    DELETED_COUNT=$((DELETED_COUNT + removed))
}

remove_pim_office() {
    section "Removing KDE PIM and LibreOffice"
    stop_pim_processes

    # User data is only deleted for a suite that is gone (or was never installed).
    local -a pim office
    local pim_gone=1 office_gone=1
    mapfile -t pim < <(installed_matching "$PIM_REGEX")
    mapfile -t office < <(installed_matching "$OFFICE_REGEX")
    if (( ${#pim[@]} )) && ! remove_batch "KDE PIM" "${pim[@]}"; then
        pim_gone=0
    fi
    if (( ${#office[@]} )) && ! remove_batch "LibreOffice" "${office[@]}"; then
        office_gone=0
    fi
    if (( ${#pim[@]} + ${#office[@]} == 0 )); then
        ok "No KDE PIM or LibreOffice packages installed"
    fi

    # Forget the groups so future group upgrades don't pull new members back in.
    local group
    for group in kde-pim libreoffice; do
        run "$DNF" group remove -y --no-packages "$group" >/dev/null 2>&1 || true
    done

    # Directories rpm no longer owns (caches, extensions, generated files).
    local dir
    for dir in "$ROOT"/usr/lib64/libreoffice "$ROOT"/usr/lib/libreoffice "$ROOT"/usr/share/akonadi "$ROOT"/etc/libreoffice; do
        if [[ -e $dir ]] && ! rpm -qf "${dir#"$ROOT"}" &>/dev/null; then
            run rm -rf -- "$dir"
        fi
    done

    if [[ -z $TARGET_HOME ]]; then
        warn "No home directory for '$TARGET_USER'; skipped deleting PIM/LibreOffice user data"
        return 0
    fi

    DELETED_COUNT=0
    if (( pim_gone )); then
        # The dnf transaction can take minutes; make sure nothing restarted Akonadi meanwhile.
        stop_pim_processes
        delete_user_paths "${PIM_JUNK[@]}"
    else
        warn "Kept KDE PIM data in $TARGET_HOME because KDE PIM is still installed"
    fi
    if (( office_gone )); then
        delete_user_paths "${OFFICE_JUNK[@]}"
    else
        warn "Kept LibreOffice settings in $TARGET_HOME because LibreOffice is still installed"
    fi
    ok "Removed $DELETED_COUNT PIM/LibreOffice data and config entries from $TARGET_HOME"

    local uid runtime
    uid=$(id -u "$TARGET_USER" 2>/dev/null) || return 0
    runtime=$ROOT/run/user/$uid
    if [[ -S $runtime/bus ]] && command -v kbuildsycoca6 &>/dev/null; then
        # The cache file name depends on the locale, so use the system one, not C.UTF-8.
        local lang
        lang=$(sed -n 's/^LANG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/etc/locale.conf" 2>/dev/null | head -n1 || true)
        run_as_user env -u LC_ALL LANG="${lang:-C.UTF-8}" XDG_RUNTIME_DIR="$runtime" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" kbuildsycoca6 --noincremental || true
    fi
}

setup_flathub() {
    section "Setting up Flathub"
    command -v flatpak &>/dev/null || dnf_install flatpak || true
    # Discover needs its Flatpak backend to show Flathub apps.
    is_installed plasma-discover-flatpak || dnf_install plasma-discover-flatpak || true
    if ! run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        warn "Couldn't add the Flathub remote"
        return 0
    fi
    run flatpak remote-modify --no-filter --enable flathub || warn "Couldn't remove Fedora's Flathub filter"

    # Fedora's own Flatpak remotes duplicate Flathub apps in Discover. Drop them if nothing uses them.
    local remote remotes origins
    remotes=$(flatpak remotes --columns=name 2>/dev/null || true)
    origins=$(flatpak list --columns=origin 2>/dev/null || true)
    for remote in fedora fedora-testing; do
        if grep -qx "$remote" <<<"$remotes" && ! grep -qx "$remote" <<<"$origins"; then
            run flatpak remote-delete --force "$remote" || warn "Couldn't remove the '$remote' Flatpak remote"
        fi
    done
    ok "Flathub enabled without Fedora's filter"
}

update_firmware() {
    section "Firmware updates"
    if [[ $VIRT != none ]] || (( IN_CONTAINER )); then
        info "Virtual machine or container, skipping firmware"
        return 0
    fi
    command -v fwupdmgr &>/dev/null || dnf_install fwupd || true
    run fwupdmgr refresh --force || warn "Couldn't refresh firmware metadata"

    local cmd=(fwupdmgr update -y --no-reboot-check --no-unreported-check)
    log_cmd "${cmd[*]}"
    if (( DRY_RUN )); then
        return 0
    fi
    local rc=0
    "${cmd[@]}" || rc=$?
    case $rc in
        0) ok "Firmware updated (some updates are applied on reboot)" ;;
        2) ok "Firmware already up to date" ;;
        *) warn "fwupdmgr exited with $rc; run 'fwupdmgr update' manually later (laptops must be on AC power)" ;;
    esac
}

apply_maintenance() {
    section "Maintenance defaults"
    run_systemctl enable --now fstrim.timer || warn "Couldn't enable fstrim.timer"
    write_file "$ROOT/etc/systemd/journald.conf.d/00-size.conf" "[Journal]
SystemMaxUse=500M"
    run_systemctl restart systemd-journald || warn "Couldn't restart systemd-journald"
    ok "fstrim.timer enabled, journal capped at 500M"
}

finish() {
    section "Done"
    if (( ! DRY_RUN )); then
        install -d -m 0755 "$STATE_DIR"
        date '+%F %T' > "$MARKER"
    fi

    local item
    printf '\n%sCompleted:%s\n' "$C_BOLD" "$C_RESET"
    for item in "${DONE[@]}"; do printf '  %s+%s %s\n' "$C_GREEN" "$C_RESET" "$item"; done
    if (( ${#WARNINGS[@]} )); then
        printf '\n%sWarnings:%s\n' "$C_BOLD" "$C_RESET"
        for item in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$item"; done
    fi
    printf '\nLog: %s\n' "$LOG"
    if (( ! DRY_RUN )); then
        printf 'Package changes are in "sudo dnf history list" (this run: transactions after #%s);\n' "${HISTORY_START:-0}"
        printf 'undo one with "sudo dnf history undo <ID>".\n'
    fi

    if (( MOK_PENDING )); then
        local password_hint="the one-time password you just created"
        if [[ -n $MOK_GENERATED_PASSWORD ]]; then
            password_hint="this one-time password: $MOK_GENERATED_PASSWORD (also saved in $MOK_PASSWORD_FILE)"
        elif (( MOK_PREVIOUS )); then
            password_hint="the one-time password you set when the key was first queued (forgot it? sudo mokutil --revoke-import, then re-run with --force)"
        fi
        cat <<EOF

${C_BOLD}${C_YELLOW}Secure Boot key enrollment on next boot:${C_RESET}
  1. A blue "Perform MOK management" screen appears. Press a key within 10 seconds.
  2. Choose "Enroll MOK" -> "Continue" -> "Yes".
  3. Type $password_hint, then choose "Reboot".
  If you miss it, run: sudo mokutil --import $MOK_CERT  and reboot again.
EOF
    fi

    if (( DRY_RUN )); then
        printf '\nDry run finished; nothing was changed.\n'
        return 0
    fi

    local reason="to load the updated system"
    (( KERNEL_UPDATED )) && reason="to boot the new kernel"
    (( NVIDIA_INSTALLED || WL_INSTALLED )) && reason="to load the new drivers"
    printf '\n%sA reboot is needed %s.%s\n' "$C_BOLD" "$reason" "$C_RESET"
    if (( OFFER_REBOOT && ! ASSUME_YES && ! IN_CONTAINER )) && have_tty; then
        if ask_yes_no "Reboot now? [Y/n]" y; then
            systemctl reboot
        fi
    fi
}

main() {
    parse_args "$@"
    setup_logging "$@"
    preflight
    detect_system
    print_plan

    prepare_dnf
    update_system
    enable_repos
    install_codecs
    install_drivers
    remove_pim_office
    setup_flathub
    update_firmware
    apply_maintenance
    finish
}

exec 3>&1
main "$@"
