#!/usr/bin/env bash
# fedora-kde-setup.sh - post-install setup for Fedora KDE Plasma (Fedora 41 or newer).
#
# Shows what's already done on this system and lets you pick what to do:
#   faster DNF, full system update, media codecs (RPM Fusion), drivers for the detected
#   hardware, removing KDE PIM and/or LibreOffice with their data, Flatpak + full Flathub,
#   firmware updates, SSD trim + journal size cap. Safe to run again any time.
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

readonly SCRIPT_VERSION=1.2.0

# FKS_ROOT prefixes every file the script reads or writes directly, so tests can fake a system.
readonly ROOT=${FKS_ROOT:-}
readonly STATE_DIR=$ROOT/var/lib/fedora-kde-setup
readonly STATE_FILE=$STATE_DIR/done
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
SELECT_ALL=0
STATUS_ONLY=0
LIST_STEPS=0
ONLY_STEPS=()
SKIP_STEPS=()

# The steps, in menu order. Weights reflect typical duration, for the progress bar.
readonly ALL_STEPS=(dnf update codecs drivers pim libreoffice flathub firmware maintenance)
declare -A STEP_WEIGHT=([dnf]=1 [update]=30 [codecs]=15 [drivers]=20 [pim]=5 [libreoffice]=5
                        [flathub]=5 [firmware]=10 [maintenance]=1)
# Recommended for almost everyone, or optional (a matter of taste).
declare -A STEP_TAG=([dnf]=recommended [update]=recommended [codecs]=recommended [drivers]=recommended
                     [pim]=optional [libreoffice]=optional [flathub]=recommended [firmware]=recommended
                     [maintenance]=optional)
declare -A STEP_TITLE=() STEP_WHY=() STEP_NA=() STEP_STATUS=() STEP_NOTE=()
declare -A SELECTED=() AUTO_SELECTED=() LEFTOVER_ONLY=() STATE_DATE=()

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
KERNEL_BEFORE="" NEWEST_KERNEL=""
MOK_PENDING=0 MOK_PREVIOUS=0 MOK_GENERATED_PASSWORD=""
NVIDIA_INSTALLED=0 WL_INSTALLED=0 PK_MASKED=0 LOG_PID="" DELETED_COUNT=0 LAST_CMD=""
HISTORY_START="" WORK_DIR=""
DRIVERS_NEED_KMOD=0 DRIVERS_WANT_NVIDIA=0 STEP_OK=1
DONE=() WARNINGS=() RAN_STEPS=() SKIPPED_STEPS=() FAILED_STEPS=() REBOOT_REASONS=()

# ---------------------------------------------------------------------------
# Output helpers

