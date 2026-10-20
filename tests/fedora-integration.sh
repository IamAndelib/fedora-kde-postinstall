#!/usr/bin/env bash
# Real-Fedora integration test: runs fedora-kde-setup.sh for real inside a Fedora
# container (or a throwaway VM) and checks the result. Never run it on a machine you care about.
#
#   podman run --rm -v "$PWD:/src:Z" -w /src registry.fedoraproject.org/fedora:44 \
#       bash tests/fedora-integration.sh
#
# Drivers, firmware and services are skipped inside containers; everything package-related
# (DNF tuning, RPM Fusion, codecs, PIM/LibreOffice removal, Flathub) runs against real repos.

set -Eeuo pipefail

readonly SCRIPT=${1:-./fedora-kde-setup.sh}
readonly TEST_USER=tester
readonly PIM_REGEX='^(kmail|kontact|korganizer|kaddressbook|akregator|kalarm|knotes|kjots|ktnef|merkuro|kdepim|grantlee-editor|mbox-importer|pim-data-exporter|pim-sieve-editor|akonadi)'

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
check() {  # $1 = description, rest = command
    local what=$1
    shift
    if "$@" &>/dev/null; then pass "$what"; else fail "$what"; fi
}
check_not() {
    local what=$1
    shift
    if "$@" &>/dev/null; then fail "$what"; else pass "$what"; fi
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
sudo -u "$TEST_USER" mkdir -p \
    "$home/.local/share/akonadi/db_data" "$home/.local/share/local-mail/cur" \
    "$home/.config/libreoffice/4/user" "$home/Documents"
sudo -u "$TEST_USER" touch "$home/.config/kmail2rc" "$home/.config/keepme" "$home/Documents/report.odt"

echo "==> Dry run"
bash "$SCRIPT" --dry-run --user "$TEST_USER" > /tmp/dry.log 2>&1 || { cat /tmp/dry.log; fail "dry run exits 0"; }
check "dry run changes nothing (no marker)" test ! -e /var/lib/fedora-kde-setup/done

echo "==> Real run"
if bash "$SCRIPT" --yes --no-reboot --user "$TEST_USER"; then pass "script exits 0"; else fail "script exits 0"; fi

echo "==> Checks"
check "dnf.conf: fastestmirror=True"         grep -qx 'fastestmirror=True' /etc/dnf/dnf.conf
check "dnf.conf: max_parallel_downloads=10"  grep -qx 'max_parallel_downloads=10' /etc/dnf/dnf.conf
check "dnf.conf: defaultyes=True"            grep -qx 'defaultyes=True' /etc/dnf/dnf.conf
check "RPM Fusion free installed"            rpm -q rpmfusion-free-release
check "RPM Fusion nonfree installed"         rpm -q rpmfusion-nonfree-release
check "openh264 repo enabled"                bash -c "dnf5 repolist --enabled | grep -q fedora-cisco-openh264"
check "full ffmpeg installed"                rpm -q ffmpeg
check_not "ffmpeg-free gone"                 rpm -q ffmpeg-free
check "gstreamer bad-freeworld"              rpm -q gstreamer1-plugins-bad-freeworld
check "gstreamer ugly"                       rpm -q gstreamer1-plugins-ugly
check "gstreamer libav"                      rpm -q gstreamer1-plugin-libav
check_not "no KDE PIM packages left"         bash -c "rpm -qa --qf '%{NAME}\n' | grep -E '$PIM_REGEX'"
check_not "no LibreOffice packages left"     bash -c "rpm -qa --qf '%{NAME}\n' | grep -E '^libreoffice'"
check "plasma-workspace kept"                rpm -q plasma-workspace
check "dolphin kept"                         rpm -q dolphin
check "konsole kept"                         rpm -q konsole
check_not "Akonadi data deleted"             test -e "$home/.local/share/akonadi"
check_not "local mail deleted"               test -e "$home/.local/share/local-mail"
check_not "LibreOffice profile deleted"      test -e "$home/.config/libreoffice"
check_not "kmail2rc deleted"                 test -e "$home/.config/kmail2rc"
check "unrelated config kept"                test -e "$home/.config/keepme"
check "Documents kept"                       test -e "$home/Documents/report.odt"
check "Flathub remote added"                 bash -c "flatpak remotes --columns=name | grep -qx flathub"
check "journald size cap written"            test -e /etc/systemd/journald.conf.d/00-size.conf
check "log written"                          test -s /var/log/fedora-kde-setup.log
check "marker written"                       test -e /var/lib/fedora-kde-setup/done

echo "==> Re-runs"
if bash "$SCRIPT" --yes --no-reboot --user "$TEST_USER" > /tmp/rerun.log 2>&1; then
    fail "second run refuses without --force"
else
    check "second run says it already completed" grep -q 'already completed' /tmp/rerun.log
fi
if bash "$SCRIPT" --yes --no-reboot --force --user "$TEST_USER" > /tmp/force.log 2>&1; then
    pass "--force re-run exits 0"
else
    tail -n 30 /tmp/force.log
    fail "--force re-run exits 0"
fi

echo
if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"
