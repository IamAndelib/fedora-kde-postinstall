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

echo "==> Status report and dry run change nothing"
bash "$SCRIPT" --status --user "$TEST_USER" > /tmp/status.log 2>&1 || { cat /tmp/status.log; fail "--status exits 0"; }
check "status lists KDE PIM as installed"      grep -q 'Remove KDE PIM' /tmp/status.log
bash "$SCRIPT" --dry-run --all --user "$TEST_USER" > /tmp/dry.log 2>&1 || { cat /tmp/dry.log; fail "dry run exits 0"; }
check "dry run changes nothing (no state)"     test ! -e /var/lib/fedora-kde-setup/done

echo "==> Only one step: remove LibreOffice"
if bash "$SCRIPT" --yes --no-reboot --only libreoffice --user "$TEST_USER"; then pass "--only libreoffice exits 0"; else fail "--only libreoffice exits 0"; fi
check_not "LibreOffice removed"                bash -c "rpm -qa --qf '%{NAME}\n' | grep -E '^libreoffice'"
check_not "LibreOffice profile deleted"        test -e "$home/.config/libreoffice"
check "KDE PIM still installed"                rpm -q kmail
check "KDE PIM data untouched"                 test -e "$home/.local/share/local-mail"
check_not "no RPM Fusion yet"                  rpm -q rpmfusion-free-release
check "state records libreoffice"              grep -q '^libreoffice ' /var/lib/fedora-kde-setup/done

echo "==> Everything else (--all)"
if bash "$SCRIPT" --yes --no-reboot --all --user "$TEST_USER" > /tmp/all.log 2>&1; then
    pass "--all exits 0"
else
    tail -n 40 /tmp/all.log
    fail "--all exits 0"
fi
check "LibreOffice step skipped as already done" grep -q 'Remove LibreOffice (already done)' /tmp/all.log
check "progress reaches 100%"                  grep -q '100%' /tmp/all.log
check "dnf.conf: fastestmirror=True"           grep -qx 'fastestmirror=True' /etc/dnf/dnf.conf
check "dnf.conf: max_parallel_downloads=10"    grep -qx 'max_parallel_downloads=10' /etc/dnf/dnf.conf
check "dnf.conf: defaultyes=True"              grep -qx 'defaultyes=True' /etc/dnf/dnf.conf
check "RPM Fusion free installed"              rpm -q rpmfusion-free-release
check "RPM Fusion nonfree installed"           rpm -q rpmfusion-nonfree-release
check "openh264 repo enabled"                  bash -c "dnf5 repolist --enabled | grep -q fedora-cisco-openh264"
check "full ffmpeg installed"                  rpm -q ffmpeg
check_not "ffmpeg-free gone"                   rpm -q ffmpeg-free
check "gstreamer bad-freeworld"                rpm -q gstreamer1-plugins-bad-freeworld
check "gstreamer ugly"                         rpm -q gstreamer1-plugins-ugly
check "gstreamer libav"                        rpm -q gstreamer1-plugin-libav
check_not "no KDE PIM packages left"           bash -c "rpm -qa --qf '%{NAME}\n' | grep -E '$PIM_REGEX'"
check "plasma-workspace kept"                  rpm -q plasma-workspace
check "dolphin kept"                           rpm -q dolphin
check "konsole kept"                           rpm -q konsole
check_not "Akonadi data deleted"               test -e "$home/.local/share/akonadi"
check_not "local mail deleted"                 test -e "$home/.local/share/local-mail"
check_not "kmail2rc deleted"                   test -e "$home/.config/kmail2rc"
check "unrelated config kept"                  test -e "$home/.config/keepme"
check "Documents kept"                         test -e "$home/Documents/report.odt"
check "Flathub remote added"                   bash -c "flatpak remotes --columns=name | grep -qx flathub"
if command -v kwriteconfig6 &>/dev/null; then
    check "Flathub is Discover's default"      grep -qx 'currentApplicationBackend=flatpak-backend' "$home/.config/discoverrc"
fi
check "journald size cap written"              test -e /etc/systemd/journald.conf.d/00-size.conf
check "log written"                            test -s /var/log/fedora-kde-setup.log

echo "==> Re-runs"
bash "$SCRIPT" --status --user "$TEST_USER" > /tmp/status2.log 2>&1 || fail "second --status exits 0"
check "status shows steps already done"        grep -q 'already' /tmp/status2.log
if bash "$SCRIPT" --yes --no-reboot --all --user "$TEST_USER" > /tmp/rerun.log 2>&1; then
    pass "re-run with --all exits 0"
else
    tail -n 30 /tmp/rerun.log
    fail "re-run with --all exits 0"
fi
check_not "re-run doesn't remove packages again" grep -q 'dnf5 remove -y' /tmp/rerun.log
if bash "$SCRIPT" --yes --no-reboot --force --only dnf,maintenance --user "$TEST_USER" > /tmp/force.log 2>&1; then
    pass "--force re-run exits 0"
else
    tail -n 30 /tmp/force.log
    fail "--force re-run exits 0"
fi
check "existing dnf settings kept"             grep -q 'already set' /tmp/force.log

echo
if (( failures )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "All checks passed"