TTY_OUT=0
if [[ -t 1 ]]; then
    TTY_OUT=1
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_BLUE=$'\e[34m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_DIM=$'\e[2m'
    C_CYAN=$'\e[36m' C_MAGENTA=$'\e[35m'
else
    C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_CYAN="" C_MAGENTA=""
fi

STEP=0
section() { STEP=$((STEP + 1)); printf '\n%s==> [%d] %s%s\n' "$C_BOLD$C_BLUE" "$STEP" "$*" "$C_RESET"; }
info()    { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
hint()    { printf '%s  %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
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
    read -r answer </dev/tty || { printf '\n'; return 1; }
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
    cat <<'USAGE'
Usage: sudo bash fedora-kde-setup.sh [options]

Post-install setup for Fedora KDE Plasma (Fedora 41 or newer). Without options it shows
what's already done on this computer and a checklist to pick what to do.

Choosing steps:
      --only LIST    run only these steps (comma-separated IDs, see --list-steps)
      --all          run every step that applies and isn't done yet
      --skip LIST    with --all: leave these steps out
      --list-steps   list the step IDs and what each one does
      --status       show what's already done; change nothing

Other options:
  -y, --yes          don't ask questions (needs --only or --all)
  -n, --dry-run      print what would be done without changing anything
  -f, --force        with --only/--all: also re-run steps that are already done
      --no-reboot    don't offer to reboot at the end
  -u, --user NAME    whose KDE PIM/LibreOffice data to clean up (default: you)
  -h, --help         show this help
  -V, --version      show the version
USAGE
}

parse_step_list() {  # $1 = option name, $2 = comma-separated IDs, $3 = array to fill
    local id ids
    local -n out=$3
    [[ -n $2 ]] || die "$1 needs a list of steps (see --list-steps)"
    out=()
    IFS=, read -ra ids <<<"$2"
    for id in "${ids[@]}"; do
        id=${id// /}
        [[ -n $id ]] || continue
        if [[ " ${ALL_STEPS[*]} " != *" $id "* ]]; then
            die "Unknown step '$id' in $1. Valid steps: ${ALL_STEPS[*]}"
        fi
        out+=("$id")
    done
}

parse_args() {
    while (( $# )); do
        case $1 in
            -y|--yes)     ASSUME_YES=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -f|--force)   FORCE=1 ;;
            --no-reboot)  OFFER_REBOOT=0 ;;
            --all)        SELECT_ALL=1 ;;
            --status)     STATUS_ONLY=1 ;;
            --list-steps) LIST_STEPS=1 ;;
            --only)       parse_step_list --only "${2:-}" ONLY_STEPS; shift ;;
            --skip)       parse_step_list --skip "${2:-}" SKIP_STEPS; shift ;;
            --only=*)     parse_step_list --only "${1#--only=}" ONLY_STEPS ;;
            --skip=*)     parse_step_list --skip "${1#--skip=}" SKIP_STEPS ;;
            -u|--user)    TARGET_USER=${2:-}; [[ -n $TARGET_USER ]] || die "--user needs a name"; shift ;;
            --user=*)     TARGET_USER=${1#--user=}; [[ -n $TARGET_USER ]] || die "--user needs a name" ;;
            -h|--help)    usage; exit 0 ;;
            -V|--version) echo "fedora-kde-setup $SCRIPT_VERSION"; exit 0 ;;
            *)            usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done
    if (( ${#ONLY_STEPS[@]} && SELECT_ALL )); then
        die "Use either --only or --all, not both"
    fi
    if (( ${#SKIP_STEPS[@]} && ! SELECT_ALL )); then
        die "--skip only works together with --all"
    fi
    if (( STATUS_ONLY )); then
        DRY_RUN=1
    fi
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
    if [[ -z $TARGET_USER ]]; then
        # Only the KDE PIM / LibreOffice data cleanup needs it; checked once steps are chosen.
        TARGET_HOME=""
        return 0
    fi
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

    if (( EUID != 0 && ! STATUS_ONLY )); then
        require "Run this with sudo: sudo bash $0"
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

    local arch
    arch=$(uname -m)
    if [[ $arch != x86_64 ]]; then
        require "This script supports x86_64 only (found: $arch)"
    fi

    resolve_target_user
    read_state
    ok "${FEDORA_NAME}, user '${TARGET_USER:-unknown}'"
}

probe() {  # $1 = URL; true if it answers over HTTPS
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsIL --max-time 20 -o /dev/null "$1"
}

check_network() {
    local url
    local needs_rpmfusion=0
    if [[ -n ${SELECTED[codecs]:-} ]] || { [[ -n ${SELECTED[drivers]:-} ]] && (( DRIVERS_NEED_KMOD )); }; then
        needs_rpmfusion=1
    fi
    if (( needs_rpmfusion )); then
        url=$(rpmfusion_url free)
        if ! probe "$url" && ! probe "$(rpmfusion_url free download1.rpmfusion.org)"; then
            require "Can't download $url. Check the internet connection; right after a new Fedora release RPM Fusion can lag a few days."
        fi
    fi
    if [[ -n ${SELECTED[update]:-}${SELECTED[firmware]:-} ]] && ! probe https://mirrors.fedoraproject.org/; then
        require "Can't reach Fedora's mirrors (https://mirrors.fedoraproject.org). Check the internet connection."
    fi
    if [[ -n ${SELECTED[flathub]:-} ]] && ! probe https://dl.flathub.org/repo/flathub.flatpakrepo; then
        require "Can't reach Flathub (https://dl.flathub.org). Check the internet connection."
    fi
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

# ---------------------------------------------------------------------------
# Steps: descriptions, what's already done, choosing, progress

# Plain-language title and one-line "what and why" for every step.
init_steps() {
    STEP_TITLE=(
        [dnf]="Faster DNF downloads"
        [update]="Full system update"
        [codecs]="Media codecs and video acceleration"
        [drivers]="Drivers for your hardware"
        [pim]="Remove KDE PIM (KMail, Kontact, KOrganizer...)"
        [libreoffice]="Remove LibreOffice"
        [flathub]="Flathub as Discover's app store"
        [firmware]="Firmware updates"
        [maintenance]="SSD trim + smaller system logs"
    )
    STEP_WHY=(
        [dnf]="Picks the fastest mirror and downloads 10 files at once, so updates finish sooner."
        [update]="Installs all pending updates: security fixes, bug fixes and newer apps."
        [codecs]="Lets common video and music formats (MP4/H.264, HEVC, MP3...) play, using your GPU. Adds RPM Fusion."
        [drivers]="Installs drivers your hardware needs that Fedora can't ship (NVIDIA, Broadcom Wi-Fi) or VM guest tools."
        [pim]="Removes KDE's email, calendar and contacts apps if you don't use them. Deletes their data."
        [libreoffice]="Removes the office suite if you use something else. Deletes its settings."
        [flathub]="Enables the full Flathub store and makes it Discover's default; hides Fedora's duplicate Flatpak apps."
        [firmware]="Installs BIOS/UEFI and device firmware updates from your vendor; they fix bugs and security holes."
        [maintenance]="Keeps SSDs fast with a weekly trim, and stops system logs from growing past 500 MB."
    )
}

short_gpu_name() {  # "NVIDIA Corporation AD107M [GeForce RTX 4060] (rev a1)" -> "GeForce RTX 4060"
    local re='\[([^]]+)\]'
    if [[ $1 =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$1"
    fi
}

# Adapts the hardware-dependent steps to what detect_system found.
refine_steps() {
    if (( IN_CONTAINER )); then
        STEP_NA[drivers]="not needed in a container"
        STEP_NA[firmware]="not available in a container"
    elif [[ $VIRT != none ]]; then
        STEP_NA[firmware]="not available in a virtual machine"
        case $VIRT in
            kvm|qemu|vmware|oracle|microsoft)
                STEP_TITLE[drivers]="Guest tools for this virtual machine ($VIRT)"
                STEP_WHY[drivers]="Better screen resizing, clipboard sharing and performance in this virtual machine."
                ;;
            *)  STEP_NA[drivers]="no guest tools known for this virtual machine ($VIRT)" ;;
        esac
    else
        if (( HAS_NVIDIA )) && [[ $NVIDIA_GEN != unsupported ]]; then
            DRIVERS_WANT_NVIDIA=1
        fi
        if (( DRIVERS_WANT_NVIDIA || NEEDS_BROADCOM_WL )); then
            DRIVERS_NEED_KMOD=1
            local gpu
            gpu=$(short_gpu_name "$NVIDIA_NAME")
            if (( DRIVERS_WANT_NVIDIA && NEEDS_BROADCOM_WL )); then
                STEP_TITLE[drivers]="Drivers: NVIDIA $gpu + Broadcom Wi-Fi"
                STEP_WHY[drivers]="Installs NVIDIA's driver for full graphics speed and the driver your Broadcom Wi-Fi chip needs."
            elif (( DRIVERS_WANT_NVIDIA )) && [[ $NVIDIA_GEN == legacy ]]; then
                STEP_TITLE[drivers]="Drivers: NVIDIA $gpu"
                STEP_WHY[drivers]="Installs NVIDIA's legacy driver that still supports your older card, for full graphics speed."
            elif (( DRIVERS_WANT_NVIDIA )); then
                STEP_TITLE[drivers]="Drivers: NVIDIA $gpu"
                STEP_WHY[drivers]="Installs NVIDIA's official driver for full graphics speed, gaming and CUDA."
            else
                STEP_TITLE[drivers]="Drivers: Broadcom Wi-Fi"
                STEP_WHY[drivers]="Installs the driver your Broadcom Wi-Fi chip needs to work."
            fi
            if (( SECURE_BOOT )); then
                STEP_WHY[drivers]+=" Secure Boot: you'll confirm a key once at the next boot."
            fi
        elif (( HAS_NVIDIA )); then
            STEP_NA[drivers]="your NVIDIA card is too old for maintained drivers; the open-source driver stays"
        else
            STEP_NA[drivers]="nothing needed: your graphics and Wi-Fi use built-in drivers"
        fi
    fi
}

applicable() { [[ -z ${STEP_NA[$1]:-} ]]; }

# --- What's already done (read-only checks of the real system) -------------

dnf_conf_value() {  # $1 = key; prints its value from dnf.conf, or nothing
    [[ -r $DNF_CONF ]] || return 0
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]#]*).*/\1/p" "$DNF_CONF" | tail -n1 || true
}

is_true() { [[ ${1,,} =~ ^(1|true|yes|on)$ ]]; }

set_status() {  # $1 = step, $2 = done|partial|todo|unknown, $3 = note
    STEP_STATUS[$1]=$2
    STEP_NOTE[$1]=${3:-}
}

join_missing() {  # prints "a, b, c" or "a, b, c and N more"
    local n=$#
    if (( n > 3 )); then
        printf '%s, %s, %s and %d more' "$1" "$2" "$3" "$((n - 3))"
    else
        local IFS=,
        printf '%s' "$*" | sed 's/,/, /g'
    fi
}

status_dnf() {
    local good=0 mpd
    is_true "$(dnf_conf_value fastestmirror)" && good=$((good + 1))
    is_true "$(dnf_conf_value defaultyes)" && good=$((good + 1))
    mpd=$(dnf_conf_value max_parallel_downloads)
    if [[ $mpd =~ ^[0-9]+$ ]] && (( mpd >= 10 )); then
        good=$((good + 1))
    fi
    case $good in
        3) set_status dnf "done" "already set" ;;
        0) set_status dnf todo "" ;;
        *) set_status dnf partial "some settings missing" ;;
    esac
}

status_update() {
    if ! command -v "$DNF" &>/dev/null; then
        set_status update unknown "couldn't check for updates"
        return 0
    fi
    info "Checking for available updates (this can take a minute)..."
    local out rc=0 args=(-q check-upgrade)
    if (( EUID == 0 )); then
        args+=(--refresh)
    fi
    out=$("$DNF" "${args[@]}" 2>/dev/null) || rc=$?
    case $rc in
        0)   set_status update "done" "up to date" ;;
        100) set_status update todo "$(awk 'NF >= 3 && $1 ~ /\./' <<<"$out" | wc -l | tr -d ' ') updates available" ;;
        *)   set_status update unknown "couldn't check for updates" ;;
    esac
}

