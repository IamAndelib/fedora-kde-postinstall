#!/usr/bin/env bash
# install.sh - one-command launcher for fedora-kde-setup.sh.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/IamAndelib/fedora-kde-postinstall/main/install.sh)
#
# Downloads a tested release of the setup script into a temporary folder, checks its
# SHA-256 checksum, and runs it with sudo. The folder is removed afterwards (and /tmp is
# cleared on reboot anyway). Options are passed on, e.g. "... install.sh) --status".

set -Eeuo pipefail

readonly REPO=IamAndelib/fedora-kde-postinstall
# The release to run. FEDORA_KDE_SETUP_REF picks another tag or branch (for testing).
readonly REF=${FEDORA_KDE_SETUP_REF:-v1.2.0}
readonly BASE=https://raw.githubusercontent.com/$REPO/$REF

fail() {
    printf '\e[31;1mError:\e[0m %s\n' "$*" >&2
    exit 1
}

dir=$(mktemp -d "${TMPDIR:-/tmp}/fedora-kde-postinstall.XXXXXX") || fail "Couldn't create a temporary folder."
trap 'rm -rf -- "$dir"' EXIT

printf 'Downloading the Fedora KDE setup script (%s)...\n' "$REF"
for file in fedora-kde-setup.sh fedora-kde-setup.sh.sha256; do
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsL --retry 3 --max-time 120 \
        -o "$dir/$file" "$BASE/$file" \
        || fail "Couldn't download $BASE/$file. Check your internet connection and try again."
done
(cd "$dir" && sha256sum --quiet -c fedora-kde-setup.sh.sha256) \
    || fail "The download is incomplete or was modified (checksum mismatch). Nothing was changed; please try again."
printf 'Download verified.\n'

rc=0
if (( EUID == 0 )); then
    bash "$dir/fedora-kde-setup.sh" "$@" || rc=$?
else
    printf 'The setup needs administrator rights: enter your password if asked (nothing shows while you type).\n'
    sudo bash "$dir/fedora-kde-setup.sh" "$@" || rc=$?
fi
exit "$rc"
