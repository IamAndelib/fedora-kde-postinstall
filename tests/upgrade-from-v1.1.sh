#!/usr/bin/env bash
# Upgrade test: a system set up with the published v1.1.0 script, then the current script.
# Runs for real inside a disposable Fedora container. Never run it on a machine you care about.
#
#   podman run --rm -v "$PWD:/src:Z" -w /src registry.fedoraproject.org/fedora:44 \
#       bash tests/upgrade-from-v1.1.sh

set -Eeuo pipefail

readonly SCRIPT=${1:-./fedora-kde-setup.sh}
readonly OLD_URL=https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/v1.1.0/fedora-kde-setup.sh
readonly TEST_USER=tester
readonly STATE=/var/lib/fedora-kde-setup/done

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
check() {
    local what=$1
    shift
    if "$@" &>/dev/null; then pass "$what"; else fail "$what"; fi
}
check_not() {
    local what=$1
    shift
    if "$@" &>/dev/null; then fail "$what"; else pass "$what"; fi
}
status_has() {  # $1 = step title, $2 = text its --status line must contain
    grep -F "$1" /tmp/status.log | head -n1 | grep -qF "$2"
}

[[ $EUID -eq 0 ]] || { echo "Run as root inside a disposable Fedora container or VM." >&2; exit 2; }
grep -q '^ID=fedora' /etc/os-release || { echo "Not Fedora." >&2; exit 2; }

echo "==> Building a minimal Fedora KDE system with KDE PIM and LibreOffice"
dnf5 -y install --setopt=install_weak_deps=False \
    plasma-workspace dolphin konsole kmail kontact korganizer akonadi-server kdepim-runtime \
    libreoffice-writer libreoffice-calc ffmpeg-free flatpak \
    curl findutils procps-ng util-linux sudo gawk sed
id "$TEST_USER" &>/dev/null || useradd -m "$TEST_USER"
home=$(getent passwd "$TEST_USER" | cut -d: -f6)
sudo -u "$TEST_USER" mkdir -p "$home/.local/share/local-mail/cur" "$home/Documents" "$home/.config"
sudo -u "$TEST_USER" touch "$home/.config/keepme" "$home/Documents/report.odt"

echo "==> Step 1: the published v1.1.0 script, everything"
curl -fsSL -o /tmp/old-setup.sh "$OLD_URL"
check "downloaded v1.1.0"                       test -s /tmp/old-setup.sh
if bash /tmp/old-setup.sh --yes --no-reboot --user "$TEST_USER" > /tmp/old.log 2>&1; then
    pass "v1.1.0 run exits 0"
else
    tail -n 40 /tmp/old.log
    fail "v1.1.0 run exits 0"
fi
check "v1.1.0 wrote its one-line marker"        bash -c "[[ \$(wc -l < $STATE) == 1 ]] && ! grep -q '^dnf ' $STATE"
check_not "v1.1.0 removed LibreOffice"          bash -c "rpm -qa --qf '%{NAME}\n' | grep -E '^libreoffice'"
check_not "v1.1.0 removed KMail"                rpm -q kmail
check_not "user's KDE PIM data gone"            test -e "$home/.local/share/local-mail"

echo "==> Step 2: the new script shows what's already done (--status)"
if bash "$SCRIPT" --status --user "$TEST_USER" > /tmp/status.log 2>&1; then
    pass "--status exits 0"
else
    cat /tmp/status.log
    fail "--status exits 0"
fi
cat /tmp/status.log
check "DNF tweaks shown as done"                status_has 'Faster DNF downloads' '✔'
check "codecs shown as done"                    status_has 'Media codecs' '✔'
check "KDE PIM shown as already removed"        status_has 'KDE PIM' 'already removed'
check "LibreOffice shown as already removed"    status_has 'LibreOffice' 'already removed'
check "maintenance shown as done"               status_has 'SSD trim' '✔'
check "Flathub shown as partly done (new Discover default)" \
                                                status_has 'Flathub' 'partly done' 
check "status changed nothing (old marker kept)" bash -c "[[ \$(wc -l < $STATE) == 1 ]]"

echo "==> Step 3: the new script with --all"
if bash "$SCRIPT" --yes --no-reboot --all --user "$TEST_USER" > /tmp/all.log 2>&1; then
    pass "--all exits 0"
else
    tail -n 40 /tmp/all.log
    fail "--all exits 0"
fi
cat /tmp/all.log
check "done steps skipped"                      grep -q '(already done)' /tmp/all.log
check "Flathub step ran"                        grep -q "Flathub as Discover's app store" /tmp/all.log
check_not "nothing removed again"               grep -q 'dnf5 remove -y' /tmp/all.log
check_not "no user data deleted again"          grep -q 'rm -rf -- /home' /tmp/all.log
check_not "RPM Fusion not re-installed"         grep -q 'rpmkeys --checksig' /tmp/all.log
if command -v kwriteconfig6 &>/dev/null; then
    check "Flathub is now Discover's default"   grep -qx 'currentApplicationBackend=flatpak-backend' "$home/.config/discoverrc"
fi
check "dnf.conf untouched (no duplicates)"      bash -c "[[ \$(grep -c '^fastestmirror=' /etc/dnf/dnf.conf) == 1 ]]"
check "state converted to per-step lines"       grep -q '^flathub ' "$STATE"
check "user files kept"                         test -e "$home/Documents/report.odt"
check "unrelated config kept"                   test -e "$home/.config/keepme"

echo "==> Step 4: running the new script again"
if bash "$SCRIPT" --yes --no-reboot --all --user "$TEST_USER" > /tmp/again.log 2>&1; then
    pass "re-run exits 0"
else
    tail -n 30 /tmp/again.log
    fail "re-run exits 0"
fi
check_not "re-run changes no packages"          grep -Eq 'dnf5 (remove|swap|install) -y' /tmp/again.log

echo
if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"