codecs_packages() {
    printf '%s\n' rpmfusion-free-release rpmfusion-nonfree-release ffmpeg gstreamer1-plugins-bad-freeworld \
        gstreamer1-plugins-ugly gstreamer1-plugin-libav gstreamer1-plugin-openh264
    (( HAS_INTEL )) && echo intel-media-driver
    (( HAS_AMD )) && echo mesa-va-drivers-freeworld
    return 0
}

status_codecs() {
    local p have=0 missing=()
    while IFS= read -r p; do
        if is_installed "$p"; then have=$((have + 1)); else missing+=("$p"); fi
    done < <(codecs_packages)
    if (( ${#missing[@]} == 0 )); then
        set_status codecs "done" "installed"
    elif (( have == 0 )); then
        set_status codecs todo ""
    else
        set_status codecs partial "missing $(join_missing "${missing[@]}")"
    fi
}

vm_tool_packages() {
    case $VIRT in
        kvm|qemu)  printf '%s\n' qemu-guest-agent spice-vdagent ;;
        vmware)    echo open-vm-tools-desktop ;;
        oracle)    echo virtualbox-guest-additions ;;
        microsoft) echo hyperv-daemons ;;
    esac
}

status_drivers() {
    applicable drivers || return 0
    local p have=0 missing=() running
    if [[ $VIRT != none ]]; then
        while IFS= read -r p; do
            if is_installed "$p"; then have=$((have + 1)); else missing+=("$p"); fi
        done < <(vm_tool_packages)
    else
        running=$(uname -r)
        if (( DRIVERS_WANT_NVIDIA )); then
            if is_installed akmod-nvidia || is_installed akmod-nvidia-580xx; then
                have=$((have + 1))
                if ! modinfo -k "$running" nvidia &>/dev/null; then
                    missing+=("nvidia module for the running kernel")
                elif [[ ! -d $ROOT/sys/module/nvidia ]]; then
                    missing+=("a reboot to load it$( ((SECURE_BOOT)) && echo ' (and Secure Boot key enrollment)')")
                fi
            else
                missing+=("NVIDIA driver")
            fi
        fi
        if (( NEEDS_BROADCOM_WL )); then
            if is_installed broadcom-wl; then
                have=$((have + 1))
                if ! modinfo -k "$running" wl &>/dev/null; then
                    missing+=("wl module for the running kernel")
                elif [[ ! -d $ROOT/sys/module/wl ]]; then
                    missing+=("a reboot to load it$( ((SECURE_BOOT)) && echo ' (and Secure Boot key enrollment)')")
                fi
            else
                missing+=("broadcom-wl")
            fi
        fi
    fi
    if (( ${#missing[@]} == 0 )); then
        set_status drivers "done" "installed"
    elif (( have == 0 )); then
        set_status drivers todo ""
    else
        set_status drivers partial "missing $(join_missing "${missing[@]}")"
    fi
}

has_user_data() {  # $@ = globs relative to the target home; true if any exists
    [[ -n $TARGET_HOME ]] || return 1
    local pattern matches path
    for pattern in "$@"; do
        # shellcheck disable=SC2206
        matches=("$TARGET_HOME"/$pattern)
        for path in "${matches[@]}"; do
            [[ -e $path || -L $path ]] && return 0
        done
    done
    return 1
}

status_suite() {  # $1 = pim | libreoffice
    local kind=$1 regex label n
    local -a junk
    if [[ $kind == pim ]]; then
        regex=$PIM_REGEX label="KDE PIM" junk=("${PIM_JUNK[@]}")
    else
        regex=$OFFICE_REGEX label=LibreOffice junk=("${OFFICE_JUNK[@]}")
    fi
    n=$(installed_matching "$regex" | grep -c . || true)
    LEFTOVER_ONLY[$kind]=0
    if (( n > 0 )); then
        set_status "$kind" todo "currently installed"
    elif has_user_data "${junk[@]}"; then
        LEFTOVER_ONLY[$kind]=1
        STEP_TITLE[$kind]="Remove leftover $label data"
        STEP_WHY[$kind]="$label is already uninstalled, but its data is still in your home folder. Deletes it."
        set_status "$kind" partial "app removed, data still in your home folder"
    else
        set_status "$kind" "done" "already removed"
    fi
}

# Reads a value from a remote's section of the system flatpak repo config.
remote_config() {  # $1 = remote, $2 = key
    local cfg=$ROOT/var/lib/flatpak/repo/config
    [[ -r $cfg ]] || return 0
    awk -v sect="[remote \"$1\"]" -v key="$2" '/^\[/ { s = ($0 == sect) }
        s && index($0, key "=") == 1 { print substr($0, length(key) + 2) }' "$cfg" | tail -n1 || true
}

flathub_config() {  # $1 = key
    remote_config flathub "$1"
}

status_flathub() {
    local missing=() cfg=$ROOT/var/lib/flatpak/repo/config origins
    command -v flatpak &>/dev/null || missing+=(Flatpak)
    is_installed plasma-discover-flatpak || missing+=("Discover's Flatpak support")
    if [[ ! -r $cfg ]] || ! grep -qx '\[remote "flathub"\]' "$cfg"; then
        missing+=(Flathub)
    elif [[ -n $(flathub_config xa.filter) ]]; then
        missing+=("the full (unfiltered) Flathub")
    elif is_true "$(flathub_config xa.disable)"; then
        missing+=("Flathub enabled")
    fi
    origins=$(flatpak list --columns=origin 2>/dev/null || true)
    if grep -qx '\[remote "fedora"\]' "$cfg" 2>/dev/null && ! is_true "$(remote_config fedora xa.disable)" \
        && ! grep -qx fedora <<<"$origins"; then
        missing+=("Fedora's duplicate Flatpak source disabled")
    fi
    if [[ -n $TARGET_HOME ]] \
        && ! grep -qx 'currentApplicationBackend=flatpak-backend' "$TARGET_HOME/.config/discoverrc" 2>/dev/null; then
        missing+=("Flathub as Discover's default")
    fi
    if (( ${#missing[@]} == 0 )); then
        set_status flathub "done" "already set up"
    elif [[ " ${missing[*]} " == *" Flatpak "* && ${#missing[@]} -ge 3 ]]; then
        set_status flathub todo ""
    else
        set_status flathub partial "missing $(join_missing "${missing[@]}")"
    fi
}

status_firmware() {
    applicable firmware || return 0
    if [[ -n ${STATE_DATE[firmware]:-} ]]; then
        set_status firmware unknown "last checked ${STATE_DATE[firmware]%% *}"
    else
        set_status firmware unknown "not checked yet"
    fi
}

status_maintenance() {
    local good=0 dropin=$ROOT/etc/systemd/journald.conf.d/00-size.conf
    if (( IN_CONTAINER )) || [[ $(systemctl is-enabled fstrim.timer 2>/dev/null || true) == enabled ]]; then
        good=$((good + 1))
    fi
    if [[ -f $dropin ]] && grep -q '^SystemMaxUse=' "$dropin"; then
        good=$((good + 1))
    fi
    case $good in
        2) set_status maintenance "done" "already set up" ;;
        0) set_status maintenance todo "" ;;
        *) set_status maintenance partial "partly set up" ;;
    esac
}

compute_status() {
    section "Checking what's already done"
    local id
    for id in "${ALL_STEPS[@]}"; do
        set_status "$id" todo ""
    done
    status_dnf
    status_update
    status_codecs
    status_drivers
    status_suite pim
    status_suite libreoffice
    status_flathub
    status_firmware
    status_maintenance
}

# Steps that count as "still to do" for --all and the "a"/"r" menu shortcuts.
wants_doing() {  # $1 = step
    applicable "$1" || return 1
    [[ ${STEP_STATUS[$1]} != "done" ]] || return 1
    # Deleting leftover data is never implied; it must be picked explicitly.
    (( ! ${LEFTOVER_ONLY[$1]:-0} ))
}

# --- Saved state: which steps this script finished, and when ---------------

read_state() {
    STATE_DATE=()
    [[ -r $STATE_FILE ]] || return 0
    local key rest id
    while read -r key rest; do
        [[ -n $key ]] || continue
        if [[ " ${ALL_STEPS[*]} " == *" $key "* ]]; then
            STATE_DATE[$key]=$rest
        else
            # v1.0/v1.1 wrote a single date after a complete run.
            for id in "${ALL_STEPS[@]}"; do
                STATE_DATE[$id]="$key${rest:+ $rest}"
            done
        fi
    done < "$STATE_FILE"
}

record_step() {  # $1 = step
    STATE_DATE[$1]=$(date '+%F %T')
    if (( DRY_RUN )); then
        return 0
    fi
    install -d -m 0755 "$STATE_DIR"
    local id tmp=$STATE_FILE.tmp
    for id in "${ALL_STEPS[@]}"; do
        if [[ -n ${STATE_DATE[$id]:-} ]]; then
            printf '%s %s\n' "$id" "${STATE_DATE[$id]}"
        fi
    done > "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

# --- Showing and choosing steps ---------------------------------------------

status_badge() {  # $1 = step
    local note=${STEP_NOTE[$1]}
    case ${STEP_STATUS[$1]} in
        done)    printf '%s✔ %s%s' "$C_GREEN" "${note:-already done}" "$C_RESET" ;;
        partial) printf '%s◐ partly done: %s%s' "$C_YELLOW" "$note" "$C_RESET" ;;
        *)       if [[ -n $note ]]; then printf '%s• %s%s' "$C_CYAN" "$note" "$C_RESET"; fi ;;
    esac
}

tag_label() {  # $1 = step
    if [[ ${STEP_TAG[$1]} == recommended ]]; then
        printf '%s[Recommended]%s' "$C_GREEN" "$C_RESET"
    else
        printf '%s[Optional]%s' "$C_MAGENTA" "$C_RESET"
    fi
}

# $1 = menu | status
draw_steps() {
    local mode=$1 i id box n_done=0 n_partial=0 n_todo=0 extra
    for id in "${ALL_STEPS[@]}"; do
        applicable "$id" || continue
        case ${STEP_STATUS[$id]} in
            done)    n_done=$((n_done + 1)) ;;
            partial) n_partial=$((n_partial + 1)) ;;
            *)       n_todo=$((n_todo + 1)) ;;
        esac
    done
    printf '\n  %sAlready done: %d%s   %sPartly done: %d%s   %sNot done yet: %d%s\n' \
        "$C_GREEN" "$n_done" "$C_RESET" "$C_YELLOW" "$n_partial" "$C_RESET" "$C_CYAN" "$n_todo" "$C_RESET"
    printf '  %s[✔]%s already done   %s[◐]%s partly done   [ ] not done yet' "$C_GREEN" "$C_RESET" "$C_YELLOW" "$C_RESET"
    if [[ $mode == menu ]]; then
        printf '   %s[x]%s selected' "$C_BOLD$C_CYAN" "$C_RESET"
    fi
    printf '\n\n'
    for i in "${!ALL_STEPS[@]}"; do
        id=${ALL_STEPS[i]}
        if ! applicable "$id"; then
            printf '  %s%d. [-] %s: %s%s\n' "$C_DIM" "$((i + 1))" "${STEP_TITLE[$id]}" "${STEP_NA[$id]}" "$C_RESET"
            continue
        fi
        # Picked steps show [x]; the rest show what's already in place.
        if [[ $mode == menu && -n ${SELECTED[$id]:-} ]]; then
            box="${C_BOLD}${C_CYAN}[x]${C_RESET} "
        else
            case ${STEP_STATUS[$id]} in
                done)    box="${C_GREEN}[✔]${C_RESET} " ;;
                partial) box="${C_YELLOW}[◐]${C_RESET} " ;;
                *)       box="[ ] " ;;
            esac
        fi
        extra=""
        if [[ -n ${AUTO_SELECTED[$id]:-} ]]; then
            extra=" $C_YELLOW(needed by Drivers)$C_RESET"
        fi
        printf '  %s%d.%s %s%s%s%s %s  %s%s\n' "$C_BOLD" "$((i + 1))" "$C_RESET" "$box" "$C_BOLD" \
            "${STEP_TITLE[$id]}" "$C_RESET" "$(tag_label "$id")" "$(status_badge "$id")" "$extra"
        printf '        %s%s%s\n' "$C_DIM" "${STEP_WHY[$id]}" "$C_RESET"
    done
}

