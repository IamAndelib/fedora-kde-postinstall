#!/usr/bin/env bash
# Scenario tests for fedora-kde-setup.sh.
#
#   bash tests/run.sh [options] [NAME_PATTERN...]
#   sudo bash tests/run.sh [options] [NAME_PATTERN...]
#
# Every scenario builds a fake system in a fresh temp dir (FKS_ROOT, stub state, fake
# homes) and runs the script with a PATH that holds only logging stubs and a few
# harmless real tools (see lib/stubs.sh), so it can't reach the real dnf, systemctl,
# mokutil or reboot. Modes:
#   dry   --dry-run (as the current user)
#   live  real code paths as root, in a private mount namespace, no terminal
#   pty   like live, on a pseudo-terminal with scripted answers
#   user  as an unprivileged user
#   upty  like user, on a pseudo-terminal
# live/pty need root or passwordless sudo, plus unshare; they are skipped otherwise.
#
# Options:
#   -m, --mode MODES   only run these modes (comma-separated: dry,live,pty,user,upty)
#   -l, --list         list scenarios and exit
#   -v, --verbose      print the script output of failing runs
#   -k, --keep         keep the temp dirs (path printed at the end)
#   -h, --help         show this help
# NAME_PATTERN is a bash glob matched against scenario names (e.g. 'nvidia*').
#
# Exit status: 0 if every run passed, 1 if any failed, 2 on usage/environment errors.

# shellcheck source-path=SCRIPTDIR
set -uo pipefail
umask 022
# The checks match UTF-8 text (✔, progress bars); a C locale would see bytes.
if locale -a 2>/dev/null | grep -Eqix 'c\.utf-?8'; then
    export LC_ALL=C.UTF-8
fi

HERE=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
SCRIPT=${FKS_SCRIPT:-$(cd "$HERE/.." && pwd)/fedora-kde-setup.sh}
readonly HERE SCRIPT

# shellcheck source=lib/stubs.sh
source "$HERE/lib/stubs.sh"
# shellcheck source=lib/harness.sh
source "$HERE/lib/harness.sh"
# shellcheck source=lib/fixture.sh
source "$HERE/lib/fixture.sh"

SCENARIOS=()
declare -A SC_MODES=() SC_DESC=()

# scenario NAME MODES DESCRIPTION; the checks live in function sc_NAME.
scenario() {
    SCENARIOS+=("$1")
    SC_MODES[$1]=$2
    SC_DESC[$1]=$3
}

# shellcheck source=scenarios.sh
source "$HERE/scenarios.sh"

usage() { sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

ONLY_MODES="" VERBOSE=0 KEEP=0 PATTERNS=()
while (( $# )); do
    case $1 in
        -m|--mode)    ONLY_MODES=${2:?--mode needs a value}; shift ;;
        -l|--list)    for s in "${SCENARIOS[@]}"; do printf '%-26s %-18s %s\n' "$s" "${SC_MODES[$s]}" "${SC_DESC[$s]}"; done; exit 0 ;;
        -v|--verbose) VERBOSE=1 ;;
        -k|--keep)    KEEP=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; exit 2 ;;
        *)            PATTERNS+=("$1") ;;
    esac
    shift
done

[[ -r $SCRIPT ]] || { echo "Script not found: $SCRIPT (set FKS_SCRIPT)" >&2; exit 2; }
command -v md5sum >/dev/null || { echo "md5sum is required" >&2; exit 2; }
unset container
probe_environment

# As root the script accepts FKS_ROOT only if it and every parent directory are root-owned
# and not writable by others (sticky dirs like /tmp are fine). A non-root harness therefore
# works under /tmp, not a $TMPDIR that may sit in its own (non-root) directory.
if (( EUID == 0 )); then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/fks-tests.XXXXXX")
else
    WORK=$(mktemp -d /tmp/fks-tests.XXXXXX)
fi
chmod 0755 "$WORK"
SAFEBIN=$WORK/safebin
safebin_create "$SAFEBIN" || exit 2
HOST_BEFORE=$(host_state)

