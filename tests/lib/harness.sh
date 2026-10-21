# shellcheck shell=bash
# Scenario runner core: environment probing, invoking the script in a sandbox,
# snapshots and assertions. Sourced by tests/run.sh.
# Variables set here (H, EXPECT_*, PTY_INPUT, ...) are read by the scenarios.
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Environment

FKS_LIB=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
readonly FKS_LIB
BASH_BIN=$BASH
ENV_BIN=$(command -v env)
SETSID_BIN=$(command -v setsid || true)
SCRIPT_BIN=$(command -v script || true)
UNSHARE_BIN=$(command -v unshare || true)
SETPRIV_BIN=$(command -v setpriv || true)
STTY_BIN=$(command -v stty || true)
TIMEOUT_BIN=$(command -v timeout || true)
readonly BASH_BIN ENV_BIN SETSID_BIN SCRIPT_BIN UNSHARE_BIN SETPRIV_BIN STTY_BIN TIMEOUT_BIN
# A run that waits for input nobody sends must not hang the suite.
readonly RUN_TIMEOUT=${FKS_RUN_TIMEOUT:-180}
readonly MOK_CERT_PATH=/etc/pki/akmods/certs/public_key.der

ROOTCMD=()          # prefix that gives root: () when already root, (sudo -n) otherwise
CAN_ROOT=0          # root, isolated from the host's /var/log
declare -A SKIP_WHY=()   # mode name -> reason it is unavailable

probe_environment() {
    [[ -n $SETSID_BIN ]] || { echo "setsid (util-linux) is required" >&2; exit 2; }

    if (( EUID == 0 )); then
        ROOTCMD=()
    elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
        ROOTCMD=(sudo -n)
    else
        SKIP_WHY[live]="not root and no passwordless sudo"
    fi
    if [[ -z ${SKIP_WHY[live]:-} ]]; then
        if [[ -n $UNSHARE_BIN ]] && "${ROOTCMD[@]}" "$UNSHARE_BIN" --mount --propagation private -- true 2>/dev/null; then
            CAN_ROOT=1
        else
            SKIP_WHY[live]="cannot create a mount namespace to isolate /var/log"
        fi
    fi
    if (( !CAN_ROOT )); then
        SKIP_WHY[pty]=${SKIP_WHY[live]}
    elif [[ -z $SCRIPT_BIN ]]; then
        SKIP_WHY[pty]="util-linux 'script' not installed"
    fi
    if (( EUID == 0 )); then
        # shellcheck disable=SC2016  # $1/$2 belong to the inner bash
        if [[ -z $SETPRIV_BIN ]] || ! "$SETPRIV_BIN" --reuid=65534 --regid=65534 --clear-groups -- \
                "$BASH_BIN" -c '[[ -r $1 && -x $2 ]]' _ "$SCRIPT" "$FKS_LIB/stub" 2>/dev/null; then
            SKIP_WHY[user]="root, and user 'nobody' cannot read the script (or no setpriv)"
        fi
    fi
    if [[ -z $SCRIPT_BIN ]]; then
        SKIP_WHY[upty]="util-linux 'script' not installed"
    elif [[ -n ${SKIP_WHY[user]:-} ]]; then
        SKIP_WHY[upty]=${SKIP_WHY[user]}
    fi
    # As root a dry run also writes /var/log, so it needs the same isolation.
    if (( EUID == 0 && !CAN_ROOT )); then
        SKIP_WHY[dry]=${SKIP_WHY[live]}
    fi
    HOST_HAS_MOK_CERT=0
    [[ -e $MOK_CERT_PATH ]] && HOST_HAS_MOK_CERT=1
    return 0
}

mode_available() { [[ -z ${SKIP_WHY[$1]:-} ]]; }