print_step_list() {
    init_steps
    local id
    printf 'Steps (use the IDs with --only, --skip):\n\n'
    for id in "${ALL_STEPS[@]}"; do
        printf '  %-12s %s [%s]\n  %-12s %s\n\n' "$id" "${STEP_TITLE[$id]}" "${STEP_TAG[$id]^}" "" "${STEP_WHY[$id]}"
    done
}

resolve_dependencies() {
    # Drivers built on this machine need kernel-devel for the newest kernel, which only the
    # current repos have, so the system must be up to date first.
    if [[ -n ${AUTO_SELECTED[update]:-} ]] && ! { [[ -n ${SELECTED[drivers]:-} ]] && (( DRIVERS_NEED_KMOD )); }; then
        unset 'SELECTED[update]' 'AUTO_SELECTED[update]'
    fi
    if [[ -n ${SELECTED[drivers]:-} && -z ${SELECTED[update]:-} ]] && (( DRIVERS_NEED_KMOD )) \
        && [[ ${STEP_STATUS[update]} != "done" ]]; then
        if [[ " ${SKIP_STEPS[*]} " == *" update "* ]]; then
            unset 'SELECTED[drivers]'
            warn "Skipped the drivers: they need the system update, which --skip leaves out"
        else
            SELECTED[update]=1 AUTO_SELECTED[update]=1
        fi
    fi
}

