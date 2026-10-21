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
    # Test mode as root: only accept a fake root that nobody else could have prepared or
    # swapped, so the directory and every parent must be root-owned and not writable by
    # others (sticky directories like /tmp are fine: others can't rename what's in them).
    fks_dir=$(realpath -e -- "$FKS_ROOT" 2>/dev/null) || fks_dir=""
    FKS_ROOT=$fks_dir
    while [[ -n $fks_dir ]]; do
        fks_mode=$(stat -c '%u %a' -- "$fks_dir" 2>/dev/null) || fks_mode="1 777"
        if [[ ${fks_mode%% *} != 0 ]] \
            || (( (8#${fks_mode#* } & 8#022) && !(8#${fks_mode#* } & 8#1000) )); then
            fks_dir=""
            FKS_ROOT=""
            break
        fi
        [[ $fks_dir == / ]] && break
        fks_dir=${fks_dir%/*}
        fks_dir=${fks_dir:-/}
    done
    if [[ -z $FKS_ROOT ]]; then
        echo "FKS_ROOT is a test-only setting and must be a root-owned directory nobody else can write to." >&2
        exit 1
    fi
    unset fks_dir fks_mode
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
# Recommended for almost everyone, optional (a matter of taste), or removals that delete data.
declare -A STEP_TAG=([dnf]=recommended [update]=recommended [codecs]=recommended [drivers]=recommended
                     [pim]=remove [libreoffice]=remove [flathub]=recommended [firmware]=recommended
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
WARNINGS=() RAN_STEPS=() SKIPPED_STEPS=() FAILED_STEPS=() REBOOT_REASONS=()

# ---------------------------------------------------------------------------
# Output helpers

TTY_OUT=0
if [[ -t 1 ]]; then
    TTY_OUT=1
fi
# Colors only on a real terminal, and not when NO_COLOR is set (no-color.org).
if (( TTY_OUT )) && [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_BLUE=$'\e[34m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RED=$'\e[31m' C_DIM=$'\e[2m'
    C_CYAN=$'\e[36m' C_MAGENTA=$'\e[35m'
else
    C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_CYAN="" C_MAGENTA=""
fi

section() { printf '\n%s== %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info()    { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
hint()    { printf '%s  %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
ok()      { printf '%s  ✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
# Messages can include file names from the user's home: show control characters as "?" so
# a crafted name can't send escape sequences to the terminal.
printable() { local s=$*; printf '%s' "${s//[[:cntrl:]]/?}"; }
warn()    { local m; m=$(printable "$*"); printf '%s  Warning:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$m" >&2; WARNINGS+=("$m"); }
die()     { printf '%sError:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }
add_reboot_reason() {
    local reason
    for reason in "${REBOOT_REASONS[@]}"; do
        [[ $reason == "$1" ]] && return 0
    done
    REBOOT_REASONS+=("$1")
}
# fd 3 is the terminal/log, so a command's own redirections never hide its log line.
log_cmd() { printf '%s  $ %s%s\n' "$C_DIM" "$(printable "$*")" "$C_RESET" >&3; }

on_error() {
    local rc=$1 line=$2 cmd=$3
    # A failing $(...) is reported once, by the shell that uses its result.
    (( BASH_SUBSHELL == 0 )) || return 0
    # Leave the checklist screen first, or the message vanishes with it.
    if (( ${MENU_ACTIVE:-0} )); then
        leave_menu
    fi
    # Drop on_error itself and bash's implicit outermost "main" frame.
    local where=${FUNCNAME[*]:1:${#FUNCNAME[@]}-2}
    if [[ $cmd == '"$@"' && -n $LAST_CMD ]]; then
        cmd=$LAST_CMD
    fi
    printf 'ERROR (for bug reports): exit %s at line %s in %s: %s\n' \
        "$rc" "$line" "${where// / <- }" "$cmd" >> "$LOG" 2>/dev/null || true
    printf '%sError:%s this command failed (exit code %s): %s\n' "$C_RED$C_BOLD" "$C_RESET" "$rc" "$cmd" >&2
}

cleanup() {
    local rc=$?
    if (( ${MENU_ACTIVE:-0} )); then
        leave_menu
    fi
    if (( ${TITLE_SET:-0} )); then
        printf '\e]0;\a' 2>/dev/null >/dev/tty || true   # give the window its own title back
    fi
    if (( rc != 0 && ${RUN_STARTED:-0} && ! ${FINISHED:-0} )); then
        print_stop_summary
    fi
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
trap 'on_interrupt' INT TERM
# Keep going if an SSH session drops; dnf inherits this too.
trap '' HUP

on_interrupt() {
    if (( ${MENU_ACTIVE:-0} )); then
        leave_menu
    fi
    if (( ! ${RUN_STARTED:-0} )); then
        printf '\nStopped. Nothing was changed.\n' >&2
        exit 130
    fi
    die "Stopped by Ctrl-C"
}

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

# Throws away keys typed earlier (e.g. Enter pressed while dnf ran) before asking anything.
# Drops keys typed ahead (or Enter held down) so they can't answer the next question:
# waits until nothing has been typed for 0.3 seconds.
flush_input() {
    local junk
    while IFS= read -rs -t 0.3 -n 1 junk </dev/tty 2>/dev/null; do :; done
    return 0
}

# Prints a question: to the log as usual, and also straight to the terminal when the
# output is redirected, so the script never waits on a question nobody can see.
ask_print() {  # printf arguments
    # shellcheck disable=SC2059
    printf "$@"
    if (( ! TTY_OUT )); then
        # shellcheck disable=SC2059
        printf "$@" 2>/dev/null >/dev/tty || true
    fi
}

ask_yes_no() {  # $1 = prompt, $2 = default (y/n)
    local answer=""
    flush_input
    ask_print '%s%s%s ' "$C_BOLD" "$1" "$C_RESET"
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
Set up a freshly installed Fedora KDE Plasma (Fedora 41 or newer): shows what's already
done on this computer and lets you pick what to do from a checklist.

Examples:
  sudo bash fedora-kde-setup.sh                      open the checklist (recommended)
  sudo bash fedora-kde-setup.sh --status             show what's already done; change nothing
  sudo bash fedora-kde-setup.sh --dry-run            preview every command; change nothing
  sudo bash fedora-kde-setup.sh --all --yes          everything that applies, no questions
                                                     (never removes apps; those need --only)
  sudo bash fedora-kde-setup.sh --only codecs,flathub --yes

Steps: dnf update codecs drivers flathub firmware maintenance pim libreoffice
       (what each one does: --list-steps)

Options:
      --only LIST    run only these steps (comma-separated)
      --all          run every step that applies and isn't done yet, except app removals
      --skip LIST    with --all: leave these steps out
      --list-steps   list the steps and what each one does
      --status       show what's already done; change nothing
  -n, --dry-run      print what would be done; change nothing
  -y, --yes          don't ask questions (needs --only or --all)
  -f, --force        with --only/--all: also redo steps that are already done
      --no-reboot    don't offer to reboot at the end
  -u, --user NAME    whose KDE PIM/LibreOffice data to clean up (default: you)
  -V, --version      show the version
  -h, --help         show this help

Docs and help: https://github.com/IamAndelib/fedora-kde-postinstall
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
            *)            die "Unknown option '$1'. See --help." ;;
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
        TARGET_USER="" TARGET_HOME=""   # dry run: carry on without a user
        return 0
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
    printf '\n%sFedora KDE post-install setup %s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
    printf 'Checks your computer, shows what is already done, and lets you choose what to do next.\n'
    section "Checking your system"

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
    section "Your hardware"

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
                # Once wl itself is loaded the chip has a wireless interface too, so an
                # installed broadcom-wl still counts.
                if [[ $vendor == 0x14e4 && $device =~ $WL_DEVICE_REGEX ]] \
                    && { is_installed broadcom-wl || ! has_wireless_phy "$dev"; }; then
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
    if [[ $mpd =~ ^[0-9]+$ ]] && (( 10#$mpd >= 10 )); then
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
                    missing+=("a reboot to load it$( ((! SECURE_BOOT)) || echo ' (and Secure Boot key enrollment)')")
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
                    missing+=("a reboot to load it$( ((! SECURE_BOOT)) || echo ' (and Secure Boot key enrollment)')")
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
    local missing=() cfg=$ROOT/var/lib/flatpak/repo/config origins no_flatpak=0
    command -v flatpak &>/dev/null || { missing+=(Flatpak); no_flatpak=1; }
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
    # The file is in the user's home: only read a regular file, and don't hang on odd ones.
    local discoverrc=$TARGET_HOME/.config/discoverrc
    if [[ -n $TARGET_HOME ]] && ! { [[ -f $discoverrc ]] \
        && timeout 5 grep -qx 'currentApplicationBackend=flatpak-backend' -- "$discoverrc" </dev/null 2>/dev/null; }; then
        missing+=("Flathub as Discover's default")
    fi
    if (( ${#missing[@]} == 0 )); then
        set_status flathub "done" "already set up"
    elif (( no_flatpak && ${#missing[@]} >= 3 )); then
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
    # Removals delete data, so "all" and "recommended" never include them.
    [[ ${STEP_TAG[$1]} != remove ]] || return 1
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

readonly STEP_GROUPS=(recommended optional remove)
declare -A GROUP_TITLE=([recommended]="RECOMMENDED" [optional]="OPTIONAL"
                        [remove]="REMOVE APPS YOU DON'T USE  (deletes their data)")
# Typical duration, shown on the review screen and step headers: "min max" minutes.
declare -A STEP_MINUTES=([dnf]="0 1" [update]="5 30" [codecs]="2 10" [drivers]="5 15" [pim]="1 3"
                         [libreoffice]="1 3" [flathub]="1 3" [firmware]="1 5" [maintenance]="0 1")
declare -A STEP_SHORT=([dnf]="DNF" [update]="System update" [codecs]="Codecs" [drivers]="Drivers"
                       [pim]="KDE PIM removed" [libreoffice]="LibreOffice removed" [flathub]="Flathub"
                       [firmware]="Firmware" [maintenance]="SSD trim + logs")
declare -A REMOVAL_APPS=() REMOVAL_DATA=()

status_badge() {  # $1 = step; plain text
    local note=${STEP_NOTE[$1]}
    case ${STEP_STATUS[$1]} in
        done)    printf '✔ %s' "${note:-already done}" ;;
        partial) printf '◐ partly done: %s' "$note" ;;
        *)       if [[ -n $note ]]; then printf '• %s' "$note"; fi ;;
    esac
}

badge_color() {  # $1 = step
    case ${STEP_STATUS[$1]} in
        done)    printf '%s' "$C_GREEN" ;;
        partial) printf '%s' "$C_YELLOW" ;;
        *)       printf '%s' "$C_CYAN" ;;
    esac
}

time_text() {  # $1 = step; "usually 5-30 min"
    local lo hi
    read -r lo hi <<<"${STEP_MINUTES[$1]}"
    if (( hi <= 1 )); then
        printf 'under a minute'
    else
        printf 'usually %d-%d min' "$lo" "$hi"
    fi
}

pad() {  # $1 = number of spaces (none if negative)
    if (( $1 > 0 )); then printf '%*s' "$1" ''; fi
}

trunc() {  # $1 = text, $2 = width; cuts with "…"
    local text=$1 width=$2
    if (( width < 1 )); then
        return 0
    elif (( ${#text} <= width )); then
        printf '%s' "$text"
    else
        printf '%s…' "${text:0:width-1}"
    fi
}

term_size() {  # sets TERM_ROWS and TERM_COLS
    local size
    size=$(stty size </dev/tty 2>/dev/null || true)
    TERM_SIZE=$size   # as reported, to notice a resize
    if [[ $size =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)$ ]]; then
        TERM_ROWS=${BASH_REMATCH[1]} TERM_COLS=${BASH_REMATCH[2]}
    else
        TERM_ROWS=24 TERM_COLS=80   # size unknown
    fi
}

# Steps the user can still choose, grouped: recommended, optional, removals.
menu_items() {
    local group id
    for group in "${STEP_GROUPS[@]}"; do
        for id in "${ALL_STEPS[@]}"; do
            if [[ ${STEP_TAG[$id]} == "$group" ]] && applicable "$id" && [[ ${STEP_STATUS[$id]} != "done" ]]; then
                printf '%s\n' "$id"
            fi
        done
    done
}

# One-line summaries of what's done and what doesn't apply here.
overview_lines() {  # $1 = width; prints "done|..." and "na|..." lines
    local width=$1 id done_list="" na_list=""
    for id in "${ALL_STEPS[@]}"; do
        if ! applicable "$id"; then
            na_list+="${na_list:+, }${STEP_SHORT[$id]}"
        elif [[ ${STEP_STATUS[$id]} == "done" ]]; then
            done_list+="${done_list:+, }${STEP_SHORT[$id]}"
        fi
    done
    printf 'done|%s\n' "$(trunc "✔ Already done: ${done_list:-nothing yet}" "$width")"
    if [[ -n $na_list ]]; then
        printf 'na|%s\n' "$(trunc "– Not needed here: $na_list" "$width")"
    fi
}

# Full overview, used by --status and when everything is done.
print_overview() {
    local id
    printf '\n  %s✔ Already done on this computer%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
    local any=0
    for id in "${ALL_STEPS[@]}"; do
        if applicable "$id" && [[ ${STEP_STATUS[$id]} == "done" ]]; then
            printf '      %s✔%s %s (%s)\n' "$C_GREEN" "$C_RESET" "${STEP_TITLE[$id]}" "${STEP_NOTE[$id]:-done}"
            any=1
        fi
    done
    (( any )) || printf '      nothing yet\n'
    any=0
    for id in "${ALL_STEPS[@]}"; do
        if ! applicable "$id"; then
            (( any )) || printf '\n  %s– Not needed on this computer%s\n' "$C_BOLD" "$C_RESET"
            printf '      %s (%s)\n' "${STEP_TITLE[$id]}" "${STEP_NA[$id]}"
            any=1
        fi
    done
}

draw_steps() {  # --status report
    local -a items
    local id group last=""
    print_overview
    mapfile -t items < <(menu_items)
    printf '\n  %sStill to do%s\n' "$C_BOLD" "$C_RESET"
    if (( ${#items[@]} == 0 )); then
        printf '      %snothing: everything that applies is done%s\n' "$C_GREEN" "$C_RESET"
    fi
    for id in "${items[@]}"; do
        group=${STEP_TAG[$id]}
        if [[ $group != "$last" ]]; then
            printf '    %s%s%s\n' "$C_BOLD" "${GROUP_TITLE[$group]}" "$C_RESET"
            last=$group
        fi
        printf '      [ ] %s  %s%s%s\n' "${STEP_TITLE[$id]}" "$(badge_color "$id")" "$(status_badge "$id")" "$C_RESET"
        printf '          %s\n' "${STEP_WHY[$id]}"
    done
}

menu_row() {  # $1 = step, $2 = highlighted (0/1), $3 = width
    local id=$1 hl=$2 width=$3 box="[ ]" title badge extra="" plain room
    if [[ -n ${SELECTED[$id]:-} ]]; then box="[x]"; fi
    [[ -n ${AUTO_SELECTED[$id]:-} ]] && extra="  (needed by Drivers)"
    title=${STEP_TITLE[$id]}
    badge=$(status_badge "$id")
    room=$(( width - 8 ))
    title=$(trunc "$title" "$room")
    room=$(( room - ${#title} - 2 ))
    badge=$(trunc "$badge$extra" "$room")
    if (( hl )); then
        plain="> $box $title${badge:+  $badge}"
        printf '  \e[7m%s%s%s%s\n' "$C_BOLD" "$plain" "$(pad $(( width - 2 - ${#plain} )))" "$C_RESET"
    else
        if [[ $box == "[x]" ]]; then box="${C_BOLD}${C_CYAN}[x]${C_RESET}"; fi
        printf '    %s %s%s%s%s\n' "$box" "$C_BOLD" "$title" "$C_RESET" \
            "${badge:+  $(badge_color "$id")$badge$C_RESET}"
    fi
}

draw_menu() {  # $1 = cursor row, $2 = message, rest = selectable step IDs
    local cur=$1 msg=$2 i id count width line group last="" why_all=1 total
    shift 2
    local -a items=("$@") top=() middle=() bottom=() line_item=()
    local -A item_line=()
    term_size
    width=$(( TERM_COLS - 1 ))
    count=$(selected_steps | grep -c . || true)

    top+=("  $C_BOLD$(trunc "Fedora KDE setup: choose what to do" $((width - 2)))$C_RESET")
    while IFS='|' read -r kind line; do
        if [[ $kind == "done" ]]; then top+=("  $C_GREEN$line$C_RESET"); else top+=("  $line"); fi
    done < <(overview_lines $((width - 2)))
    top+=("")

    local plural="s" b_cont b_quit b_help b_why
    (( count == 1 )) && plural=""
    i=${#items[@]}
    if (( cur == i )); then
        line="> ▶ Continue with $count selected step$plural"
        b_cont="  "$'\e[7m'"$C_BOLD$line$(pad $(( width - 2 - ${#line} )))$C_RESET"
        b_why="Shows a summary of what will happen; nothing changes until you confirm."
    else
        b_cont="    $C_GREEN▶ Continue with $count selected step$plural$C_RESET"
    fi
    if (( cur == i + 1 )); then
        line="> Quit without changes"
        b_quit="  "$'\e[7m'"$C_BOLD$line$(pad $(( width - 2 - ${#line} )))$C_RESET"
        b_why="Leaves without changing anything."
    else
        b_quit="    Quit without changes"
    fi
    if (( cur < i )); then
        b_why=${STEP_WHY[${items[cur]}]}
    fi
    b_why="  $C_DIM$(trunc "ℹ $b_why" $((width - 2)))$C_RESET"
    if (( width >= 78 )); then
        b_help="  $(trunc "↑↓ move · Enter select · r recommended · a all · n none · ? help · q quit" $((width - 2)))"
    else
        b_help="  $(trunc "↑↓ move · Enter select · ? help · q quit" $((width - 2)))"
    fi
    # A message takes the place of the blank or explanation line, so the layout never
    # changes height (and rows never move under the mouse).
    local b_gap=""
    if [[ -n $msg ]]; then
        b_why="  $C_YELLOW$(trunc "$msg" $((width - 2)))$C_RESET" b_gap=$b_why
    fi

    # Middle: group headings and steps. Show every explanation under its step if it all
    # fits. Otherwise show only the highlighted step's, in a fixed line above Continue (so
    # rows don't shift as the highlight moves); in a short window also drop the overview,
    # spacing and key help. bpos = where Continue is in the bottom part.
    local pass bpos
    for pass in 1 2 3; do
        case $pass in
            1) bottom=("$b_gap" "$b_cont" "$b_quit" "" "$b_help") bpos=1 ;;
            2) bottom=("" "$b_why" "$b_cont" "$b_quit" "" "$b_help") bpos=2 why_all=0 ;;
            3)
                # Scrolling the full layout is fine while a few steps still show at a time.
                if (( TERM_ROWS - 1 - ${#top[@]} - ${#bottom[@]} - 2 >= 4 )); then
                    break
                fi
                top=("${top[0]}")
                bottom=("$b_why" "$b_cont" "$b_quit") bpos=1 ;;
        esac
        middle=() item_line=() line_item=() last=""
        for i in "${!items[@]}"; do
            id=${items[i]}
            group=${STEP_TAG[$id]}
            if [[ $group != "$last" ]]; then
                [[ -n $last ]] && middle+=("")
                case $group in
                    recommended) middle+=("  $C_BOLD$C_CYAN${GROUP_TITLE[$group]}$C_RESET") ;;
                    optional)    middle+=("  $C_BOLD$C_MAGENTA${GROUP_TITLE[$group]}$C_RESET") ;;
                    *)           middle+=("  $C_BOLD$C_RED$(trunc "${GROUP_TITLE[$group]}" $((width - 2)))$C_RESET") ;;
                esac
                last=$group
            fi
            item_line[$i]=${#middle[@]}
            line_item[${#middle[@]}]=$i
            middle+=("$(menu_row "$id" $(( i == cur )) "$width")")
            if (( why_all )); then
                line_item[${#middle[@]}]=$i
                middle+=("        $(trunc "${STEP_WHY[$id]}" $((width - 8)))")
            fi
        done
        total=$(( ${#top[@]} + ${#middle[@]} + ${#bottom[@]} ))
        if (( total <= TERM_ROWS - 1 )); then
            break
        fi
    done

    # Still too tall: scroll the middle part so the highlighted step stays visible.
    local room=$(( TERM_ROWS - 1 - ${#top[@]} - ${#bottom[@]} - 2 )) start=0 focus
    local shown=${#middle[@]} skip=0 m
    MENU_ROW_ITEM=()
    if (( (total > TERM_ROWS - 1 && room < 1) || TERM_COLS < 30 )); then
        printf '\e[H\e[2J'
        printf '%s\n' "Window too small." "Make it bigger, or press q to quit."
        return 0
    fi
    if (( total > TERM_ROWS - 1 )); then
        # Scroll only as far as needed to keep the highlighted step (and its explanation)
        # in view, so the list doesn't jump around under the mouse.
        local focus_end
        if (( cur < ${#items[@]} )); then focus=${item_line[$cur]}; else focus=$(( ${#middle[@]} - 1 )); fi
        focus_end=$focus
        if [[ ${line_item[focus + 1]:-} == "${line_item[focus]:-x}" ]]; then
            focus_end=$(( focus + 1 ))
        fi
        start=$MENU_START
        if (( focus < start )); then
            start=$focus
            # Show the group heading above the first step of a group too.
            if (( start > 0 )) && [[ -z ${line_item[start - 1]:-} ]]; then
                start=$(( start - 1 ))
            fi
        fi
        if (( focus_end >= start + room )); then
            start=$(( focus_end - room + 1 ))
        fi
        (( start <= ${#middle[@]} - room )) || start=$(( ${#middle[@]} - room ))
        (( start >= 0 )) || start=0
        MENU_START=$start
        local -a window=("${middle[@]:start:room}")
        shown=$room skip=1
        if (( start > 0 )); then
            window=("  ↑ $start more line(s)" "${window[@]}")
        else
            window=("" "${window[@]}")
        fi
        if (( start + room < ${#middle[@]} )); then
            window+=("  ↓ $(( ${#middle[@]} - start - room )) more line(s)")
        fi
        middle=("${window[@]}")
    fi

    # Which step each screen row shows (rows count from 1), so mouse clicks can find it.
    for m in "${!line_item[@]}"; do
        if (( m >= start && m < start + shown )); then
            MENU_ROW_ITEM[${#top[@]} + 1 + skip + m - start]=${line_item[m]}
        fi
    done
    MENU_ROW_ITEM[${#top[@]} + ${#middle[@]} + bpos + 1]=${#items[@]}
    MENU_ROW_ITEM[${#top[@]} + ${#middle[@]} + bpos + 2]=$(( ${#items[@]} + 1 ))

    printf '\e[H\e[2J'
    printf '%s\n' "${top[@]}" "${middle[@]}" "${bottom[@]}"
}

menu_help() {
    local redraw=1
    while true; do
        if (( redraw )); then
            term_size
            printf '\e[H\e[2J'
            cat <<HELP
  ${C_BOLD}How to use this checklist${C_RESET}

  ↑ / ↓  (or k / j, Tab)   move between steps
  Enter or Space           select or unselect the highlighted step
  r                        select all recommended steps
  a                        select everything except the app removals
  n                        unselect everything
  q, Esc or Ctrl-D         quit without changing anything
  Mouse                    the wheel moves one step per notch; a click selects
                           (hold Shift to select text with the mouse)
HELP
            if (( TERM_ROWS >= 20 )); then
                cat <<HELP

  When you're ready, move to "▶ Continue" and press Enter. You'll see a
  summary of what will happen, including any data that gets deleted, and
  confirm once more.

  Steps that are already done, or don't apply to this computer, are listed
  at the top and don't need anything from you.
HELP
            fi
            printf '\n  Press any key to go back.\n'
        fi
        read_menu_key
        case $MENU_KEY in
            resize)         redraw=1 ;;
            wheel-*|"")     redraw=0 ;;
            *)              break ;;
        esac
    done
}

# Reads one key press from the terminal into MENU_KEY: a character, or a name for special
# keys (enter, up, down, home, end, esc, eof, resize) and mouse events (wheel-up,
# wheel-down, "click ROW"). Anything else becomes "", so stray sequences do nothing.
MENU_KEY=""
read_menu_key() {
    local c seq rc b y
    MENU_KEY=""
    while true; do
        rc=0
        IFS= read -rsn1 -t 0.5 c </dev/tty || rc=$?
        (( rc > 128 )) || break
        # Nothing typed for a while: redraw if the window was resized meanwhile.
        if [[ $(stty size </dev/tty 2>/dev/null) != "$TERM_SIZE" ]]; then
            MENU_KEY=resize
            return 0
        fi
    done
    if (( rc != 0 )) || [[ $c == $'\x04' ]]; then
        MENU_KEY=eof
        return 0
    fi
    case $c in
        ""|" ") MENU_KEY=enter ;;
        $'\t') MENU_KEY=down ;;
        $'\e') ;;
        *) MENU_KEY=$c ;;
    esac
    [[ $c == $'\e' ]] || return 0
    # Escape sequence. Wait a little so slow connections aren't read as a lone Esc.
    if ! IFS= read -rsn1 -t 0.5 c </dev/tty; then
        MENU_KEY=esc
        return 0
    fi
    if [[ $c != "[" && $c != O ]]; then
        MENU_KEY=esc   # Esc pressed twice, or Esc and then another key quickly
        return 0
    fi
    seq=$c
    # Read up to the final character (@ to ~); the length cap stops runaway input.
    while (( ${#seq} < 24 )) && IFS= read -rsn1 -t 0.3 c </dev/tty; do
        seq+=$c
        [[ ${#seq} -gt 1 && $c == [@-~] ]] && break
    done
    case $seq in
        '[A'|OA|'[1;'[0-9]A) MENU_KEY=up ;;
        '[B'|OB|'[1;'[0-9]B) MENU_KEY=down ;;
        '[H'|OH|'[1~'|'[7~'|'[5~') MENU_KEY=home ;;
        '[F'|OF|'[4~'|'[8~'|'[6~') MENU_KEY=end ;;
        '[<'*M)
            # SGR mouse press: ESC [ < button ; column ; row M
            seq=${seq:2:${#seq}-3}
            b=${seq%%;*} y=${seq##*;}
            [[ $b =~ ^[0-9]{1,3}$ && $y =~ ^[0-9]{1,4}$ ]] || return 0
            case $(( 10#$b & ~28 )) in   # drop the Shift/Alt/Ctrl bits
                64) MENU_KEY=wheel-up ;;
                65) MENU_KEY=wheel-down ;;
                0)  MENU_KEY="click $(( 10#$y ))" ;;
            esac ;;
        '[M')
            # Old-style mouse report from terminals without SGR mode: three raw bytes.
            # Read them so they aren't taken as key presses.
            IFS= read -rsn3 -t 0.3 c </dev/tty || return 0
            printf -v b '%d' "'${c:0:1}"
            case $(( (b - 32) & ~28 )) in
                64) MENU_KEY=wheel-up ;;
                65) MENU_KEY=wheel-down ;;
            esac ;;
    esac
    return 0
}

MENU_ACTIVE=0 MENU_STTY="" TERM_SIZE="" TITLE_SET=0 MENU_START=0
MENU_ROW_ITEM=()

enter_menu() {
    MENU_ACTIVE=1
    # No echo between key reads, so keys pressed during a redraw don't show up as ^[[B.
    MENU_STTY=$(stty -g </dev/tty 2>/dev/null || true)
    stty -echo -icanon </dev/tty 2>/dev/null || true
    # Alternate screen (like less/htop), so the menu doesn't fill the scrollback; hidden
    # cursor; no line wrapping, so long lines are cut instead of pushing the screen up.
    # Mouse reporting makes the terminal send one event per wheel notch instead of several
    # arrow keys, so the wheel moves exactly one step.
    printf '\e[?1049h\e[?25l\e[?7l\e[?1000h\e[?1006h' >/dev/tty
}

leave_menu() {
    local junk
    MENU_ACTIVE=0
    printf '\e[?1006l\e[?1000l\e[?7h\e[?25h\e[?1049l' 2>/dev/null >/dev/tty || true
    # Drop mouse events or keys still on their way, so they don't reach the shell.
    while IFS= read -rs -t 0.05 -n 1 junk </dev/tty 2>/dev/null; do :; done
    if [[ -n $MENU_STTY ]]; then
        stty "$MENU_STTY" </dev/tty 2>/dev/null || true
    fi
}

choose_steps_menu() {
    local -a items
    mapfile -t items < <(menu_items)
    if (( ${#items[@]} == 0 )); then
        print_overview
        printf '\n  %sEverything that applies to this computer is already done.%s\n' "$C_GREEN" "$C_RESET"
        printf '  To redo a step anyway, run the setup again with: --only <step> --force   (see --list-steps)\n'
        exit 0
    fi
    local cur=0 n=$(( ${#items[@]} + 2 )) msg="" id row
    # Smart default: everything recommended that isn't done yet starts selected.
    for id in "${items[@]}"; do
        if [[ ${STEP_TAG[$id]} == recommended ]] && wants_doing "$id"; then
            select_step "$id"
        fi
    done
    resolve_dependencies
    enter_menu
    while true; do
        draw_menu "$cur" "$msg" "${items[@]}" >/dev/tty
        msg=""
        read_menu_key
        case $MENU_KEY in
            up|k|K)
                cur=$(( (cur - 1 + n) % n )) ;;
            down|j|J)
                cur=$(( (cur + 1) % n )) ;;
            # The wheel stops at the ends instead of wrapping around.
            wheel-up)
                (( cur > 0 )) && cur=$(( cur - 1 )) ;;
            wheel-down)
                (( cur < n - 1 )) && cur=$(( cur + 1 )) ;;
            home)
                cur=0 ;;
            end)
                cur=${#items[@]} ;;
            "click "*)
                row=${MENU_KEY#click }
                if [[ -n ${MENU_ROW_ITEM[row]:-} ]]; then
                    cur=${MENU_ROW_ITEM[row]}
                    MENU_KEY=enter
                fi ;;
            a|A) for id in "${items[@]}"; do wants_doing "$id" && select_step "$id"; done ;;
            r|R) for id in "${items[@]}"; do
                     [[ ${STEP_TAG[$id]} == recommended ]] && wants_doing "$id" && select_step "$id"
                 done ;;
            n|N) SELECTED=() AUTO_SELECTED=() ;;
            '?') menu_help >/dev/tty ;;
        esac
        if [[ $MENU_KEY == enter ]]; then
            if (( cur < ${#items[@]} )); then
                id=${items[cur]}
                if [[ -n ${AUTO_SELECTED[$id]:-} ]]; then
                    msg="The system update is needed by the drivers step; unselect the drivers first."
                elif [[ -n ${SELECTED[$id]:-} ]]; then
                    unset "SELECTED[$id]"
                else
                    select_step "$id"
                fi
            elif (( cur == ${#items[@]} )); then
                if [[ -n $(selected_steps) ]]; then
                    break
                fi
                msg="Select at least one step first: move to it and press Enter or Space."
            else
                MENU_KEY=q
            fi
        fi
        # q, Esc and Ctrl-D all quit.
        if [[ $MENU_KEY == q || $MENU_KEY == Q || $MENU_KEY == esc || $MENU_KEY == eof ]]; then
            leave_menu
            printf '\nNothing was changed.\n'
            exit 0
        fi
        resolve_dependencies
    done
    leave_menu
}

print_step_list() {
    init_steps
    local id group
    printf 'Steps (use the IDs with --only and --skip):\n'
    for group in "${STEP_GROUPS[@]}"; do
        printf '\n  %s\n' "${GROUP_TITLE[$group]}"
        for id in "${ALL_STEPS[@]}"; do
            [[ ${STEP_TAG[$id]} == "$group" ]] || continue
            printf '    %-12s %s\n    %-12s %s\n' "$id" "${STEP_TITLE[$id]}" "" "${STEP_WHY[$id]}"
        done
    done
    printf '\n--all selects every step that applies and isn'"'"'t done yet, except the app removals.\n'
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
            if [[ ${STEP_TAG[$id]} == remove ]]; then
                continue   # never implied: removals delete data
            elif wants_doing "$id" || (( FORCE )); then
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

choose_steps() {
    if (( ${#ONLY_STEPS[@]} || SELECT_ALL )); then
        select_from_flags
    elif (( ASSUME_YES )); then
        die "Choose steps with --only ... or --all (see --list-steps). Nothing was changed."
    elif have_tty && [[ ${TERM:-} != dumb ]]; then
        choose_steps_menu
    elif have_tty && (( ! DRY_RUN )); then
        die "This terminal (TERM=dumb) can't show the checklist. Choose steps with --only ... or --all (see --list-steps)."
    elif (( DRY_RUN )); then
        info "No terminal for the checklist: previewing every step that isn't done yet (except app removals)"
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

# --- Review screen -------------------------------------------------------------

# Works out, before anything runs, what removing KDE PIM / LibreOffice would also take with
# it and which of the user's files it deletes. Unselects a removal that can't be done safely.
plan_removals() {
    local kind regex label out n names=() hits=() apps=() files path size
    local -a junk matches existing
    local -A installed=()
    while IFS= read -r n; do installed[$n]=1; done < <(rpm -qa --qf '%{NAME}\n' 2>/dev/null || true)
    for kind in pim libreoffice; do
        [[ -n ${SELECTED[$kind]:-} ]] || continue
        if [[ $kind == pim ]]; then
            regex=$PIM_REGEX label="KDE PIM" junk=("${PIM_JUNK[@]}")
        else
            regex=$OFFICE_REGEX label=LibreOffice junk=("${OFFICE_JUNK[@]}")
        fi
        local -a pkgs
        mapfile -t pkgs < <(installed_matching "$regex")
        if (( ${#pkgs[@]} )); then
            out=$(LC_ALL=C "$DNF" remove "${pkgs[@]}" --assumeno 2>&1 || true)
            if [[ $out != *"Transaction Summary"* && $out != *"Operation aborted"* ]]; then
                unset "SELECTED[$kind]"
                warn "Removing $label isn't possible right now (dnf: $(tail -n 2 <<<"$out" | tr '\n' ' ')); unselected it"
                continue
            fi
            hits=() apps=()
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
                unset "SELECTED[$kind]"
                warn "Removing $label would also remove core desktop parts (${hits[*]}); unselected it"
                continue
            fi
            if (( ${#apps[@]} )) && (( ASSUME_YES )); then
                unset "SELECTED[$kind]"
                warn "Removing $label would also remove ${apps[*]}; unselected it (--yes never removes extra apps)"
                continue
            fi
            REMOVAL_APPS[$kind]=${apps[*]}
        fi
        existing=()
        if [[ -n $TARGET_HOME ]]; then
            for path in "${junk[@]}"; do
                # shellcheck disable=SC2206
                matches=("$TARGET_HOME"/$path)
                for n in "${matches[@]}"; do
                    [[ -e $n || -L $n ]] && existing+=("$n")
                done
            done
        fi
        if (( ${#existing[@]} )); then
            size=$(du -sch -- "${existing[@]}" 2>/dev/null | tail -n1 | cut -f1 || true)
            REMOVAL_DATA[$kind]="${#existing[@]} item(s), ${size:-?} in your home folder"
        else
            REMOVAL_DATA[$kind]="nothing"
        fi
    done
}

# True if the user has real mail or contacts that the KDE PIM removal would delete.
has_real_pim_data() {
    [[ -n $TARGET_HOME ]] || return 1
    local dir
    for dir in "$TARGET_HOME/.local/share/local-mail" "$TARGET_HOME/.local/share/contacts"; do
        if [[ -d $dir && -n $(find "$dir" -type f -print -quit 2>/dev/null) ]]; then
            return 0
        fi
    done
    return 1
}

confirm_selection() {
    local id i=0 lo hi min=0 max=0 n reboot=0 note
    local -a ids
    plan_removals
    resolve_dependencies
    mapfile -t ids < <(selected_steps)
    if (( ${#ids[@]} == 0 )); then
        printf '\nNothing left to do. Nothing was changed.\n'
        exit 0
    fi
    for id in "${ids[@]}"; do
        read -r lo hi <<<"${STEP_MINUTES[$id]}"
        min=$((min + lo)) max=$((max + hi))
        case $id in update|drivers|firmware) reboot=1 ;; esac
    done
    n=${#ids[@]}
    printf '\n  %sReady to start %d step%s%s' "$C_BOLD" "$n" "$( ((n == 1)) || echo s)" "$C_RESET"
    if (( max > 1 )); then printf ' (usually about %d-%d minutes in total)' "$((min > 0 ? min : 1))" "$max"; fi
    printf ':\n\n'
    for id in "${ids[@]}"; do
        i=$((i + 1))
        note=""
        [[ -n ${AUTO_SELECTED[$id]:-} ]] && note="needed by the drivers"
        if [[ $id == drivers ]] && (( DRIVERS_NEED_KMOD && SECURE_BOOT )); then
            note="Secure Boot: you'll set a one-time password right after this screen"
        fi
        printf '   %d. %-44s %s%s%s\n' "$i" "${STEP_TITLE[$id]}" "$C_DIM" "$note" "$C_RESET"
        if [[ $id == pim || $id == libreoffice ]]; then
            printf '      %s! deletes: %s%s\n' "$C_RED" "${REMOVAL_DATA[$id]:-nothing}" "$C_RESET"
            if [[ -n ${REMOVAL_APPS[$id]:-} ]]; then
                printf '      %s! also removes these apps, which use its libraries: %s%s\n' "$C_RED" "${REMOVAL_APPS[$id]}" "$C_RESET"
            fi
        fi
    done
    printf '\n'
    if (( IS_LAPTOP )); then
        printf '  Keep the laptop plugged in until it finishes.\n'
    fi
    if (( reboot )); then
        printf '  A reboot will probably be needed at the end.\n'
    fi
    if (( DRY_RUN )); then
        info "Dry run: commands below are printed, not executed."
        return 0
    fi
    if (( ! ASSUME_YES )); then
        have_tty || die "No terminal to confirm on; re-run with --yes"
        ask_yes_no "Start these $n step$( ((n == 1)) || echo s) now? [y/N]" n || { printf 'Nothing was changed.\n'; exit 0; }
        if [[ -n ${SELECTED[pim]:-} ]] && has_real_pim_data; then
            printf '\n  %sYou have mail or contacts in %s/.local/share that will be deleted for good.%s\n' \
                "$C_BOLD$C_RED" "$TARGET_HOME" "$C_RESET"
            local typed=""
            flush_input
            ask_print '  Type %sdelete%s to confirm, or press Enter to keep them: ' "$C_BOLD" "$C_RESET"
            read -r typed </dev/tty || typed=""
            if [[ $typed != delete ]]; then
                unset 'SELECTED[pim]'
                printf '  OK, KDE PIM and its data are kept.\n'
                if [[ -z $(selected_steps) ]]; then
                    printf 'Nothing was changed.\n'
                    exit 0
                fi
            fi
        fi
    fi
}

# Questions that would otherwise interrupt a long run are asked before it starts.
ask_questions_up_front() {
    MOK_READY=-1
    if [[ -n ${SELECTED[drivers]:-} ]] && (( DRIVERS_NEED_KMOD && SECURE_BOOT )) && [[ $VIRT == none ]]; then
        section "Secure Boot key (before the long part)"
        if setup_secure_boot_signing; then MOK_READY=1; else MOK_READY=0; fi
    fi
}

# --- Progress ----------------------------------------------------------------

STEP_TOTAL=0 STEP_INDEX=0 CURRENT_STEP="" RUN_STARTED=0 FINISHED=0

elapsed_text() {  # $1 = seconds
    if (( $1 < 60 )); then printf '%d s' "$1"; else printf '%d min' $(( ($1 + 30) / 60 )); fi
}

progress_bar() {  # $1 = percent; prints the bar
    local pct=$1 width=24 fill bar="" j
    fill=$(( pct * width / 100 ))
    for (( j = 0; j < width; j++ )); do
        if (( j < fill )); then bar+="█"; else bar+="░"; fi
    done
    printf '[%s] %3d%%' "$bar" "$pct"
}

step_header() {  # $1 = index, $2 = total, $3 = percent, $4 = step
    local i=$1 n=$2 pct=$3 id=$4 text
    text="Step $i of $n · ${STEP_TITLE[$id]} · $(time_text "$id")"
    if (( TTY_OUT )); then
        printf '\n%s━━ %s ━━%s\n' "$C_BOLD$C_BLUE" "$text" "$C_RESET"
        printf '%s%s%s\n' "$C_GREEN" "$(progress_bar "$pct")" "$C_RESET"
        printf '\e]0;fedora-kde-setup · Step %d/%d · %d%%\a' "$i" "$n" "$pct" 2>/dev/null >/dev/tty || true
        TITLE_SET=1
    else
        printf '\n== %s (%d%%) ==\n' "$text" "$pct"
    fi
}

run_steps() {
    local -a ids
    local id total=0 done_weight=0 i=0 started
    mapfile -t ids < <(selected_steps)
    STEP_TOTAL=${#ids[@]}
    for id in "${ids[@]}"; do
        total=$((total + STEP_WEIGHT[$id]))
    done
    RUN_STARTED=1
    if selection_touches_packages; then
        prepare_packages
    fi
    ask_questions_up_front
    for id in "${ids[@]}"; do
        i=$((i + 1))
        STEP_INDEX=$i CURRENT_STEP=$id
        step_header "$i" "$STEP_TOTAL" $(( total ? done_weight * 100 / total : 0 )) "$id"
        started=$SECONDS
        STEP_OK=1
        "step_$id"
        if (( STEP_OK )); then
            RAN_STEPS+=("${STEP_TITLE[$id]}")
            record_step "$id"
            printf '  %s✔ Step %d of %d done%s (%s)\n' "$C_GREEN$C_BOLD" "$i" "$STEP_TOTAL" "$C_RESET" "$(elapsed_text $((SECONDS - started)))"
        else
            FAILED_STEPS+=("${STEP_TITLE[$id]}")
            printf '  %s✘ Step %d of %d not completed%s (%s); see the warnings above\n' "$C_YELLOW$C_BOLD" "$i" "$STEP_TOTAL" "$C_RESET" "$(elapsed_text $((SECONDS - started)))"
        fi
        done_weight=$((done_weight + STEP_WEIGHT[$id]))
    done
    CURRENT_STEP=""
}

# Printed when the script stops early (an error or Ctrl-C) after steps started.
print_stop_summary() {
    local title finished=""
    printf '\n%sThe script stopped' "$C_BOLD$C_RED" >&2
    if [[ -n $CURRENT_STEP ]]; then
        printf ' during step %d of %d (%s)' "$STEP_INDEX" "$STEP_TOTAL" "${STEP_TITLE[$CURRENT_STEP]}" >&2
    fi
    printf '.%s\n' "$C_RESET" >&2
    for title in "${RAN_STEPS[@]}"; do finished+="${finished:+, }$title"; done
    printf '  Finished before that: %s\n' "${finished:-nothing}" >&2
    printf '  Running the script again is safe: it shows what is done and skips it.\n' >&2
    printf '  Details are in the log: %s\n' "$LOG" >&2
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
    if [[ $3 == min && $current =~ ^[0-9]+$ ]] && (( 10#$current >= value )); then
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
        add_reboot_reason "to start the new kernel"
    elif [[ $(last_transaction_id) != "$history_before" ]]; then
        add_reboot_reason "so updated system services and libraries are used"
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
        [[ -n $WORK_DIR ]] || WORK_DIR=$(mktemp -d "$ROOT/tmp/fedora-kde-setup.XXXXXX")
    fi

    local key file out keyring files=()
    for repo in "${repos[@]}"; do
        key=$keydir/RPM-GPG-KEY-rpmfusion-$repo-fedora-$release
        file=$WORK_DIR/rpmfusion-$repo-release.noarch.rpm
        keyring=$WORK_DIR/keyring-$repo
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
        # Check the signature against RPM Fusion's key alone, in a keyring of its own: the
        # system keyring also trusts every other key ever imported (COPRs, Google, ...).
        local -a own_keyring=(--dbpath "$keyring" --define "_keyringpath $keyring/pubkeys/")
        if ! { install -d -m 0700 "$keyring" && rpmdb "${own_keyring[@]}" --initdb \
               && rpmkeys "${own_keyring[@]}" --import "$key"; } &>/dev/null; then
            warn "Couldn't set up a keyring to verify the RPM Fusion $repo release package"
            return 1
        fi
        if ! out=$(rpmkeys "${own_keyring[@]}" --checksig -- "$file" 2>&1) || [[ $out != "$file: digests signatures OK" ]]; then
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
        ok "Codecs: ffmpeg, GStreamer bad/ugly/libav, LAME"
    else
        STEP_OK=0
    fi
    # OpenH264 comes from Cisco's own server, which is sometimes unreachable.
    if (( DRY_RUN )) || is_installed gstreamer1-plugin-openh264; then
        ok "OpenH264 (H.264 video in Firefox and GStreamer)"
    else
        warn "OpenH264 couldn't be installed (Cisco's download server may be down); run the codecs step again later"
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
            rm -f -- "$MOK_PASSWORD_FILE"   # its one-time password isn't needed any more
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
        # mokutil doesn't flush its prompts, so talk to the terminal directly. Drop keys
        # typed while packages installed, or they'd become (empty) passwords.
        flush_input
        until mokutil --import "$MOK_CERT" </dev/tty >/dev/tty 2>&1; do
            tries=$((tries + 1))
            if (( tries >= 3 )); then
                warn "MOK import failed 3 times"
                return 1
            fi
            warn "Passwords didn't match or import failed, try again"
            flush_input
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
        # The password itself goes only to the terminal (in finish), never into the log.
        warn "A one-time MOK password was created and saved in $MOK_PASSWORD_FILE; you'll need it on the next boot"
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
    add_reboot_reason "to load the new drivers"
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
        if (( ${MOK_READY:--1} == 1 )); then
            :
        elif (( ${MOK_READY:--1} == 0 )) || ! setup_secure_boot_signing; then
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
            add_reboot_reason "to load the new drivers"
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
    local kind=libreoffice app approved
    [[ $label == "KDE PIM" ]] && kind=pim
    approved=" ${REMOVAL_APPS[$kind]:-} "
    for app in "${apps[@]}"; do
        if [[ $approved != *" $app "* ]]; then
            warn "Skipped removing $label: it would now also remove $app, which wasn't on the review screen. To remove it anyway: sudo dnf remove ${pkgs[*]}"
            return 1
        fi
    done

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
    local default_set=0
    if [[ -z $TARGET_HOME ]]; then
        warn "Couldn't tell whose Discover to set up (run the script with sudo from your account, or --user NAME); pick Flathub in Discover > Settings"
    elif ! command -v kwriteconfig6 &>/dev/null; then
        warn "Couldn't make Flathub Discover's default source (kwriteconfig6 not found); pick it in Discover > Settings"
    elif run_as_user kwriteconfig6 --file "$TARGET_HOME/.config/discoverrc" --group ResourcesModel \
            --key currentApplicationBackend flatpak-backend; then
        default_set=1
    else
        warn "Couldn't make Flathub Discover's default source; pick it in Discover > Settings"
    fi
    if (( default_set )); then
        ok "Flathub enabled, unfiltered, and Discover's default source"
    else
        ok "Flathub enabled and unfiltered"
    fi
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
           add_reboot_reason "to apply the firmware updates" ;;
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
    local n_run=${#RAN_STEPS[@]} n_failed=${#FAILED_STEPS[@]} item verdict color
    FINISHED=1
    if (( n_failed == 0 )); then
        color=$C_GREEN verdict="All $n_run step$( ((n_run == 1)) || echo s) finished."
    else
        color=$C_YELLOW verdict="$n_run of $((n_run + n_failed)) steps finished; $n_failed need$( ((n_failed != 1)) || echo s) attention (see below)."
    fi
    if (( TTY_OUT )); then
        printf '\n%s━━ %s ━━%s\n%s%s%s\n' "$C_BOLD$color" "$verdict" "$C_RESET" "$color" "$(progress_bar 100)" "$C_RESET"
        printf '\e]0;fedora-kde-setup: done\a' 2>/dev/null >/dev/tty || true
    else
        printf '\n== %s ==\n' "$verdict"
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
            password_hint="the one-time password saved in $MOK_PASSWORD_FILE (show it: sudo cat $MOK_PASSWORD_FILE)"
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
        if [[ -n $MOK_GENERATED_PASSWORD ]]; then
            printf '  %sYour one-time password: %s%s  (shown only here, not in the log)\n' \
                "$C_BOLD" "$MOK_GENERATED_PASSWORD" "$C_RESET" 2>/dev/null >/dev/tty || true
        fi
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
        printf 'Save your work in other apps first.\n'
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
    # Started without sudo from a terminal: ask for it instead of failing.
    if (( EUID != 0 && ! DRY_RUN )) && [[ -f $0 && -r $0 ]] && command -v sudo &>/dev/null && have_tty; then
        printf 'The setup needs administrator rights: enter your password if asked (nothing shows while you type).\n'
        exec sudo bash -- "$0" "$@"
    fi
    setup_logging "$@"
    preflight
    detect_system
    init_steps
    refine_steps
    compute_status
    if (( STATUS_ONLY )); then
        draw_steps
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