# Paths on the host the script could write if a test hook failed.
host_state() {
    local p home
    local paths=(/etc/dnf /var/lib/fedora-kde-setup /var/log/fedora-kde-setup.log
        /etc/systemd/journald.conf.d /etc/pki/akmods /usr/lib64/libreoffice /usr/lib/libreoffice
        /usr/share/akonadi /etc/libreoffice /run/fedora-kde-setup.lock /system-update
        /root/fedora-kde-setup-mok-password.txt /root/.fedora-kde-setup-mok.hash)
    paths+=(/tmp/fedora-kde-setup*.log "${TMPDIR:-/tmp}"/fedora-kde-setup*.log)
    for home in "$HOME" ${SUDO_USER:+"$(getent passwd "$SUDO_USER" | cut -d: -f6)"}; do
        [[ -n $home ]] && paths+=("$home/.config" "$home/.local/share" "$home/.cache")
    done
    for p in "${paths[@]}"; do
        if [[ ! -e $p ]]; then
            printf '%s absent\n' "$p"
        elif [[ $p == */.config || $p == */.local/share || $p == */.cache ]]; then
            # Names only: other programs legitimately touch files in a real home.
            find "$p" -mindepth 1 -maxdepth 1 -printf '%p\n' 2>/dev/null | LC_ALL=C sort
        else
            find "$p" -printf '%p %y %s %m %T@\n' 2>/dev/null | LC_ALL=C sort
            find "$p" -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort
        fi
    done
}

# ---------------------------------------------------------------------------
# Per-scenario state

new_scenario_dirs() {  # $1 = scenario name
    # Neutral dir name: scenario names must not leak into paths that regexes see.
    T=$(mktemp -d "$WORK/run.XXXXXX")
    printf '%s\n' "$1" > "$T/SCENARIO"
    R=$T/root
    S=$T/state
    H="$T/home/tester home"
    CALLS=$T/calls.log
    OUT=$T/out.txt
    STUBDIR=$T/stubs
    MISSING=()
    RUN_ENV=(SUDO_USER=tester)
    PTY_INPUT=""
    EXPECT_REBOOT=0
    ALLOW_NOTFOUND=0
    EXPECT_ERRTRAP=0
    EXPECT_NO_LOG=0
    KEEP_ROOT_OWNER=0
    AUTO_ALL=1
    SCRIPT_UNDER_TEST=""
    PTY_ROWS=24 PTY_COLS=80
    LOCK_FD=""
    RC=""
    IS_DRY=0
    FAILS=()
    NCHECKS=0
    : > "$CALLS"
}

cleanup_dir() {  # $1 = dir; files made by root runs may need root to delete
    rm -rf -- "$1" 2>/dev/null || "${ROOTCMD[@]}" rm -rf -- "$1"
}

# As root, user/upty runs go through user "nobody", who must be able to use the whole
# scenario dir. Done before any snapshot too, so the mode change isn't seen as a change.
share_with_nobody() {
    if (( EUID == 0 )) && [[ $MODE == user || $MODE == upty ]]; then
        chmod -R a+rwX "$T"
    fi
}

tree_state() {  # DIR... -> listing + checksums, for "nothing changed" checks
    share_with_nobody
    # The script's own log (FKS_ROOT/var/log) is the one file a dry run may write.
    find "$@" -path "$R/var/log" -prune -o -printf '%p %y %m %l\n' 2>/dev/null | LC_ALL=C sort
    find "$@" -path "$R/var/log" -prune -o -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort
}

# Holds the script's lock file from the harness, like a concurrent run would.
hold_lock() {
    exec {LOCK_FD}>"$R/run/fedora-kde-setup.lock"
    flock -n "$LOCK_FD"
}
release_lock() {
    [[ -n ${LOCK_FD:-} ]] && exec {LOCK_FD}>&-
    LOCK_FD=""
}