select_step() {  # $1 = step
    SELECTED[$1]=1
}

selected_steps() {
    local id
    for id in "${ALL_STEPS[@]}"; do
        if [[ -n ${SELECTED[$id]:-} ]]; then
            printf '%s\n' "$id"
        fi
    done
}

select_from_flags() {
    local id
    if (( SELECT_ALL )); then
        for id in "${ALL_STEPS[@]}"; do
            [[ " ${SKIP_STEPS[*]} " == *" $id "* ]] && continue
            applicable "$id" || continue
            if wants_doing "$id" || { (( FORCE )) && (( ! ${LEFTOVER_ONLY[$id]:-0} )); }; then
                select_step "$id"
            elif [[ ${STEP_STATUS[$id]} == "done" ]]; then
                SKIPPED_STEPS+=("${STEP_TITLE[$id]} (already done)")
            fi
        done
    else
        for id in "${ONLY_STEPS[@]}"; do
            if ! applicable "$id"; then
                warn "Skipping ${STEP_TITLE[$id]}: ${STEP_NA[$id]}"
            elif [[ ${STEP_STATUS[$id]} == "done" ]] && (( ! FORCE )); then
                SKIPPED_STEPS+=("${STEP_TITLE[$id]} (already done; --force runs it again)")
            else
                select_step "$id"
            fi
        done
    fi
}

