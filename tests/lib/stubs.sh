# shellcheck shell=bash
# Stub generator: builds a PATH in which every external command fedora-kde-setup.sh
# may call is a logging stub (lib/stub), plus a whitelist of harmless real tools.
# Nothing else is reachable, so a scenario can never run the real dnf, systemctl,
# reboot, mokutil, ...

# Commands the script runs that could inspect or change the host. All stubbed.
readonly FKS_STUB_COMMANDS=(
    dnf5 dnf rpm lspci lscpu mokutil systemd-detect-virt flatpak fwupdmgr systemctl
    curl getent id pgrep pkill sudo akmods kmodgenca modinfo akonadictl kbuildsycoca6
    uname date openssl pkcon sleep runuser df rpmkeys
)

# Real tools the script (and the stubs) need; they only touch paths they are given,
# which are all inside the scenario's temp dirs. (sleep is stubbed so polls don't wait.)
readonly FKS_SAFE_TOOLS=(bash awk sed grep sort tail head cut tr tee install rm od cat mv mkdir find flock chmod mktemp stat)

# safebin_create DIR: symlink farm of the whitelisted real tools.
safebin_create() {
    local dir=$1 tool path
    mkdir -p "$dir"
    for tool in "${FKS_SAFE_TOOLS[@]}"; do
        path=$(command -v "$tool") || { echo "required tool not found: $tool" >&2; return 1; }
        ln -sf "$path" "$dir/$tool"
    done
}

# stubs_create STUBDIR POOLDIR [MISSING_COMMAND...]
# Every command gets a stub in STUBDIR, except the "missing" ones, which go to
# POOLDIR (the dnf stub moves e.g. flatpak into PATH when the flatpak package is
# installed, the way a real install would).
stubs_create() {
    local dir=$1 pool=$2 missing=" ${*:3} " cmd
    mkdir -p "$dir" "$pool"
    for cmd in "${FKS_STUB_COMMANDS[@]}"; do
        if [[ $missing == *" $cmd "* ]]; then
            ln -s "$FKS_LIB/stub" "$pool/$cmd"
        else
            ln -s "$FKS_LIB/stub" "$dir/$cmd"
        fi
    done
}