# Self-check: under the scenario PATH, anything that could change the host is either
# missing or one of our stubs.
path_guard() {
    local dir=$WORK/guard cmd path bad=()
    stubs_create "$dir/stubs" "$dir/pool"
    for cmd in reboot shutdown poweroff halt systemctl dnf dnf5 yum rpm rpm-ostree mokutil \
            kmodgenca akmods fwupdmgr flatpak sudo su runuser pkill kill killall mount umount \
            useradd userdel chown dd mkfs curl wget id getent rpmkeys rpmdb; do
        path=$(PATH="$dir/stubs:$SAFEBIN" type -P "$cmd") || continue
        [[ $path == "$dir/stubs/$cmd" && $(readlink "$path") == "$FKS_LIB/stub" ]] || bad+=("$cmd=$path")
    done
    rm -rf -- "$dir"
    if (( ${#bad[@]} )); then
        ROWS+=("path-guard|all|FAIL|1|reachable real commands: ${bad[*]}")
        NFAIL=$((NFAIL + 1))
    else
        ROWS+=("path-guard|all|PASS|1|")
        NPASS=$((NPASS + 1))
    fi
}

selected() {  # NAME
    local p
    (( ${#PATTERNS[@]} )) || return 0
    for p in "${PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        [[ $1 == $p ]] && return 0
    done
    return 1
}

# The script and its launcher must be shellcheck-clean (skipped if shellcheck isn't installed).
script_shellcheck() {
    local out files=("$SCRIPT")
    [[ -f $HERE/../install.sh ]] && files+=("$HERE/../install.sh")
    if ! command -v shellcheck >/dev/null; then
        ROWS+=("script-shellcheck|all|SKIP|-|shellcheck not installed")
        NSKIP=$((NSKIP + 1))
    elif out=$(shellcheck "${files[@]}" 2>&1); then
        ROWS+=("script-shellcheck|all|PASS|${#files[@]}|")
        NPASS=$((NPASS + 1))
    else
        ROWS+=("script-shellcheck|all|FAIL|${#files[@]}|shellcheck reports issues")
        NFAIL=$((NFAIL + 1))
        DETAILS+=("--- script-shellcheck"$'\n'"    ${out//$'\n'/$'\n'    }")
    fi
}

ROWS=() DETAILS=() NPASS=0 NFAIL=0 NSKIP=0
path_guard
script_shellcheck
for name in "${SCENARIOS[@]}"; do
    selected "$name" || continue
    for MODE in ${SC_MODES[$name]}; do
        if [[ -n $ONLY_MODES && ,$ONLY_MODES, != *",$MODE,"* ]]; then
            continue
        fi
        if ! mode_available "$MODE"; then
            ROWS+=("$name|$MODE|SKIP|-|${SKIP_WHY[$MODE]}")
            NSKIP=$((NSKIP + 1))
            continue
        fi
        printf '.' >&2
        new_scenario_dirs "$name"
        fx_base
        "sc_${name//-/_}"
        if (( ${#FAILS[@]} == 0 )); then
            ROWS+=("$name|$MODE|PASS|$NCHECKS|")
            NPASS=$((NPASS + 1))
        else
            ROWS+=("$name|$MODE|FAIL|$NCHECKS|${#FAILS[@]} failed: ${FAILS[0]}")
            NFAIL=$((NFAIL + 1))
            detail="--- $name [$MODE] (exit $RC)"
            (( KEEP )) && detail+=" dir: $T"
            for f in "${FAILS[@]}"; do detail+=$'\n'"    x $f"; done
            if (( VERBOSE )); then
                detail+=$'\n'"    output:"$'\n'"$(sed 's/^/    | /' "$OUT")"
            fi
            DETAILS+=("$detail")
        fi
        (( KEEP )) || cleanup_dir "$T"
    done
done
printf '\n' >&2

HOST_AFTER=$(host_state)
if [[ $HOST_BEFORE == "$HOST_AFTER" ]]; then
    ROWS+=("host-untouched|all|PASS|1|")
    NPASS=$((NPASS + 1))
else
    ROWS+=("host-untouched|all|FAIL|1|host paths changed during the run")
    NFAIL=$((NFAIL + 1))
    DETAILS+=("--- host-untouched"$'\n'"$(diff <(echo "$HOST_BEFORE") <(echo "$HOST_AFTER") | sed 's/^/    /')")
fi

printf '\n%-26s %-5s %-6s %6s  %s\n' SCENARIO MODE RESULT CHECKS NOTE
printf '%s\n' "------------------------------------------------------------------------------------------"
for row in "${ROWS[@]}"; do
    IFS='|' read -r c1 c2 c3 c4 c5 <<< "$row"
    printf '%-26s %-5s %-6s %6s  %s\n' "$c1" "$c2" "$c3" "$c4" "$c5"
done
if (( ${#DETAILS[@]} )); then
    printf '\nFailures:\n'
    printf '%s\n' "${DETAILS[@]}"
fi
printf '\n%d passed, %d failed, %d skipped\n' "$NPASS" "$NFAIL" "$NSKIP"

if (( KEEP )); then
    printf 'Temp dirs kept in %s\n' "$WORK"
else
    cleanup_dir "$WORK"
fi
(( NFAIL == 0 ))