choose_steps_menu() {
    local line tok id n=${#ALL_STEPS[@]} count
    local -a toks
    while true; do
        draw_steps menu
        printf '\n  %sType numbers to select/unselect%s (e.g. "1 3 5"; selecting a [✔] step redoes it), %sr%s = all recommended not done yet,\n  %sa%s = everything not done yet, ' \
            "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '%sn%s = none, %sEnter%s = continue, %sq%s = quit\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
        printf '%s> %s' "$C_BOLD" "$C_RESET"
        if ! read -r line </dev/tty; then
            die "Aborted, nothing was changed."
        fi
        line=${line//,/ }
        read -ra toks <<<"$line"
        if (( ${#toks[@]} == 0 )); then
            count=$(selected_steps | grep -c . || true)
            if (( count > 0 )); then
                break
            fi
            hint "Nothing selected yet: type the numbers of the steps you want (or r for the recommended ones)."
            continue
        fi
        for tok in "${toks[@]}"; do
            case ${tok,,} in
                q|quit)
                    printf '\nNothing was changed.\n'
                    exit 0 ;;
                a|all)
                    for id in "${ALL_STEPS[@]}"; do wants_doing "$id" && select_step "$id"; done ;;
                r|rec|recommended)
                    for id in "${ALL_STEPS[@]}"; do
                        [[ ${STEP_TAG[$id]} == recommended ]] && wants_doing "$id" && select_step "$id"
                    done ;;
                n|none)
                    SELECTED=() AUTO_SELECTED=() ;;
                *)
                    if [[ $tok =~ ^[0-9]{1,2}$ ]] && (( 10#$tok >= 1 && 10#$tok <= n )); then
                        tok=$((10#$tok))
                        id=${ALL_STEPS[tok - 1]}
                        if ! applicable "$id"; then
                            hint "Step $tok isn't available: ${STEP_NA[$id]}."
                        elif [[ -n ${AUTO_SELECTED[$id]:-} ]]; then
                            hint "Step $tok is needed by the drivers step; untick that one first."
                        elif [[ -n ${SELECTED[$id]:-} ]]; then
                            unset "SELECTED[$id]"
                        else
                            select_step "$id"
                        fi
                    else
                        hint "\"$tok\" isn't a step number between 1 and $n."
                    fi ;;
            esac
        done
        resolve_dependencies
    done
}

choose_steps() {
    section "Choose what to do"
    if (( ${#ONLY_STEPS[@]} || SELECT_ALL )); then
        select_from_flags
    elif (( ASSUME_YES )); then
        die "Choose steps with --only ... or --all (see --list-steps). Nothing was changed."
    elif have_tty; then
        choose_steps_menu
    elif (( DRY_RUN )); then
        info "No terminal for the checklist: previewing every step that isn't done yet"
        SELECT_ALL=1
        select_from_flags
    else
        die "No terminal to show the checklist on. Choose steps with --only ... or --all, plus --yes."
    fi
    resolve_dependencies
}

# Steps that change packages, or need the network.
selection_touches_packages() {
    local id
    for id in $(selected_steps); do
        [[ $id == dnf || $id == maintenance ]] || return 0
    done
    return 1
}

selection_needs_network() {
    local id
    for id in $(selected_steps); do
        case $id in update|codecs|drivers|flathub|firmware) return 0 ;; esac
    done
    return 1
}

confirm_selection() {
    local id i=0
    printf '\n  %sWill do:%s\n' "$C_BOLD" "$C_RESET"
    for id in $(selected_steps); do
        i=$((i + 1))
        printf '   %d. %s%s\n' "$i" "${STEP_TITLE[$id]}" "${AUTO_SELECTED[$id]:+  (needed by Drivers)}"
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

# --- Progress ----------------------------------------------------------------

progress_line() {  # $1 = percent, $2 = text
    local pct=$1 text=$2 width=24 fill bar="" j
    fill=$(( pct * width / 100 ))
    if (( TTY_OUT )); then
        for (( j = 0; j < width; j++ )); do
            if (( j < fill )); then bar+="█"; else bar+="░"; fi
        done
        printf '\n%s%s[%s] %3d%%%s  %s%s%s\n' "$C_BOLD" "$C_GREEN" "$bar" "$pct" "$C_RESET" "$C_BOLD" "$text" "$C_RESET"
        printf '\e]0;fedora-kde-setup %d%%\a' "$pct" >/dev/tty 2>/dev/null || true
    else
        printf '\n[%d%%] %s\n' "$pct" "$text"
    fi
}

run_steps() {
    local -a ids
    local id total=0 done_weight=0 i=0
    mapfile -t ids < <(selected_steps)
    for id in "${ids[@]}"; do
        total=$((total + STEP_WEIGHT[$id]))
    done
    if selection_touches_packages; then
        prepare_packages
    fi
    for id in "${ids[@]}"; do
        i=$((i + 1))
        progress_line $(( total ? done_weight * 100 / total : 0 )) "Step $i of ${#ids[@]}: ${STEP_TITLE[$id]}"
        STEP_OK=1
        "step_$id"
        if (( STEP_OK )); then
            RAN_STEPS+=("${STEP_TITLE[$id]}")
            record_step "$id"
        else
            FAILED_STEPS+=("${STEP_TITLE[$id]}")
        fi
        done_weight=$((done_weight + STEP_WEIGHT[$id]))
    done
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
    # Only once PackageKit is idle, and only if this run updates the system itself: drop a
    # staged offline update so the same updates don't run again on the next boot.
    if [[ -n ${SELECTED[update]:-} ]] && [[ -e $ROOT/system-update || -L $ROOT/system-update ]]; then
        info "Cancelling a staged offline update; this script installs the same updates now"
        run pkcon offline-cancel >/dev/null 2>&1 || run rm -f "$ROOT/system-update"
    fi
}

# Sets a dnf.conf option unless the file already has it (or, for numbers, something higher).
ensure_dnf_option() {  # $1 = key, $2 = value, $3 = bool | min
    local key=$1 value=$2 current
    current=$(dnf_conf_value "$key")
    if [[ $3 == bool ]] && is_true "$current"; then
        info "$key is already set"
        return 0
    fi
    if [[ $3 == min && $current =~ ^[0-9]+$ ]] && (( current >= value )); then
        info "Kept your $key=$current"
        return 0
    fi
    set_dnf_option "$key" "$value"
}

last_transaction_id() {
    "$DNF" history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ { print $1 }' | sort -n | tail -n1 || true
}

# Before any package changes: remember where dnf history starts and pause Discover's updater.
prepare_packages() {
    HISTORY_START=$(last_transaction_id)
    pause_packagekit
}

step_dnf() {
    ensure_dnf_option fastestmirror True bool
    ensure_dnf_option max_parallel_downloads 10 min
    ensure_dnf_option defaultyes True bool
    ok "DNF: fastest mirror, parallel downloads"
}

step_update() {
    info "This can take a while"
    local history_before
    history_before=$(last_transaction_id)
    KERNEL_BEFORE=$(newest_kernel)
    run "$DNF" upgrade --refresh -y
    NEWEST_KERNEL=$(newest_kernel)
    if [[ $NEWEST_KERNEL != "$KERNEL_BEFORE" ]]; then
        REBOOT_REASONS+=("to start the new kernel")
    elif [[ $(last_transaction_id) != "$history_before" ]]; then
        REBOOT_REASONS+=("so updated system services and libraries are used")
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

    if ! is_installed distribution-gpg-keys && ! run "$DNF" install -y distribution-gpg-keys; then
        warn "Couldn't install distribution-gpg-keys, so RPM Fusion can't be verified"
        return 1
    fi
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
        if [[ ! -r $key ]]; then
            warn "RPM Fusion's signing key for Fedora $release isn't in distribution-gpg-keys ($keydir), so its packages can't be verified. Try again after the next Fedora update."
            return 1
        fi
        if ! run rpmkeys --import "$key"; then
            warn "Couldn't import RPM Fusion's signing key"
            return 1
        fi
        if ! download "$(rpmfusion_url "$repo")" "$file" \
            && ! download "$(rpmfusion_url "$repo" download1.rpmfusion.org)" "$file"; then
            warn "Couldn't download the RPM Fusion $repo release package"
            return 1
        fi
        if ! out=$(rpmkeys --checksig -- "$file" 2>&1) || [[ $out != "$file: digests signatures OK" ]]; then
            warn "Signature check failed for the RPM Fusion $repo release package, refusing to install it: $out"
            return 1
        fi
        if [[ $(rpm -qp --qf '%{NAME}' -- "$file" 2>/dev/null) != "rpmfusion-$repo-release" ]]; then
            warn "The downloaded file isn't the rpmfusion-$repo-release package, refusing to install it"
            return 1
        fi
        ok "RPM Fusion $repo release package signature verified"
        files+=("$file")
    done
    if (( DRY_RUN )); then
        log_cmd "$DNF install -y <verified rpmfusion-*-release packages>"
    elif ! run "$DNF" install -y "${files[@]}"; then
        warn "Installing the RPM Fusion release packages failed"
        return 1
    fi
}

enable_repos() {
    install_rpmfusion || return 1

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

step_codecs() {
    if ! enable_repos; then
        warn "Skipped the codecs: they come from RPM Fusion, which couldn't be set up"
        STEP_OK=0
        return 0
    fi
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
    else
        STEP_OK=0
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
        else
            STEP_OK=0
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
        else
            STEP_OK=0
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
    if check_installed "${pkgs[@]}"; then
        ok "VM guest tools: ${pkgs[*]}"
    else
        STEP_OK=0
    fi
}

# Builds kernel modules now instead of on first boot, and checks they exist.
build_kmods() {
    [[ -n $NEWEST_KERNEL ]] || NEWEST_KERNEL=$(newest_kernel)
    if [[ -z $NEWEST_KERNEL ]]; then
        warn "Couldn't determine the newest kernel; akmods will build modules at next boot"
        return 0
    fi
    local mod mods=() built=1
    (( NVIDIA_INSTALLED )) && mods+=(nvidia)
    (( WL_INSTALLED )) && mods+=(wl)
    for mod in "${mods[@]}"; do
        modinfo -k "$NEWEST_KERNEL" "$mod" &>/dev/null || built=0
    done
    if (( built && ! DRY_RUN )); then
        ok "Kernel modules (${mods[*]}) already built for $NEWEST_KERNEL"
        return 0
    fi

    info "Building kernel modules for $NEWEST_KERNEL (a few minutes)"
    dnf_install "kernel-devel-$NEWEST_KERNEL" || warn "Couldn't install kernel-devel-$NEWEST_KERNEL"
    run akmods --force --kernels "$NEWEST_KERNEL" || warn "akmods reported a problem"
    REBOOT_REASONS+=("to load the new drivers")
    if (( DRY_RUN )); then
        return 0
    fi

    for mod in "${mods[@]}"; do
        if ! modinfo -k "$NEWEST_KERNEL" "$mod" &>/dev/null; then
            warn "Kernel module '$mod' isn't built yet; akmods retries at boot (logs: /var/cache/akmods/)"
            STEP_OK=0
        elif (( SECURE_BOOT )) && [[ -z $(modinfo -k "$NEWEST_KERNEL" -F signer "$mod" 2>/dev/null || true) ]]; then
            warn "Kernel module '$mod' is built but not signed; it won't load with Secure Boot on"
            STEP_OK=0
        else
            ok "Kernel module '$mod' built for $NEWEST_KERNEL"
        fi
    done
}

step_drivers() {
    if [[ $VIRT != none ]]; then
        install_vm_tools
        return 0
    fi

    local want_nvidia=$DRIVERS_WANT_NVIDIA want_wl=$NEEDS_BROADCOM_WL
    # The NVIDIA and wl drivers come from RPM Fusion.
    if ! install_rpmfusion; then
        warn "Skipped the drivers: they come from RPM Fusion, which couldn't be set up"
        STEP_OK=0
        return 0
    fi

    if (( (want_nvidia || want_wl) && SECURE_BOOT )); then
        if ! setup_secure_boot_signing; then
            warn "Secure Boot signing isn't set up, so the NVIDIA/Broadcom drivers were skipped (they couldn't load). Fix it, then run the script again and pick the drivers step."
            want_nvidia=0 want_wl=0
            STEP_OK=0
        fi
    fi
    if (( want_nvidia )); then
        if install_nvidia; then NVIDIA_INSTALLED=1; else STEP_OK=0; fi
    fi
    if (( want_wl )); then
        if install_broadcom; then WL_INSTALLED=1; else STEP_OK=0; fi
    fi
    if (( NVIDIA_INSTALLED || WL_INSTALLED )); then
        build_kmods
        if { (( NVIDIA_INSTALLED )) && [[ ! -d $ROOT/sys/module/nvidia ]]; } \
            || { (( WL_INSTALLED )) && [[ ! -d $ROOT/sys/module/wl ]]; }; then
            REBOOT_REASONS+=("to load the new drivers")
        fi
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

refresh_menu_cache() {
    local uid runtime lang
    uid=$(id -u "$TARGET_USER" 2>/dev/null) || return 0
    runtime=$ROOT/run/user/$uid
    if [[ -S $runtime/bus ]] && command -v kbuildsycoca6 &>/dev/null; then
        # The cache file name depends on the locale, so use the system one, not C.UTF-8.
        lang=$(sed -n 's/^LANG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/etc/locale.conf" 2>/dev/null | head -n1 || true)
        run_as_user env -u LC_ALL LANG="${lang:-C.UTF-8}" XDG_RUNTIME_DIR="$runtime" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" kbuildsycoca6 --noincremental || true
    fi
}

# Removes KDE PIM or LibreOffice. Its user data is deleted only once the suite is gone.
remove_suite() {  # $1 = pim | libreoffice
    local kind=$1 label regex group dir
    local -a pkgs junk dirs
    if [[ $kind == pim ]]; then
        label="KDE PIM" regex=$PIM_REGEX group=kde-pim
        junk=("${PIM_JUNK[@]}") dirs=("$ROOT"/usr/share/akonadi)
        stop_pim_processes
    else
        label=LibreOffice regex=$OFFICE_REGEX group=libreoffice
        junk=("${OFFICE_JUNK[@]}") dirs=("$ROOT"/usr/lib64/libreoffice "$ROOT"/usr/lib/libreoffice "$ROOT"/etc/libreoffice)
    fi

    mapfile -t pkgs < <(installed_matching "$regex")
    if (( ${#pkgs[@]} )); then
        if ! remove_batch "$label" "${pkgs[@]}"; then
            warn "Kept $label data in ${TARGET_HOME:-the home folder} because $label is still installed"
            STEP_OK=0
            return 0
        fi
    else
        info "$label is not installed"
    fi

    # Forget the group so future group upgrades don't pull new members back in.
    run "$DNF" group remove -y --no-packages "$group" >/dev/null 2>&1 || true
    # Directories rpm no longer owns (caches, extensions, generated files).
    for dir in "${dirs[@]}"; do
        if [[ -e $dir ]] && ! rpm -qf "${dir#"$ROOT"}" &>/dev/null; then
            run rm -rf -- "$dir"
        fi
    done

    if [[ -z $TARGET_HOME ]]; then
        warn "No home directory for '$TARGET_USER'; skipped deleting $label user data"
        return 0
    fi
    if [[ $kind == pim ]] && (( ${#pkgs[@]} )); then
        # The dnf transaction can take minutes; make sure nothing restarted Akonadi meanwhile.
        stop_pim_processes
    fi
    DELETED_COUNT=0
    delete_user_paths "${junk[@]}"
    ok "Deleted $DELETED_COUNT $label data and settings entries from $TARGET_HOME"
    refresh_menu_cache
}

step_pim() {
    remove_suite pim
}

step_libreoffice() {
    remove_suite libreoffice
}

step_flathub() {
    command -v flatpak &>/dev/null || dnf_install flatpak || true
    # Discover needs its Flatpak backend to show Flathub apps.
    is_installed plasma-discover-flatpak || dnf_install plasma-discover-flatpak || true
    if ! run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        warn "Couldn't add the Flathub remote"
        STEP_OK=0
        return 0
    fi
    if ! run flatpak remote-modify --no-filter --enable flathub; then
        warn "Couldn't remove Fedora's Flathub filter"
        STEP_OK=0
    fi

    # Flathub wins over any other remote that offers the same app.
    run flatpak remote-modify --prio=10 flathub || warn "Couldn't raise Flathub's priority"

    # Fedora's own Flatpak remotes list the same apps again, so Discover shows them twice.
    # Disable them (reversible) unless apps are installed from them, which still need updates.
    local remote remotes origins
    remotes=$(flatpak remotes --columns=name 2>/dev/null || true)
    origins=$(flatpak list --columns=origin 2>/dev/null || true)
    for remote in fedora fedora-testing; do
        grep -qx "$remote" <<<"$remotes" || continue
        if grep -qx "$remote" <<<"$origins"; then
            run flatpak remote-modify --prio=1 "$remote" || true
            warn "Kept Fedora's '$remote' Flatpak source enabled because apps are installed from it; Flathub is preferred over it now"
        else
            run flatpak remote-modify --disable "$remote" || warn "Couldn't disable the '$remote' Flatpak source"
        fi
    done

    # Make Flatpak (Flathub) Discover's default source, like Discover's own "Make default" button.
    if [[ -n $TARGET_HOME ]] && command -v kwriteconfig6 &>/dev/null; then
        run_as_user kwriteconfig6 --file "$TARGET_HOME/.config/discoverrc" --group ResourcesModel \
            --key currentApplicationBackend flatpak-backend || warn "Couldn't make Flathub Discover's default source"
    else
        warn "Couldn't make Flathub Discover's default source (kwriteconfig6 not found); pick it in Discover > Settings"
    fi
    ok "Flathub enabled, unfiltered, and Discover's default source"
}

step_firmware() {
    command -v fwupdmgr &>/dev/null || dnf_install fwupd || true
    local refreshed=1
    if ! run fwupdmgr refresh --force; then
        warn "Couldn't refresh firmware metadata"
        refreshed=0
    fi

    local cmd=(fwupdmgr update -y --no-reboot-check --no-unreported-check)
    log_cmd "${cmd[*]}"
    if (( DRY_RUN )); then
        return 0
    fi
    local rc=0
    "${cmd[@]}" || rc=$?
    case $rc in
        0) ok "Firmware updated (some updates are applied on reboot)"
           REBOOT_REASONS+=("to apply the firmware updates") ;;
        2) if (( refreshed )); then ok "Firmware already up to date"; else STEP_OK=0; fi ;;
        *) warn "fwupdmgr exited with $rc; run 'fwupdmgr update' manually later (laptops must be on AC power)"
           STEP_OK=0 ;;
    esac
}

step_maintenance() {
    run_systemctl enable --now fstrim.timer || warn "Couldn't enable fstrim.timer"
    write_file "$ROOT/etc/systemd/journald.conf.d/00-size.conf" "[Journal]
SystemMaxUse=500M"
    run_systemctl restart systemd-journald || warn "Couldn't restart systemd-journald"
    ok "fstrim.timer enabled, journal capped at 500M"
}

finish() {
    section "Done"
    local n_run=${#RAN_STEPS[@]} n_failed=${#FAILED_STEPS[@]} item
    progress_line 100 "Finished: $n_run of $((n_run + n_failed)) steps done"
    if (( TTY_OUT )); then
        printf '\e]0;fedora-kde-setup: done\a' >/dev/tty 2>/dev/null || true
    fi

    if (( n_run )); then
        printf '\n%sDone:%s\n' "$C_BOLD" "$C_RESET"
        for item in "${RAN_STEPS[@]}"; do printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$item"; done
    fi
    if (( ${#SKIPPED_STEPS[@]} )); then
        printf '\n%sSkipped:%s\n' "$C_BOLD" "$C_RESET"
        for item in "${SKIPPED_STEPS[@]}"; do printf '  %s-%s %s\n' "$C_DIM" "$C_RESET" "$item"; done
    fi
    if (( n_failed )); then
        printf '\n%sNot completed (see warnings):%s\n' "$C_BOLD" "$C_RESET"
        for item in "${FAILED_STEPS[@]}"; do printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$item"; done
    fi
    if (( ${#WARNINGS[@]} )); then
        printf '\n%sWarnings:%s\n' "$C_BOLD" "$C_RESET"
        for item in "${WARNINGS[@]}"; do printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$item"; done
    fi
    printf '\nLog: %s\n' "$LOG"
    if [[ -n $HISTORY_START ]] && (( ! DRY_RUN )); then
        printf 'Package changes are in "sudo dnf history list" (this run: transactions after #%s);\n' "$HISTORY_START"
        printf 'undo one with "sudo dnf history undo <ID>".\n'
    fi
    printf 'Run the script again any time: it shows what is already done.\n'
    local script_dir
    script_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)
    if [[ ${script_dir##*/} == fedora-kde-postinstall ]] && (( ! DRY_RUN )); then
        printf 'After the reboot you can delete the download folder: rm -rf %s\n' "$script_dir"
    fi

    if (( MOK_PENDING )); then
        local password_hint="the one-time password you just created"
        if [[ -n $MOK_GENERATED_PASSWORD ]]; then
            password_hint="this one-time password: $MOK_GENERATED_PASSWORD (also saved in $MOK_PASSWORD_FILE)"
        elif (( MOK_PREVIOUS )); then
            password_hint="the one-time password you set when the key was first queued (forgot it? sudo mokutil --revoke-import, then run the script again and pick the drivers step)"
        fi
        cat <<MOK

${C_BOLD}${C_YELLOW}Secure Boot key enrollment on next boot:${C_RESET}
  1. A blue "Perform MOK management" screen appears. Press a key within 10 seconds.
  2. Choose "Enroll MOK" -> "Continue" -> "Yes".
  3. Type $password_hint, then choose "Reboot".
  If you miss it, run: sudo mokutil --import $MOK_CERT  and reboot again.
MOK
    fi

    if (( DRY_RUN )); then
        printf '\nDry run finished; nothing was changed.\n'
        return 0
    fi

    if (( ${#REBOOT_REASONS[@]} == 0 && ! MOK_PENDING )); then
        printf '\n%sNo reboot needed.%s\n' "$C_GREEN" "$C_RESET"
        return 0
    fi
    local reason=${REBOOT_REASONS[0]:-to enroll the Secure Boot key}
    printf '\n%sA reboot is recommended %s.%s\n' "$C_BOLD$C_YELLOW" "$reason" "$C_RESET"
    if (( OFFER_REBOOT && ! ASSUME_YES && ! IN_CONTAINER )) && have_tty; then
        if ask_yes_no "Reboot now? (recommended) [Y/n]" y; then
            systemctl reboot
        else
            printf 'OK. Remember to reboot soon.\n'
        fi
    fi
}

main() {
    parse_args "$@"
    if (( LIST_STEPS )); then
        print_step_list
        exit 0
    fi
    setup_logging "$@"
    preflight
    detect_system
    init_steps
    refine_steps
    compute_status
    if (( STATUS_ONLY )); then
        draw_steps status
        printf '\nNothing was changed. Run without --status to pick steps.\n'
        exit 0
    fi

    choose_steps
    if [[ -z $(selected_steps) ]]; then
        printf '\nNothing to do: the selected steps are already done (--force runs them again).\n'
        exit 0
    fi
    if [[ -n ${SELECTED[pim]:-}${SELECTED[libreoffice]:-} && -z $TARGET_HOME ]]; then
        require "Can't tell whose KDE PIM/LibreOffice data to clean up. Run it with sudo from your own account, or pass --user NAME."
    fi
    if selection_touches_packages; then
        check_safety_rails
    fi
    take_lock
    if selection_needs_network; then
        check_network
    fi
    confirm_selection
    run_steps
    finish
}

exec 3>&1
main "$@"