# invoke [SCRIPT_ARGS...]: runs the script once in the current $MODE.
#   dry   --dry-run, as the harness user (as root: isolated like live)
#   live  as root in a private mount namespace, no controlling terminal
#   pty   like live, but on a pseudo-terminal fed with $PTY_INPUT
#   user  as an unprivileged user (the harness user, or nobody when root)
#   upty  like user, but on a pseudo-terminal fed with $PTY_INPUT
invoke() {
    local args=("$@") a
    # v1.2 runs nothing unless steps are chosen: scenarios that don't choose get --all.
    if (( AUTO_ALL )); then
        local chosen=0
        for a in "${args[@]}"; do
            case $a in --only|--only=*|--all|--status|--list-steps|-h|--help|-V|--version) chosen=1 ;; esac
        done
        (( chosen )) || args=(--all "${args[@]}")
    fi
    [[ $MODE == dry ]] && args=(--dry-run "${args[@]}")
    IS_DRY=0
    for a in "${args[@]}"; do [[ $a == -n || $a == --dry-run ]] && IS_DRY=1; done

    if [[ ! -d $STUBDIR ]]; then
        stubs_create "$STUBDIR" "$S/pool" "${MISSING[@]}"
    fi
    : > "$CALLS"

    local envv=(
        "PATH=$STUBDIR:$SAFEBIN" "FKS_ROOT=$R" "FKS_STATE=$S" "FKS_CALLS=$CALLS"
        "TMPDIR=$T/tmp" "HOME=$T/invoker-home" LANG=C "${RUN_ENV[@]}"
    )
    local cmd=("$ENV_BIN" -i "${envv[@]}" "$BASH_BIN" "${SCRIPT_UNDER_TEST:-$SCRIPT}" "${args[@]}")
    local guard=()
    [[ -n $TIMEOUT_BIN ]] && guard=("$TIMEOUT_BIN" -k 10 "$RUN_TIMEOUT")
    local isolate=("${guard[@]}" "${ROOTCMD[@]}" "$UNSHARE_BIN" --mount --propagation private -- \
        "$BASH_BIN" "$FKS_LIB/isolate.sh" "$T/hostlog")

    local before=""
    if (( IS_DRY )); then before=$(tree_state "$R" "$T/home" "$T/outside"); fi

    # As root the script accepts only a FKS_ROOT that is root-owned, like every parent
    # directory, and not writable by others (sticky dirs are fine). Under sudo the harness
    # user built the tree, so hand FKS_ROOT to root, and make the scenario dir and the work
    # dir root-owned sticky dirs like /tmp, which the harness user can still write into.
    if (( ${#ROOTCMD[@]} )) && [[ $MODE == live || $MODE == pty ]]; then
        "${ROOTCMD[@]}" chown 0:0 "$T" "$WORK"
        "${ROOTCMD[@]}" chmod 1777 "$T" "$WORK"
        if (( !KEEP_ROOT_OWNER )); then
            "${ROOTCMD[@]}" chown 0:0 "$R"
            "${ROOTCMD[@]}" chmod go-w "$R"
        fi
    fi

    case $MODE in
        dry)
            if (( EUID == 0 )); then
                ( cd "$T/cwd" && "${isolate[@]}" "$SETSID_BIN" -w "${cmd[@]}" ) </dev/null 2>&1 | cat > "$T/raw.txt"
            else
                ( cd "$T/cwd" && "${guard[@]}" "$SETSID_BIN" -w "${cmd[@]}" ) </dev/null 2>&1 | cat > "$T/raw.txt"
            fi
            RC=${PIPESTATUS[0]}
            ;;
        live)
            ( cd "$T/cwd" && "${isolate[@]}" "$SETSID_BIN" -w "${cmd[@]}" ) </dev/null 2>&1 | cat > "$T/raw.txt"
            RC=${PIPESTATUS[0]}
            ;;
        pty)
            local cmdline
            # A fixed terminal size, as stty reports it to the script's menu.
            cmdline="$(printf '%q ' "$STTY_BIN" rows "$PTY_ROWS" cols "$PTY_COLS"); $(printf '%q ' "${cmd[@]}")"
            feed_pty_input "$PTY_INPUT" \
                | ( cd "$T/cwd" && "${isolate[@]}" "$SCRIPT_BIN" -qec "$cmdline" /dev/null ) 2>&1 \
                | cat > "$T/raw.txt"
            RC=${PIPESTATUS[1]}
            ;;
        upty)
            local cmdline drop=()
            cmdline="$(printf '%q ' "$STTY_BIN" rows "$PTY_ROWS" cols "$PTY_COLS"); $(printf '%q ' "${cmd[@]}")"
            share_with_nobody
            if (( EUID == 0 )); then
                drop=("$SETPRIV_BIN" --reuid=65534 --regid=65534 --clear-groups --)
            fi
            feed_pty_input "$PTY_INPUT" \
                | ( cd "$T/cwd" && "${guard[@]}" "${drop[@]}" "$SCRIPT_BIN" -qec "$cmdline" /dev/null ) 2>&1 \
                | cat > "$T/raw.txt"
            RC=${PIPESTATUS[1]}
            ;;
        user)
            share_with_nobody
            if (( EUID == 0 )); then
                ( cd "$T/cwd" && "$SETPRIV_BIN" --reuid=65534 --regid=65534 --clear-groups -- \
                    "$SETSID_BIN" -w "${cmd[@]}" ) </dev/null 2>&1 | cat > "$T/raw.txt"
            else
                ( cd "$T/cwd" && "$SETSID_BIN" -w "${cmd[@]}" ) </dev/null 2>&1 | cat > "$T/raw.txt"
            fi
            RC=${PIPESTATUS[0]}
            ;;
    esac

    # Plain text: no escape sequences (colors, cursor, clear screen, window title), no
    # carriage returns from the pty.
    sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' "$T/raw.txt" > "$OUT"
    if (( IS_DRY )); then
        sed -n 's/^  \$ //p' "$OUT" > "$T/actions"
    else
        cp "$CALLS" "$T/actions"
    fi

    # Checks that apply to every run.
    if (( !ALLOW_NOTFOUND )); then
        expect_no_out 'command not found'
    fi
    if (( !EXPECT_ERRTRAP )); then
        expect_no_out 'this command failed \(exit code'
    fi
    check "run finished before the ${RUN_TIMEOUT}s timeout" test "$RC" -ne 124
    if (( !EXPECT_REBOOT )); then
        expect_no_call '^systemctl (reboot|poweroff|halt|kexec)'
    fi
    check "no temp work dir left behind" \
        test -z "$("${ROOTCMD[@]}" find "$T/tmp" "$R/tmp" -mindepth 1 -maxdepth 1 -type d -name 'fedora-kde-setup.*' 2>/dev/null)"
    if (( IS_DRY )); then
        check "dry run executed no state-changing command" no_mutating_calls
        check "dry run left fake root and homes unchanged" \
            test "$before" == "$(tree_state "$R" "$T/home" "$T/outside")"
    fi
    if [[ $MODE == live || $MODE == pty || ($MODE == dry && $EUID == 0) ]]; then
        # Root runs log to FKS_ROOT/var/log; the host's /var/log (bind-mounted to
        # $T/hostlog in the namespace) must stay empty.
        if (( !EXPECT_NO_LOG )); then
            check "root run logged to FKS_ROOT/var/log" test -s "$R/var/log/fedora-kde-setup.log"
        fi
        check "nothing written to the host's /var/log" test -z "$(ls -A "$T/hostlog")"
    fi
}

# Keys for the pty, printf %b style, with two kinds of markers:
#   |WAIT:ERE|  wait until the script's output matches ERE (e.g. a prompt) before sending
#               more; the script flushes typed-ahead input before each yes/no question
#   |PAUSE|     wait 2 s, so a key arrives while the script is already waiting for it
feed_pty_input() {
    local rest=$1 part marker re i
    while [[ $rest =~ \|(WAIT:[^|]*|PAUSE)\| ]]; do
        marker=${BASH_REMATCH[1]}
        part=${rest%%"|$marker|"*}
        rest=${rest#*"|$marker|"}
        printf '%b' "$part"
        if [[ $marker == PAUSE ]]; then
            sleep 2
        else
            re=${marker#WAIT:}
            for (( i = 0; i < 300; i++ )); do
                grep -aEq -- "$re" "$T/raw.txt" 2>/dev/null && break
                sleep 0.1
            done
            sleep 0.2
        fi
    done
    printf '%b' "$rest"
}

no_mutating_calls() {
    ! grep -v -- '--assumeno' "$CALLS" | grep -Eq \
        '^(dnf5?( -[^ ]+)* (install|remove|autoremove|swap|upgrade|mark|config-manager|group)|systemctl (enable|disable|start|stop|restart|reboot|mask|unmask)|flatpak remote-|fwupdmgr|kmodgenca|akmods|mokutil --(import|generate-hash)|openssl|pkcon|pkill|sudo|runuser|akonadictl|kbuildsycoca6|rpmkeys|curl .* -fsSL )'
}

# ---------------------------------------------------------------------------
# Assertions. Each records a failure message instead of stopping the scenario.

check() {  # DESCRIPTION COMMAND...
    NCHECKS=$((NCHECKS + 1))
    if ! "${@:2}"; then
        FAILS+=("$1")
    fi
    return 0
}

not() { ! "$@"; }
is_live() { (( !IS_DRY )); }

grep_q() { grep -Eq -- "$1" "$2"; }

expect_rc() {  # N | nonzero
    if [[ $1 == nonzero ]]; then
        check "exit code non-zero (got $RC)" test "$RC" -ne 0
    else
        check "exit code $1 (got $RC)" test "$RC" -eq "$1"
    fi
}
expect_out()       { check "output matches /$1/" grep_q "$1" "$OUT"; }
expect_no_out()    { check "output does not match /$1/" not grep_q "$1" "$OUT"; }
expect_action()    { check "action /$1/" grep_q "$1" "$T/actions"; }
expect_no_action() { check "no action /$1/" not grep_q "$1" "$T/actions"; }
expect_call()      { check "call /$1/" grep_q "$1" "$CALLS"; }
expect_no_call()   { check "no call /$1/" not grep_q "$1" "$CALLS"; }

# Package installs: "dnf5 install -y --skip-unavailable ... PKG ..." in either mode.
pkg_re() { local p=${1//./\\.}; printf '^dnf5? install .* %s( |$)' "${p//+/\\+}"; }
expect_install()    { expect_action "$(pkg_re "$1")"; }
expect_no_install() { expect_no_action "$(pkg_re "$1")"; }

first_line() {  # REGEX FILE -> line number of first match, or a huge number
    local n
    n=$(grep -En -- "$1" "$2" | head -n1 | cut -d: -f1)
    echo "${n:-999999}"
}
action_before() { (( $(first_line "$1" "$T/actions") < $(first_line "$2" "$T/actions") )); }
expect_order() {  # RE1 RE2: first RE1 action comes before first RE2 action
    check "action /$1/ comes before /$2/" action_before "$1" "$2"
}

# File tests run as root when the harness got root through sudo, so a path inside a
# root-only directory can't pass "absent" just because the harness can't see it.
rtest() { "${ROOTCMD[@]}" test "$@"; }
expect_file()    { check "file exists: ${1#"$T"/}" rtest -e "$1" -o -L "$1"; }
expect_no_file() { check "file absent: ${1#"$T"/}" not rtest -e "$1" -o -L "$1"; }
expect_grep()    { check "${1#"$T"/} matches /$2/" grep_q "$2" "$1"; }
expect_count() {  # FILE REGEX N
    local n
    n=$(grep -Ec -- "$2" "$1" 2>/dev/null || true)
    check "${1#"$T"/} has $3 line(s) matching /$2/ (found ${n:-0})" test "${n:-0}" -eq "$3"
}
expect_no_dnf() {
    check "no dnf/dnf5 call at all" not grep_q '^dnf5? ' "$CALLS"
}
