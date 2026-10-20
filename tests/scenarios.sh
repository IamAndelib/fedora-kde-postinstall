# shellcheck shell=bash
# Scenario matrix for tests/run.sh.
#
# scenario NAME MODES DESCRIPTION registers sc_NAME. Before each run the runner gives
# the scenario fresh dirs and the base machine from fx_base (Fedora 41 KDE, dnf5,
# PIM + LibreOffice installed, bare metal, Secure Boot off, PackageKit idle, no PCI
# devices, user "tester" with PIM/LibreOffice junk and decoys in a home whose path has
# a space). sc_NAME adjusts the machine, calls invoke (once per run, or more) and
# asserts. Shared variables come from lib/harness.sh (read there, set here, and vice
# versa).
# shellcheck disable=SC2154,SC2034

PIM_SORTED=$(printf '%s\n' "${FX_PIM[@]}" | LC_ALL=C sort | tr '\n' ' ')
PIM_SORTED=${PIM_SORTED% }
OFFICE_SORTED=$(printf '%s\n' "${FX_OFFICE[@]}" | LC_ALL=C sort | tr '\n' ' ')
OFFICE_SORTED=${OFFICE_SORTED% }
readonly PIM_SORTED OFFICE_SORTED

# NVIDIA GPUs by PCI device ID.
readonly NV_TU106=(0x1f08 "NVIDIA Corporation TU106 [GeForce RTX 2060 Rev. A] (rev a1)")
readonly NV_AD107=(0x28e0 "NVIDIA Corporation AD107 [GeForce RTX 4060] (rev a1)")
readonly NV_GA107M=(0x25a2 "NVIDIA Corporation GA107M [GeForce RTX 3050 Mobile] (rev a1)")
readonly NV_GA106=(0x2504 "NVIDIA Corporation GA106 [GeForce RTX 3060 Lite Hash Rate] (rev a1)")
readonly NV_GP104=(0x1b80 "NVIDIA Corporation GP104 [GeForce GTX 1080] (rev a1)")
readonly NV_GK208=(0x128b "NVIDIA Corporation GK208B [GeForce GT 710] (rev a1)")
readonly NV_MCP79=(0x0863 "NVIDIA Corporation C79 [GeForce 9400M] (rev b1)")
readonly NEW_KERNEL=6.12.5-200.fc41.x86_64
readonly NV_CURRENT_PKGS="akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power libva-nvidia-driver"
readonly NV_580XX_PKGS="akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda xorg-x11-drv-nvidia-580xx-power libva-nvidia-driver"
readonly PIM_PROC_RE='^(akonadi|kalendarac|korgac|kontact|kmail|korganizer|kaddressbook|akregator|kalarm|merkuro)'

world_readable_with() {  # FILE TEXT: FILE is readable by others and contains TEXT
    [[ $(stat -c %A "$1" 2>/dev/null) == ???????r* ]] && grep -qF -- "$2" "$1"
}

mok_cert() { printf '%s' "$R/etc/pki/akmods/certs/public_key.der"; }

# ---------------------------------------------------------------------------
# Shared expectations

expect_out_fixed()       { check "output contains '$1'" grep -Fq -- "$1" "$OUT"; }
expect_no_out_fixed()    { check "output lacks '$1'" not grep -Fq -- "$1" "$OUT"; }
expect_action_line()     { check "action line '$1'" grep -Fxq -- "$1" "$T/actions"; }
expect_no_action_line()  { check "no action line '$1'" not grep -Fxq -- "$1" "$T/actions"; }
expect_call_line()       { check "call line '$1'" grep -Fxq -- "$1" "$CALLS"; }
expect_no_call_fixed()   { check "no call containing '$1'" not grep -Fq -- "$1" "$CALLS"; }
count_calls()            { grep -Ec -- "$1" "$CALLS" || true; }

readonly CURL_HEAD='curl --proto =https --proto-redir =https --tlsv1.2 -fsIL --max-time 20 -o /dev/null'
readonly CURL_GET='curl --proto =https --proto-redir =https --tlsv1.2 -fsSL --retry 3 --max-time 180 -o'
rf_url() { printf 'https://%s/%s/fedora/rpmfusion-%s-release-%s.noarch.rpm' "${3:-mirrors.rpmfusion.org}" "$1" "$1" "$2"; }
rf_key() { printf '%s' "$R/usr/share/distribution-gpg-keys/rpmfusion/RPM-GPG-KEY-rpmfusion-$1-fedora-$2"; }
re_quote() { sed 's/[][\\.*^$+?(){}|/]/\\&/g' <<<"$1"; }

# RPM Fusion bootstrap: key import, HTTPS download, signature check, local install.
expect_rpmfusion() {  # RELEASE [REPOS...]  (default: free nonfree)
    local rel=$1 repo wd files=""
    shift
    local repos=("${@:-free}")
    (( $# )) || repos=(free nonfree)
    if ! is_live; then
        for repo in "${repos[@]}"; do
            expect_action_line "rpmkeys --import $(rf_key "$repo" "$rel")"
            expect_action_line "download $(rf_url "$repo" "$rel")"
            expect_action_line "rpmkeys --checksig rpmfusion-$repo-release.noarch.rpm"
        done
        expect_action_line 'dnf5 install -y <verified rpmfusion-*-release packages>'
        return 0
    fi
    # Downloads go to a mktemp dir under FKS_ROOT/tmp, never the caller's TMPDIR.
    wd="$(re_quote "$R/tmp")/fedora-kde-setup\.[A-Za-z0-9]{6}"
    for repo in "${repos[@]}"; do
        expect_call_line "rpmkeys --import $(rf_key "$repo" "$rel")"
        expect_call "^$(re_quote "$CURL_GET") $wd/rpmfusion-$repo-release\.noarch\.rpm $(re_quote "$(rf_url "$repo" "$rel")")$"
        expect_call "^rpmkeys --checksig -- $wd/rpmfusion-$repo-release\.noarch\.rpm$"
        expect_call "^rpm -qp --qf %\{NAME\} -- $wd/rpmfusion-$repo-release\.noarch\.rpm$"
        expect_out "RPM Fusion $repo release package signature verified"
        files+=" $wd/rpmfusion-$repo-release\.noarch\.rpm"
    done
    expect_action "^dnf5 install -y$files$"
    expect_order '^rpmkeys --checksig' '^dnf5 install -y .*/rpmfusion-'
}

expect_success() {
    expect_rc 0
    if is_live; then
        expect_grep "$R/var/lib/fedora-kde-setup/done" '^2026-01-02 03:04:05$'
        expect_grep "$R/etc/systemd/journald.conf.d/00-size.conf" '^SystemMaxUse=500M$'
        expect_count "$R/etc/dnf/dnf.conf" '^fastestmirror=True$' 1
    else
        expect_out 'Dry run finished; nothing was changed'
        expect_no_file "$R/var/lib/fedora-kde-setup/done"
    fi
}

expect_untouched() {  # a run that must stop before changing anything
    expect_rc nonzero
    expect_no_dnf
    expect_no_call '^systemctl (mask|stop)'
    check "completion marker not written" not grep -qs '^2026-01-02 03:04:05$' "$R/var/lib/fedora-kde-setup/done"
    expect_count "$R/etc/dnf/dnf.conf" 'fastestmirror' 0
    expect_file "$H/.config/kmail2rc"
}

# Commands run as the target user are logged as "runuser -u tester -- CMD" and executed
# as "runuser -u tester -- setsid -w CMD" (the runuser stub really runs rm, inside the
# scenario dir only).
as_user_prefix() {
    if is_live; then printf 'runuser -u tester -- setsid -w'; else printf 'runuser -u tester --'; fi
}

expect_deleted() {  # HOME REL_PATH...
    local home=$1 p
    shift
    for p in "$@"; do
        expect_action_line "$(as_user_prefix) rm -rf -- $home/$p"
        if is_live; then expect_no_file "$home/$p"; fi
    done
}

expect_kept() {  # HOME REL_PATH...
    local home=$1 p
    shift
    for p in "$@"; do
        expect_no_action_line "$(as_user_prefix) rm -rf -- $home/$p"
        expect_file "$home/$p"
    done
}

expect_rm_count() {  # HOME N: exactly N deletions under HOME, and the summary says so
    local n
    n=$(grep -cF -- "rm -rf -- $1/" "$T/actions")
    check "exactly $2 deletions under the home (found $n)" test "$n" -eq "$2"
    expect_out_fixed "Removed $2 PIM/LibreOffice data and config entries from $1"
}

expect_home_cleaned() {  # HOME
    expect_deleted "$1" "${FX_JUNK[@]}"
    expect_kept "$1" "${FX_DECOYS[@]}"
    expect_file "$T/outside/lo-profile/registrymodifications.xcu"
    expect_rm_count "$1" "${#FX_JUNK[@]}"
}

expect_pim_data_kept() {  # PIM batch skipped, LibreOffice removed
    expect_kept "$H" "${FX_PIM_JUNK[@]}"
    expect_deleted "$H" "${FX_OFFICE_JUNK[@]}"
    expect_rm_count "$H" "${#FX_OFFICE_JUNK[@]}"
    expect_out_fixed "Kept KDE PIM data in $H because KDE PIM is still installed"
}

expect_home_intact() {  # HOME
    local p
    for p in "${FX_JUNK[@]}" "${FX_DECOYS[@]}"; do expect_file "$1/$p"; done
}

expect_nvidia() {  # "PKGS" expected in the driver install line
    expect_action "^dnf5 install -y --skip-unavailable $1$"
    expect_action '^systemctl enable nvidia-fallback.service$'
    expect_no_action 'nvidia-(suspend|resume|hibernate)'
    expect_install "kernel-devel-$FX_KERNEL"
    expect_action "^akmods --force --kernels $FX_KERNEL$"
    expect_order "^dnf5 install -y --skip-unavailable ${1%% *} " '^akmods --force'
}

expect_no_kmods() {
    expect_no_action 'akmod-nvidia'
    expect_no_install broadcom-wl
    expect_no_action 'kernel-devel'
    expect_no_action '^akmods'
    expect_no_action '^kmodgenca'
    expect_no_action 'mokutil --import'
}

# ---------------------------------------------------------------------------
# Hardware

scenario intel_laptop "dry live" "Intel iGPU + Intel Wi-Fi laptop: full happy path"
sc_intel_laptop() {
    fx_gpu_intel; fx_wifi_intel; fx_wifi_phy 0000:00:14.3; fx_battery
    fx_add installed libva-intel-media-driver
    invoke --yes --no-reboot
    expect_success
    expect_out 'Form factor +laptop'
    expect_out 'Secure Boot +disabled'
    expect_out 'GPU\(s\) +Intel Corporation Alder Lake-P GT2'
    expect_call_line "$CURL_HEAD $(rf_url free 41)"
    expect_call '^uname -m$'
    expect_call_line "pgrep -x dnf5|dnf|rpm|dnf-automatic"
    expect_call_line "rpm -q --quiet rpm"
    expect_action '^systemctl mask --runtime packagekit.service$'
    expect_order '^systemctl mask --runtime packagekit' '^dnf5 upgrade --refresh'
    expect_action '^dnf5 upgrade --refresh -y$'
    expect_rpmfusion 41
    expect_no_install distribution-gpg-keys
    expect_call '^dnf5 repolist --enabled$'
    expect_action '^dnf5 config-manager setopt fedora-cisco-openh264.enabled=1$'
    expect_no_install dnf5-plugins
    expect_install rpmfusion-nonfree-appstream-data
    expect_action '^dnf5 swap -y ffmpeg-free ffmpeg --allowerasing$'
    expect_action '^dnf5 upgrade -y @multimedia --setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin$'
    expect_action '^dnf5 install -y --skip-unavailable --allowerasing gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-libav gstreamer1-plugin-openh264 mozilla-openh264 lame ffmpegthumbs libva-utils$'
    expect_action '^dnf5 swap -y libva-intel-media-driver intel-media-driver --allowerasing$'
    expect_install libva-intel-driver
    expect_no_action 'mesa-va-drivers'
    expect_no_kmods
    expect_no_out 'Broadcom'
    expect_out 'no extra driver needed'
    expect_no_action '^dnf5 mark'
    expect_no_action 'autoremove'
    expect_call "^dnf5 remove $PIM_SORTED --assumeno$"
    expect_call "^dnf5 remove $OFFICE_SORTED --assumeno$"
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_no_action 'remove -y .*(kgpg|kpim6-akonadi-mime|kf6-kcontacts|kate)'
    expect_action '^dnf5 group remove -y --no-packages kde-pim$'
    expect_action '^dnf5 group remove -y --no-packages libreoffice$'
    expect_action '^flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo$'
    expect_action '^flatpak remote-modify --no-filter --enable flathub$'
    expect_action '^flatpak remote-delete --force fedora$'
    expect_no_install plasma-discover-flatpak
    expect_action '^fwupdmgr refresh --force$'
    expect_action '^fwupdmgr update -y --no-reboot-check --no-unreported-check$'
    expect_action '^systemctl enable --now fstrim.timer$'
    expect_action '^systemctl restart systemd-journald$'
    expect_home_cleaned "$H"
    if is_live; then
        expect_call '^systemctl unmask --runtime packagekit.service$'
        expect_order '^systemctl restart systemd-journald' '^systemctl unmask --runtime packagekit'
        expect_no_call '^pkcon'
        expect_no_out 'Not installed'
        expect_out 'Firmware already up to date'
        expect_call '^dnf5 history list$'
        expect_order '^dnf5 history list$' '^systemctl mask'
        expect_out_fixed 'Package changes are in "sudo dnf history list" (this run: transactions after #17);'
        expect_out 'A reboot is needed to load the updated system'
        expect_out_fixed "Log: $R/var/log/fedora-kde-setup.log"
        check "root log is mode 600" test "$(stat -c %a "$R/var/log/fedora-kde-setup.log")" = 600
    fi
}

scenario amd_desktop "dry live" "AMD desktop: mesa-va freeworld only, RPM Fusion already present"
sc_amd_desktop() {
    fx_gpu_amd
    fx_conf FKS_CPU_VENDOR=AuthenticAMD FKS_FWUPD_RC=0
    fx_del installed ffmpeg-free
    fx_add installed rpmfusion-free-release rpmfusion-nonfree-release mesa-vdpau-drivers
    invoke --yes --no-reboot
    expect_success
    expect_out 'RPM Fusion already installed'
    expect_no_action 'rpmkeys|download '
    expect_no_call '^curl .* -fsSL '
    expect_out 'Form factor +desktop'
    expect_out 'AMD: mesa-va-drivers-freeworld'
    expect_install mesa-va-drivers-freeworld
    expect_no_action 'swap .*mesa-va-drivers'
    expect_no_action 'vdpau'
    expect_no_action '^dnf5 install .*rpmfusion-(free|nonfree)-release'
    expect_action '^dnf5 install -y --skip-unavailable ffmpeg --allowerasing$'
    expect_no_action 'intel-media-driver'
    expect_no_kmods
    if is_live; then expect_out 'Firmware updated'; expect_out 'AMD VA-API: mesa-va-drivers-freeworld'; fi
}

scenario amd_swap "dry live" "AMD with mesa-va-drivers installed: swapped for freeworld"
sc_amd_swap() {
    fx_gpu_amd
    fx_add installed mesa-va-drivers
    invoke --yes --no-reboot
    expect_success
    expect_action '^dnf5 swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing$'
    expect_no_install mesa-va-drivers-freeworld
}

scenario intel_fresh "live" "Intel without libva-intel-media-driver: intel-media-driver installed"
sc_intel_fresh() {
    fx_gpu_intel
    invoke --yes --no-reboot
    expect_success
    expect_action '^dnf5 install -y --skip-unavailable intel-media-driver --allowerasing$'
    expect_no_action 'swap -y libva-intel-media-driver'
    expect_out 'Intel VA-API: intel-media-driver'
}

scenario nvidia_turing "dry live" "NVIDIA Turing (0x1f08) desktop, Secure Boot off"
sc_nvidia_turing() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'NVIDIA: akmod-nvidia \+ CUDA \+ power management \+ VA-API \(NVIDIA Corporation TU106'
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_no_call 'repoquery'
    expect_no_action '^kmodgenca'
    expect_no_action 'mokutil --import'
    expect_no_out 'Secure Boot: create'
    if is_live; then
        expect_call '^systemctl cat nvidia-fallback.service$'
        expect_out "Kernel module 'nvidia' built for $FX_KERNEL"
        expect_out 'A reboot is needed to load the new drivers'
    fi
}

scenario nvidia_no_lspci "dry live" "No lspci: NVIDIA RTX 4060 still classified by device ID"
sc_nvidia_no_lspci() {
    fx_missing lspci
    fx_gpu_nvidia "${NV_AD107[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'GPU\(s\) +vendor 0x10de device 0x28e0'
    expect_out 'NVIDIA: akmod-nvidia \+ CUDA'
    expect_nvidia "$NV_CURRENT_PKGS"
}

scenario nvidia_pkg_missing "live" "akmod-nvidia unavailable: warning, no kmod build, no fallback unit"
sc_nvidia_pkg_missing() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_add unavailable akmod-nvidia
    invoke --yes --no-reboot
    expect_success
    expect_out 'Not installed \(unavailable or failed\): akmod-nvidia'
    expect_no_action 'kernel-devel'
    expect_no_action '^akmods'
    expect_no_action 'enable nvidia-fallback'
    expect_no_out 'A reboot is needed to load the new drivers'
}

scenario nvidia_turing_sb "dry pty" "Secure Boot on, terminal, no --yes: kmodgenca + interactive MOK import before akmod-nvidia"
sc_nvidia_turing_sb() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    if [[ $MODE == pty ]]; then
        PTY_INPUT='y\n'
        invoke --no-reboot
    else
        invoke --yes --no-reboot
    fi
    expect_success
    expect_out 'Secure Boot +enabled'
    expect_out 'Secure Boot: create an akmods signing key'
    expect_action '^dnf5 install -y --skip-unavailable akmods kmodtool mokutil openssl$'
    expect_action '^kmodgenca -a$'
    expect_action_line "mokutil --import $(mok_cert)"
    expect_order '^kmodgenca -a$' '^mokutil --import'
    expect_order '^mokutil --import' '^dnf5 install .* akmod-nvidia '
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_out 'Secure Boot key enrollment on next boot'
    if is_live; then
        expect_file "$(mok_cert)"
        expect_call_line "mokutil --test-key $(mok_cert)"
        expect_no_call 'generate-hash|--hash-file|^openssl'
        expect_out 'akmods signing key queued for enrollment'
        expect_out 'Type the one-time password you just created'
    fi
}

scenario nvidia_sb_yes_tty "pty" "Secure Boot on, --yes on a terminal: generated password, never the interactive prompt"
sc_nvidia_sb_yes_tty() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    expect_call '^openssl rand -hex 4$'
    expect_call_line "mokutil --import $(mok_cert) --hash-file $R/root/.fedora-kde-setup-mok.hash"
    expect_no_call_line "mokutil --import $(mok_cert)"
    expect_out 'MOK one-time password: a1b2c3d4'
    expect_nvidia "$NV_CURRENT_PKGS"
}

scenario nvidia_sb_notty "live" "Secure Boot on, --yes, no terminal: generated MOK password saved (0600) and shown"
sc_nvidia_sb_notty() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    local pwfile=$R/root/fedora-kde-setup-mok-password.txt
    expect_call '^openssl rand -hex 4$'
    expect_call '^mokutil --generate-hash=a1b2c3d4$'
    expect_call_line "mokutil --import $(mok_cert) --hash-file $R/root/.fedora-kde-setup-mok.hash"
    expect_order '^mokutil --import' '^dnf5 install .* akmod-nvidia '
    expect_no_file "$R/root/.fedora-kde-setup-mok.hash"
    # $R/root is root's 0700 dir: read it as root (the harness may be a sudo user).
    check "MOK password file holds the password" "${ROOTCMD[@]}" grep -qx a1b2c3d4 "$pwfile"
    check "MOK password file is mode 600" test "$("${ROOTCMD[@]}" stat -c %a "$pwfile" 2>/dev/null)" = 600
    check "FKS_ROOT/root created with mode 700" test "$("${ROOTCMD[@]}" stat -c %a "$R/root" 2>/dev/null)" = 700
    expect_out_fixed "MOK one-time password: a1b2c3d4 (saved in $pwfile); you'll need it on the next boot"
    expect_out_fixed "this one-time password: a1b2c3d4 (also saved in $pwfile)"
    expect_nvidia "$NV_CURRENT_PKGS"
    # The password file is 0600; the log the same password is printed to must not be
    # readable by everyone.
    local log=$R/var/log/fedora-kde-setup.log
    check "MOK password not exposed in a world-readable log" not world_readable_with "$log" a1b2c3d4
}

scenario nvidia_sb_enrolled "live" "Secure Boot on, key already enrolled: no MOK import"
sc_nvidia_sb_enrolled() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_STATE=enrolled
    mkdir -p "$R/etc/pki/akmods/certs"; echo cert > "$(mok_cert)"
    invoke --yes --no-reboot
    expect_success
    expect_no_call '^kmodgenca'
    expect_out 'akmods signing key already enrolled'
    expect_no_call 'mokutil --import'
    expect_no_out 'Secure Boot key enrollment on next boot'
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_out "Kernel module 'nvidia' built"
}

scenario nvidia_sb_pending "live" "Secure Boot on, key already queued: no new import, earlier password hint"
sc_nvidia_sb_pending() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_STATE=pending
    invoke --yes --no-reboot
    expect_success
    expect_no_call 'mokutil --import'
    expect_out 'already queued for enrollment'
    expect_out_fixed 'Type the one-time password you set when the key was first queued (forgot it? sudo mokutil --revoke-import, then re-run with --force)'
    expect_nvidia "$NV_CURRENT_PKGS"
}

scenario nvidia_sb_pending_saved "live" "Key queued by an earlier --yes run: finish shows the saved password"
sc_nvidia_sb_pending_saved() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_STATE=pending
    mkdir -p "$R/root"
    printf 'feedc0de\n' > "$R/root/fedora-kde-setup-mok-password.txt"
    invoke --yes --no-reboot
    expect_success
    expect_no_call 'mokutil --(import|generate-hash)'
    expect_out_fixed "Type this one-time password: feedc0de (also saved in $R/root/fedora-kde-setup-mok-password.txt)"
    expect_no_out 'revoke-import'
}

scenario nvidia_sb_import_fails "live" "MOK import fails (no tty): NVIDIA and Broadcom drivers skipped"
sc_nvidia_sb_import_fails() {
    fx_gpu_nvidia "${NV_TU106[@]}"; fx_wifi_broadcom 0x43a0 bcma
    fx_conf FKS_SB=enabled FKS_MOK_IMPORT_RC=1
    invoke --yes --no-reboot
    expect_success
    expect_out 'MOK import failed'
    expect_out "Secure Boot signing isn't set up, so the NVIDIA/Broadcom drivers were skipped"
    expect_no_action 'install .*akmod-nvidia'
    expect_no_install broadcom-wl
    expect_no_action '^akmods'
    expect_no_file "$R/root/fedora-kde-setup-mok-password.txt"
    expect_no_file "$R/root/.fedora-kde-setup-mok.hash"
    expect_no_out 'Secure Boot key enrollment on next boot'
}

scenario nvidia_sb_tty_fails "pty" "MOK import fails 3 times on a terminal: driver skipped"
sc_nvidia_sb_tty_fails() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_IMPORT_RC=1
    PTY_INPUT='y\n'
    invoke --no-reboot
    expect_success
    check "mokutil --import tried 3 times (got $(count_calls '^mokutil --import'))" \
        test "$(count_calls '^mokutil --import')" -eq 3
    expect_out 'MOK import failed 3 times'
    expect_no_action 'install .*akmod-nvidia'
}

scenario kmodgenca_fails "live" "kmodgenca creates no key: drivers skipped"
sc_kmodgenca_fails() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_KMODGENCA_CREATES=0
    invoke --yes --no-reboot
    expect_success
    expect_out "kmodgenca didn't create"
    expect_no_call 'mokutil --import'
    expect_no_action 'install .*akmod-nvidia'
}

scenario nvidia_sb_unsigned "live" "Secure Boot on, module built without signer: warning"
sc_nvidia_sb_unsigned() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_STATE=enrolled FKS_MOD_SIGNER=
    invoke --yes --no-reboot
    expect_success
    expect_call "^modinfo -k $FX_KERNEL -F signer nvidia$"
    expect_out "Kernel module 'nvidia' is built but not signed"
}

scenario optimus_laptop "dry live" "Intel + NVIDIA GA107M (3D controller) Optimus laptop"
sc_optimus_laptop() {
    fx_gpu_intel; fx_gpu_nvidia "${NV_GA107M[@]}" 0x030200; fx_battery
    invoke --yes --no-reboot
    expect_success
    expect_out 'Form factor +laptop'
    expect_out 'GPU\(s\) +Intel.* \| NVIDIA Corporation GA107M'
    expect_install intel-media-driver
    expect_install libva-intel-driver
    expect_nvidia "$NV_CURRENT_PKGS"
}

scenario amd_nvidia "dry live" "AMD iGPU + NVIDIA RTX 4060"
sc_amd_nvidia() {
    fx_gpu_amd 0000:05:00.0; fx_gpu_nvidia "${NV_AD107[@]}"
    fx_conf FKS_CPU_VENDOR=AuthenticAMD
    fx_add installed mesa-va-drivers
    invoke --yes --no-reboot
    expect_success
    expect_action '^dnf5 swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing$'
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_no_action 'intel-media-driver'
}

scenario pascal_main580 "dry live" "GTX 1080, main driver 580.x, no 580xx package: main driver + swap advice"
sc_pascal_main580() {
    fx_gpu_nvidia "${NV_GP104[@]}"
    fx_conf FKS_NVIDIA_MAIN_VER=580.178.04
    invoke --yes --no-reboot
    expect_success
    expect_out 'NVIDIA: driver branch that still supports this card'
    expect_call_line 'dnf5 -q repoquery --latest-limit=1 --qf %{version}\n xorg-x11-drv-nvidia'
    if is_live; then
        expect_nvidia "$NV_CURRENT_PKGS"
        expect_no_action 'install .*580xx'
        expect_out_fixed 'Installed the main NVIDIA driver (580.178.04) for NVIDIA Corporation GP104'
        expect_out_fixed 'Before upgrading Fedora, run: sudo dnf swap akmod-nvidia akmod-nvidia-580xx --allowerasing'
    else
        # A dry run can't see RPM Fusion yet and assumes the 580xx branch.
        expect_nvidia "$NV_580XX_PKGS"
    fi
}

scenario pascal_prefer580xx "dry live" "GTX 1080, main driver still 580.x but 580xx available: 580xx preferred"
sc_pascal_prefer580xx() {
    fx_gpu_nvidia "${NV_GP104[@]}"
    fx_conf FKS_NVIDIA_MAIN_VER=580.178.04
    fx_add available akmod-nvidia-580xx
    invoke --yes --no-reboot
    expect_success
    expect_nvidia "$NV_580XX_PKGS"
    expect_no_action 'install .* akmod-nvidia '
    expect_no_out 'Before upgrading Fedora'
}

scenario pascal_580xx "dry live" "GTX 1080, main driver 590+, 580xx available: 580xx branch"
sc_pascal_580xx() {
    fx_gpu_nvidia "${NV_GP104[@]}"
    fx_conf FKS_NVIDIA_MAIN_VER=590.44.01
    fx_add available akmod-nvidia-580xx
    invoke --yes --no-reboot
    expect_success
    expect_nvidia "$NV_580XX_PKGS"
    expect_no_action 'install .* akmod-nvidia '
}

scenario pascal_nobranch "dry live" "GTX 1080, 590+ only, no 580xx: live keeps nouveau, dry assumes 580xx"
sc_pascal_nobranch() {
    fx_gpu_nvidia "${NV_GP104[@]}"
    fx_conf FKS_NVIDIA_MAIN_VER=590.44.01
    invoke --yes --no-reboot
    expect_success
    if is_live; then
        expect_out 'No NVIDIA driver branch for NVIDIA Corporation GP104 .* found in RPM Fusion; keeping nouveau'
        expect_no_action 'install .*akmod-nvidia'
        expect_no_action '^akmods'
        expect_no_action 'kernel-devel'
    else
        expect_action "^dnf5 install -y --skip-unavailable $NV_580XX_PKGS$"
    fi
}

scenario dual_nvidia "dry live" "GTX 1080 + RTX 3060: the oldest (legacy) decides"
sc_dual_nvidia() {
    fx_gpu_nvidia "${NV_GA106[@]}" 0x030000 0000:01:00.0
    fx_gpu_nvidia "${NV_GP104[@]}" 0x030000 0000:02:00.0
    fx_conf FKS_NVIDIA_MAIN_VER=590.44.01
    fx_add available akmod-nvidia-580xx
    invoke --yes --no-reboot
    expect_success
    expect_out 'NVIDIA: driver branch that still supports this card, 580xx where needed \(NVIDIA Corporation GP104'
    expect_nvidia "$NV_580XX_PKGS"
}

scenario kepler "dry live" "GT 710 (Kepler 0x128b), Secure Boot on: no driver, no key, warning"
sc_kepler() {
    fx_gpu_nvidia "${NV_GK208[@]}"
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    expect_out 'card too old for maintained drivers, keeping nouveau'
    expect_out "is Kepler or older; RPM Fusion's 470xx driver is end-of-life"
    expect_no_out 'Secure Boot: create'
    expect_no_kmods
}

scenario nforce_igp "dry live" "GeForce 9400M nForce IGP (0x0863): unsupported, nouveau kept"
sc_nforce_igp() {
    fx_gpu_nvidia "${NV_MCP79[@]}" 0x030000 0000:00:10.0
    invoke --yes --no-reboot
    expect_success
    expect_out 'card too old for maintained drivers'
    expect_no_kmods
}

scenario broadcom_wl "dry live" "BCM4360 (0x43a0) on bcma, no wiphy: broadcom-wl + akmods"
sc_broadcom_wl() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0 bcma
    invoke --yes --no-reboot
    expect_success
    expect_out 'Broadcom Wi-Fi: broadcom-wl driver'
    expect_install broadcom-wl
    expect_install "kernel-devel-$FX_KERNEL"
    expect_action "^akmods --force --kernels $FX_KERNEL$"
    expect_no_action 'akmod-nvidia'
    if is_live; then expect_out "Kernel module 'wl' built"; fi
}

scenario broadcom_phy "dry live" "BCM4360 already registered a wiphy (ieee80211/phy0, b43 via bcma): no wl"
sc_broadcom_phy() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0 bcma
    fx_wifi_phy 0000:02:00.0 bcma0:1
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'Broadcom Wi-Fi: broadcom-wl'
    expect_no_kmods
}

scenario broadcom_phy_direct "dry live" "BCM4360 with ieee80211/phy0 directly under the (symlinked) PCI device: no wl"
sc_broadcom_phy_direct() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0 brcmsmac
    fx_wifi_phy 0000:02:00.0
    invoke --yes --no-reboot
    expect_success
    check "fixture: sysfs device entry is a symlink" test -L "$R/sys/bus/pci/devices/0000:02:00.0"
    expect_no_out 'Broadcom Wi-Fi: broadcom-wl'
    expect_no_kmods
}

scenario broadcom_brcmfmac "dry live" "BCM4350 (0x43a3, brcmfmac chip) unbound: not a wl chip, no wl"
sc_broadcom_brcmfmac() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a3
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'Broadcom Wi-Fi: broadcom-wl'
    expect_no_kmods
}

scenario broadcom_sb "dry" "Broadcom wl with Secure Boot on: MOK import before broadcom-wl"
sc_broadcom_sb() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    expect_out 'Secure Boot: create an akmods signing key'
    expect_order '^mokutil --import' "$(pkg_re broadcom-wl)"
}

vm_case() {  # VIRT EXPECTED_PKG...
    fx_conf "FKS_VIRT=$1" FKS_SB=enabled
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_wifi_broadcom 0x43a0
    invoke --yes --no-reboot
    expect_success
    expect_out "Virtual +$1$"
    expect_out "Virtual machine \\($1\\): install guest tools"
    expect_no_out 'Apply firmware updates'
    expect_no_out 'Secure Boot: create'
    local pkg
    for pkg in "${@:2}"; do expect_install "$pkg"; done
    expect_no_kmods
    expect_no_action '^fwupdmgr'
    expect_no_install fwupd
    expect_out 'Virtual machine or container, skipping firmware'
    expect_action '^systemctl mask --runtime packagekit.service$'
}

scenario vm_kvm "dry live" "KVM guest (NVIDIA passthrough, Broadcom, SB on): guest tools only"
sc_vm_kvm() {
    fx_pci 0000:00:01.0 0x030000 0x1af4 0x1050 "Red Hat, Inc. Virtio 1.0 GPU (rev 01)" virtio-pci
    vm_case kvm qemu-guest-agent spice-vdagent
}
scenario vm_vmware "dry live" "VMware guest: open-vm-tools-desktop"
sc_vm_vmware() {
    fx_pci 0000:00:0f.0 0x030000 0x15ad 0x0405 "VMware SVGA II Adapter" vmwgfx
    vm_case vmware open-vm-tools-desktop
}
scenario vm_virtualbox "dry live" "VirtualBox guest: virtualbox-guest-additions"
sc_vm_virtualbox() {
    fx_pci 0000:00:02.0 0x030000 0x80ee 0xbeef "InnoTek Systemberatung GmbH VirtualBox Graphics Adapter" vboxvideo
    vm_case oracle virtualbox-guest-additions
}
scenario vm_hyperv "dry live" "Hyper-V guest: hyperv-daemons"
sc_vm_hyperv() { vm_case microsoft hyperv-daemons; }

scenario vm_unknown "dry" "Unknown hypervisor (xen): no guest tools, no drivers"
sc_vm_unknown() {
    fx_conf FKS_VIRT=xen
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out "No guest tools known for 'xen'"
    expect_no_kmods
}

container_checks() {
    expect_success
    expect_out 'Virtual +container$'
    expect_out 'Container: skip drivers, firmware and services'
    expect_out 'Container: skipping drivers'
    expect_no_out 'Virtual machine \('
    expect_no_out 'Apply firmware updates with fwupd'
    expect_no_action '^systemctl'
    expect_no_call '^systemctl'
    expect_no_kmods
    expect_no_action 'guest-agent|open-vm-tools|hyperv-daemons|virtualbox-guest'
    expect_no_action '^fwupdmgr'
    expect_no_call '^pkcon'
    expect_out 'Virtual machine or container, skipping firmware'
}

scenario container_podman "dry live" "Podman container (.containerenv, detect-virt --container)"
sc_container_podman() {
    touch "$R/run/.containerenv"
    fx_conf FKS_CONTAINER_VIRT=podman
    fx_gpu_nvidia "${NV_TU106[@]}"; fx_wifi_broadcom 0x43a0
    invoke --yes --no-reboot
    container_checks
}

scenario container_env "dry live" "container=docker in the environment alone is NOT trusted: treated as bare metal"
sc_container_env() {
    RUN_ENV+=(container=docker)
    fx_missing lspci
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'GPU\(s\) +vendor 0x10de device 0x1f08'
    expect_out 'Virtual +none$'
    expect_no_out 'Container'
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_action '^fwupdmgr update'
}

scenario container_dockerenv "dry" "/.dockerenv only: detected as container"
sc_container_dockerenv() {
    touch "$R/.dockerenv"
    invoke --yes --no-reboot
    container_checks
}

scenario container_in_vm "dry live" "Container on a Hyper-V host (detect-virt --vm says microsoft)"
sc_container_in_vm() {
    touch "$R/run/.containerenv"
    fx_conf FKS_CONTAINER_VIRT=podman FKS_VIRT=microsoft
    invoke --yes --no-reboot
    container_checks
}

scenario container_pty "pty" "Container on a terminal: confirm, but never offer a reboot"
sc_container_pty() {
    touch "$R/run/.containerenv"
    fx_conf FKS_CONTAINER_VIRT=podman
    PTY_INPUT='y\n'
    invoke
    expect_success
    expect_out 'Proceed\? \[y/N\]'
    expect_no_out 'Reboot now'
    expect_no_call '^systemctl'
}

scenario bios_no_mokutil "dry live" "BIOS boot: no efivars, no mokutil; NVIDIA unsigned"
sc_bios_no_mokutil() {
    fx_missing mokutil
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'Secure Boot +disabled'
    expect_no_call '^mokutil'
    expect_no_action '^kmodgenca'
    expect_no_action '^mokutil|install .* mokutil'
    expect_nvidia "$NV_CURRENT_PKGS"
}

scenario efivars_sb_on "dry" "No mokutil, efivars SecureBoot=1: detected, mokutil installed"
sc_efivars_sb_on() {
    fx_missing mokutil
    fx_efivar_secureboot 1
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'Secure Boot +enabled'
    expect_action '^dnf5 install -y --skip-unavailable akmods kmodtool mokutil openssl$'
    expect_action '^mokutil --import'
}

scenario efivars_sb_off "dry" "No mokutil, efivars SecureBoot=0: disabled"
sc_efivars_sb_off() {
    fx_missing mokutil
    fx_efivar_secureboot 0
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'Secure Boot +disabled'
    expect_no_action '^kmodgenca'
}

# ---------------------------------------------------------------------------
# PackageKit, lock, logging

scenario pk_busy "live" "PackageKit active, goes idle after 2 polls: pkcon quit, no stop"
sc_pk_busy() {
    echo 2 > "$S/pk_active"
    invoke --yes --no-reboot
    expect_success
    expect_action '^systemctl mask --runtime packagekit.service$'
    expect_action '^pkcon quit$'
    expect_order '^pkcon quit' '^dnf5 upgrade --refresh'
    expect_no_call '^systemctl stop packagekit'
    expect_call '^sleep 2$'
    expect_call '^systemctl unmask --runtime packagekit.service$'
}

scenario pk_stuck "live" "PackageKit never goes idle: 60 polls (stubbed sleep), then systemctl stop"
sc_pk_stuck() {
    echo 999 > "$S/pk_active"
    invoke --yes --no-reboot
    expect_rc 1
    check "60 two-second waits (got $(count_calls '^sleep 2$'))" test "$(count_calls '^sleep 2$')" -eq 60
    expect_out_fixed 'PackageKit (Discover) is still busy after 2 minutes. Let it finish, then run this again. Nothing was changed.'
    expect_no_call '^systemctl stop'
    expect_call '^systemctl unmask --runtime packagekit.service$'
    expect_no_call '^dnf5 (upgrade|install|remove|swap)'
    expect_no_file "$R/var/lib/fedora-kde-setup/done"
    expect_count "$R/etc/dnf/dnf.conf" 'fastestmirror' 0
}

scenario pk_stuck_offline "live" "PackageKit stuck with a staged offline update: 'Nothing was changed' must be true"
sc_pk_stuck_offline() {
    echo 999 > "$S/pk_active"
    ln -s /var/lib/PackageKit/prepared-update "$R/system-update"
    invoke --yes --no-reboot
    expect_rc 1
    expect_out 'Nothing was changed'
    expect_no_call '^pkcon offline-cancel'
    expect_file "$R/system-update"
}

scenario pk_absent "live" "No packagekit.service: nothing masked or unmasked"
sc_pk_absent() {
    fx_del units packagekit.service
    invoke --yes --no-reboot
    expect_success
    expect_call '^systemctl cat packagekit.service$'
    expect_no_call '^systemctl (mask|unmask|stop|is-active).*packagekit'
}

scenario pk_offline_update "dry live" "Staged offline update (/system-update): pkcon offline-cancel"
sc_pk_offline_update() {
    ln -s /var/lib/PackageKit/prepared-update "$R/system-update"
    invoke --yes --no-reboot
    expect_success
    expect_action '^pkcon offline-cancel$'
    expect_order '^pkcon offline-cancel' '^dnf5 upgrade --refresh'
    if is_live; then expect_no_file "$R/system-update"; fi
}

scenario pk_offline_nopkcon "live" "Staged offline update without pkcon: rm -f fallback"
sc_pk_offline_nopkcon() {
    fx_missing pkcon
    ln -s /var/lib/PackageKit/prepared-update "$R/system-update"
    invoke --yes --no-reboot
    expect_success
    expect_no_file "$R/system-update"
    expect_out_fixed "\$ rm -f $R/system-update"
}

scenario upgrade_fails "live" "dnf5 upgrade fails: stops with a located error, PackageKit unmasked"
sc_upgrade_fails() {
    fx_add fail '^dnf5 upgrade --refresh'
    EXPECT_ERRTRAP=1
    invoke --yes --no-reboot
    expect_rc nonzero
    expect_out 'Failed \(exit 1\) at line [0-9]+ in run <- update_system <- main: '
    expect_no_file "$R/var/lib/fedora-kde-setup/done"
    expect_call '^systemctl unmask --runtime packagekit.service$'
    expect_no_action '^dnf5 remove -y'
}

scenario interrupted "live" "Ctrl-C during the upgrade: 'Interrupted', PackageKit unmasked, no marker"
sc_interrupted() {
    fx_conf 'FKS_SIGINT_ON=^dnf5 upgrade --refresh'
    invoke --yes --no-reboot
    expect_rc nonzero
    expect_out 'xx Interrupted'
    expect_call '^systemctl unmask --runtime packagekit.service$'
    expect_no_file "$R/var/lib/fedora-kde-setup/done"
    expect_no_action '^dnf5 remove -y'
}

scenario lock_held "live" "Another run holds the lock: dies before changing anything"
sc_lock_held() {
    hold_lock
    invoke --yes --no-reboot
    release_lock
    expect_untouched
    expect_out 'Another run of this script is already in progress'
}

scenario log_unwritable "live" "Log dir missing: falls back to /dev/null, run completes"
sc_log_unwritable() {
    rm -rf "$R/var/log"
    EXPECT_NO_LOG=1
    invoke --yes --no-reboot
    expect_success
    expect_out_fixed 'Log: /dev/null'
}

# ---------------------------------------------------------------------------
# Package manager and removal

scenario dnf4_only "dry live" "No dnf5 binary: real run dies, dry run warns"
sc_dnf4_only() {
    fx_missing dnf5
    ALLOW_NOTFOUND=1
    invoke --yes --no-reboot
    expect_out 'dnf5 not found; this script needs Fedora 41 or newer'
    expect_no_call '^dnf '
    if is_live; then
        expect_untouched
    else
        expect_rc 0
        expect_out 'Dry run finished'
    fi
}

scenario fedora_40 "dry live" "Fedora 40: real run dies, dry run warns"
sc_fedora_40() {
    fx_conf FKS_FEDORA=40
    invoke --yes --no-reboot
    expect_out 'Fedora 40 is too old; this script needs Fedora 41 or newer'
    if is_live; then expect_untouched; else expect_rc 0; fi
}

scenario rawhide "dry live" "Rawhide: RPM Fusion rawhide release packages"
sc_rawhide() {
    fx_os_release ID=fedora VERSION_ID=44 VARIANT_ID=kde REDHAT_SUPPORT_PRODUCT_VERSION=rawhide \
        'PRETTY_NAME="Fedora Linux 44 (KDE Plasma Prerelease)"'
    fx_conf FKS_FEDORA=44
    invoke --yes --no-reboot
    expect_success
    expect_call_line "$CURL_HEAD $(rf_url free rawhide)"
    expect_rpmfusion rawhide
}

scenario openh264_enabled "dry live" "fedora-cisco-openh264 already enabled: no config-manager"
sc_openh264_enabled() {
    fx_add repos fedora-cisco-openh264
    invoke --yes --no-reboot
    expect_success
    expect_out 'Cisco OpenH264 repo already enabled'
    expect_no_action 'config-manager'
}

scenario openh264_no_plugins "dry live" "dnf5-plugins missing: installed before config-manager"
sc_openh264_no_plugins() {
    fx_del installed dnf5-plugins
    invoke --yes --no-reboot
    expect_success
    expect_install dnf5-plugins
    expect_order "$(pkg_re dnf5-plugins)" '^dnf5 config-manager setopt fedora-cisco-openh264.enabled=1$'
}

scenario soft_failures "live" "config-manager, AppStream, codecs, @multimedia fail: warnings only"
sc_soft_failures() {
    fx_add fail 'config-manager' 'install .*rpmfusion-free-appstream-data' \
        'install .*gstreamer1-plugins-ugly' 'upgrade -y @multimedia'
    invoke --yes --no-reboot
    expect_success
    expect_out "Couldn't enable the fedora-cisco-openh264 repo"
    expect_out "Couldn't install RPM Fusion AppStream data"
    expect_out 'Multimedia group not installed'
    expect_out 'Some codec packages failed to install'
    expect_out 'Not installed \(unavailable or failed\): gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-libav'
}

scenario codecs_unavailable "live" "A codec package is unavailable: listed in a warning"
sc_codecs_unavailable() {
    fx_add unavailable gstreamer1-plugins-bad-freeworld
    invoke --yes --no-reboot
    expect_success
    expect_out 'Not installed \(unavailable or failed\): gstreamer1-plugins-bad-freeworld$'
    expect_no_out 'Codecs: ffmpeg'
}

scenario pim_absent "dry live" "PIM/LibreOffice not installed; unowned leftovers removed, owned kept"
sc_pim_absent() {
    fx_del installed "${FX_PIM[@]}" "${FX_OFFICE[@]}"
    mkdir -p "$R/usr/lib64/libreoffice/program" "$R/usr/share/akonadi/agents" "$R/etc/libreoffice"
    fx_add owned /etc/libreoffice
    invoke --yes --no-reboot
    expect_success
    expect_out 'No KDE PIM or LibreOffice packages installed'
    expect_no_call 'remove .*--assumeno'
    expect_no_action '^dnf5 remove -y'
    expect_action '^dnf5 group remove -y --no-packages kde-pim$'
    expect_home_cleaned "$H"
    if is_live; then
        expect_no_file "$R/usr/lib64/libreoffice"
        expect_no_file "$R/usr/share/akonadi"
        expect_file "$R/etc/libreoffice"
        expect_call_line "rpm -qf /usr/lib64/libreoffice"
    else
        expect_action_line "rm -rf -- $R/usr/lib64/libreoffice"
        expect_action_line "rm -rf -- $R/usr/share/akonadi"
        expect_no_action_line "rm -rf -- $R/etc/libreoffice"
    fi
}

scenario removal_guard "dry live" "PIM removal would take plasma-workspace: PIM skipped, LibreOffice removed"
sc_removal_guard() {
    fx_add remove_extra 'kmail plasma-workspace sddm libfoo'
    invoke --yes --no-reboot
    expect_success
    expect_out 'Skipped removing KDE PIM: it would also remove core desktop packages \(plasma-workspace sddm\)'
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario office_guard "dry live" "LibreOffice removal would take plasma-desktop: its settings kept, PIM data deleted"
sc_office_guard() {
    fx_add remove_extra 'libreoffice-core plasma-desktop'
    invoke --yes --no-reboot
    expect_success
    expect_out 'Skipped removing LibreOffice: it would also remove core desktop packages \(plasma-desktop\)'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_no_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_deleted "$H" "${FX_PIM_JUNK[@]}"
    expect_kept "$H" "${FX_OFFICE_JUNK[@]}"
    expect_rm_count "$H" "${#FX_PIM_JUNK[@]}"
    expect_out_fixed "Kept LibreOffice settings in $H because LibreOffice is still installed"
}

scenario remove_fails "live" "dnf5 remove -y fails for KDE PIM: warning, PIM data kept, run completes"
sc_remove_fails() {
    fx_add fail '^dnf5 remove -y akonadi'
    invoke --yes --no-reboot
    expect_success
    expect_out 'Removing KDE PIM failed'
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario removal_guard_uninstalled "dry" "Protected name in the transaction but not installed: not counted"
sc_removal_guard_uninstalled() {
    fx_add remove_extra 'kmail plasma-login-manager'
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'core desktop packages'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
}

scenario removal_plan_error "dry live" "dnf5 can't plan the removal (lock error): both batches skipped"
sc_removal_plan_error() {
    fx_conf FKS_DNF_PLAN_ERROR=1
    invoke --yes --no-reboot
    expect_success
    expect_out "Skipped removing KDE PIM: dnf couldn't plan it \\(.*transaction lock"
    expect_out "Skipped removing LibreOffice: dnf couldn't plan it"
    expect_no_action '^dnf5 remove -y'
    expect_kept "$H" "${FX_JUNK[@]}"
    expect_rm_count "$H" 0
}

scenario kgpg_cascade_yes "dry live" "PIM removal would take kgpg (an app): skipped with --yes, LibreOffice removed"
sc_kgpg_cascade_yes() {
    fx_add remove_extra 'kmail kgpg'
    invoke --yes --no-reboot
    expect_success
    expect_out 'Removing KDE PIM also removes these apps, which use its libraries: kgpg$'
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    if is_live; then
        expect_out 'Skipped removing KDE PIM to keep those apps'
        expect_no_action "^dnf5 remove -y $PIM_SORTED$"
        expect_pim_data_kept
    else
        expect_out 'a real run asks before removing them, or skips with --yes'
        expect_action "^dnf5 remove -y $PIM_SORTED$"
        expect_home_cleaned "$H"
    fi
}

scenario kgpg_cascade_tty_yes "pty" "kgpg cascade on a terminal, answered y: PIM removed"
sc_kgpg_cascade_tty_yes() {
    fx_add remove_extra 'kmail kgpg'
    PTY_INPUT='y\ny\n'
    invoke --no-reboot
    expect_success
    expect_out 'Remove them too\? \[y/N\]'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_home_cleaned "$H"
}

scenario kgpg_cascade_tty_no "pty" "kgpg cascade on a terminal, answered n: PIM skipped"
sc_kgpg_cascade_tty_no() {
    fx_add remove_extra 'kmail kgpg'
    PTY_INPUT='y\nn\n'
    invoke --no-reboot
    expect_success
    expect_out 'Remove them too\? \[y/N\]'
    expect_out 'Skipped removing KDE PIM$'
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario pim_running "dry live" "PIM processes running: pkill (pattern and akonadi db) before removal"
sc_pim_running() {
    fx_conf FKS_PIM_RUNNING=1
    invoke --yes --no-reboot
    expect_success
    expect_action_line "pkill -u tester $PIM_PROC_RE"
    expect_action_line 'pkill -u tester -f akonadi/(mysql\.conf|db_data)'
    expect_order '^pkill -u tester' '^dnf5 remove -y'
    expect_no_call '^pgrep .* -f akonadi$'
}

scenario session_bus "dry live" "User session bus under FKS_ROOT/run/user: akonadictl stop + kbuildsycoca6"
sc_session_bus() {
    fx_session_bus
    local rt=$R/run/user/$FX_UID lang=C.UTF-8
    # kbuildsycoca6 gets the system locale (live: from etc/locale.conf; dry: default).
    if [[ $MODE == live ]]; then
        printf 'LANG="de_DE.UTF-8"\n' > "$R/etc/locale.conf"
        lang=de_DE.UTF-8
    fi
    invoke --yes --no-reboot
    expect_success
    expect_action_line "$(as_user_prefix) env XDG_RUNTIME_DIR=$rt DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus akonadictl stop"
    expect_action_line "$(as_user_prefix) env -u LC_ALL LANG=$lang XDG_RUNTIME_DIR=$rt DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus kbuildsycoca6 --noincremental"
    expect_no_action '^sudo' 
    expect_order 'akonadictl stop' '^dnf5 remove -y'
}

scenario user_junk "dry live" "Home cleanup deletes exactly the listed paths (symlink not followed)"
sc_user_junk() {
    invoke --yes --no-reboot
    expect_success
    expect_home_cleaned "$H"
}

# ---------------------------------------------------------------------------
# Flatpak, firmware, kernel modules

scenario flatpak_setup "dry live" "flatpak + Discover backend missing; unused Fedora remotes dropped"
sc_flatpak_setup() {
    fx_missing flatpak
    fx_del installed plasma-discover-flatpak
    : > "$S/flatpak_remotes"
    fx_add flatpak_remotes fedora fedora-testing flathub
    fx_add flatpak_origins fedora flathub
    invoke --yes --no-reboot
    expect_success
    expect_install flatpak
    expect_install plasma-discover-flatpak
    expect_order "$(pkg_re flatpak)" '^flatpak remote-add'
    expect_action '^flatpak remote-add --if-not-exists flathub '
    expect_no_action '^flatpak remote-delete --force fedora$'
    if is_live; then
        expect_action '^flatpak remote-delete --force fedora-testing$'
    fi
}

scenario fwupd_fail "dry live" "fwupd not installed, fwupdmgr update fails: warning only"
sc_fwupd_fail() {
    fx_missing fwupdmgr
    fx_conf FKS_FWUPD_RC=1
    invoke --yes --no-reboot
    expect_success
    expect_install fwupd
    expect_action '^fwupdmgr refresh --force$'
    if is_live; then expect_out 'fwupdmgr exited with 1'; fi
}

scenario kernel_update "live" "Upgrade pulls a new kernel: modules built for it"
sc_kernel_update() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf "FKS_UPGRADE_KERNEL=$NEW_KERNEL"
    invoke --yes --no-reboot
    expect_success
    expect_out "newest kernel: $NEW_KERNEL"
    expect_install "kernel-devel-$NEW_KERNEL"
    expect_action "^akmods --force --kernels $NEW_KERNEL$"
    expect_no_install "kernel-devel-$FX_KERNEL"
    expect_out 'A reboot is needed to load the new drivers'
}

scenario kernel_update_nokmod "live" "New kernel, no kmods: reboot reason is the kernel"
sc_kernel_update_nokmod() {
    fx_gpu_intel
    fx_conf "FKS_UPGRADE_KERNEL=$NEW_KERNEL"
    invoke --yes --no-reboot
    expect_success
    expect_out 'A reboot is needed to boot the new kernel'
}

scenario kmod_not_built "live" "akmods build fails: warning, run completes"
sc_kmod_not_built() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_MODS_BUILT=0
    invoke --yes --no-reboot
    expect_success
    expect_out "Kernel module 'nvidia' isn't built yet"
}

# ---------------------------------------------------------------------------
# Marker, confirmation, reboot

scenario marker_no_force "dry live" "Marker present, no --force: real run refuses, dry run warns"
sc_marker_no_force() {
    fx_marker "2025-05-05 10:00:00"
    invoke --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out 'Setup already completed on 2025-05-05 10:00:00. Use --force to run it again.'
        expect_grep "$R/var/lib/fedora-kde-setup/done" '^2025-05-05 10:00:00$'
    else
        expect_rc 0
        expect_out 'Setup already completed on 2025-05-05 10:00:00; a real run would need --force'
    fi
}

scenario marker_force "dry live" "Marker present with --force: runs, marker refreshed"
sc_marker_force() {
    fx_marker "2025-05-05 10:00:00"
    invoke --force --yes --no-reboot
    expect_rc 0
    expect_no_out 'already completed'
    if is_live; then
        expect_grep "$R/var/lib/fedora-kde-setup/done" '^2026-01-02 03:04:05$'
    else
        expect_grep "$R/var/lib/fedora-kde-setup/done" '^2025-05-05 10:00:00$'
    fi
}

scenario no_tty_no_yes "live" "No terminal and no --yes: abort before any change, tell user about --yes"
sc_no_tty_no_yes() {
    invoke --no-reboot
    expect_untouched
    expect_out 'No terminal to confirm on; re-run with --yes'
    expect_no_out 'No such device or address'
}

scenario tty_confirm_yes "pty" "Terminal: answer y, then accept the reboot default (stubbed systemctl)"
sc_tty_confirm_yes() {
    PTY_INPUT='y\n\n'
    EXPECT_REBOOT=1
    invoke
    expect_success
    expect_out 'Proceed\? \[y/N\]'
    expect_out 'Reboot now\? \[Y/n\]'
    expect_call '^systemctl reboot$'
}

scenario tty_confirm_no "pty" "Terminal: answer n, nothing changes"
sc_tty_confirm_no() {
    PTY_INPUT='n\n'
    invoke --no-reboot
    expect_untouched
    expect_out 'Aborted, nothing was changed'
}

scenario tty_no_reboot "pty" "Terminal + --no-reboot: no reboot prompt"
sc_tty_no_reboot() {
    PTY_INPUT='y\n'
    invoke --no-reboot
    expect_success
    expect_no_out 'Reboot now'
}

scenario assume_yes "live" "--yes without --no-reboot: never prompts or reboots"
sc_assume_yes() {
    invoke --yes
    expect_success
    expect_no_out 'Proceed\?'
    expect_no_out 'Reboot now'
    expect_out 'A reboot is needed'
}

# ---------------------------------------------------------------------------
# Target user

scenario root_no_user "dry live" "Root, no SUDO_USER, no --user: real run dies"
sc_root_no_user() {
    RUN_ENV=()
    invoke --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out "Can't tell which user to clean up"
    else
        expect_rc 0
        expect_out "cleaning up for user '(root|tester)'"
    fi
}

scenario sudo_user_root "live" "SUDO_USER=root (sudo from a root shell): real run dies"
sc_sudo_user_root() {
    RUN_ENV=(SUDO_USER=root)
    invoke --yes --no-reboot
    expect_untouched
    expect_out "Can't tell which user to clean up"
}

scenario user_root "dry live" "--user root: real run refuses, dry run warns"
sc_user_root() {
    invoke --user root --yes --no-reboot
    expect_out "Refusing to clean root's home"
    if is_live; then expect_untouched; else expect_rc 0; fi
}

scenario pkexec_root "live" "PKEXEC_UID=0 resolves to root: refused"
sc_pkexec_root() {
    RUN_ENV=(PKEXEC_UID=0)
    invoke --yes --no-reboot
    expect_untouched
    expect_out "Refusing to clean root's home"
}

scenario pkexec_uid "dry live" "pkexec: PKEXEC_UID picks the user"
sc_pkexec_uid() {
    RUN_ENV=("PKEXEC_UID=$FX_UID")
    invoke --yes --no-reboot
    expect_success
    expect_out "cleaning up for user 'tester'"
    expect_home_cleaned "$H"
}

scenario user_option "dry live" "--user tester overrides SUDO_USER=alice; alice's home untouched"
sc_user_option() {
    RUN_ENV=(SUDO_USER=alice)
    fx_home_junk "$T/home/alice"
    invoke --user tester --yes --no-reboot
    expect_success
    expect_out "cleaning up for user 'tester'"
    expect_home_cleaned "$H"
    expect_home_intact "$T/home/alice"
    expect_no_action "home/alice"
}

scenario user_eq_form "dry" "--user=tester form"
sc_user_eq_form() {
    RUN_ENV=(SUDO_USER=alice)
    invoke --user=tester --yes
    expect_success
    expect_out "cleaning up for user 'tester'"
}

scenario user_unknown "dry live" "--user ghost: real run dies, dry run warns and skips user data"
sc_user_unknown() {
    invoke --user ghost --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out "User 'ghost' doesn't exist"
    else
        expect_rc 0
        expect_out "\\(dry-run\\) User 'ghost' doesn't exist"
        expect_out "No home directory for 'ghost'; skipped deleting PIM/LibreOffice user data"
        expect_out 'Dry run finished'
    fi
}

scenario user_needs_name "dry" "--user without a name is rejected"
sc_user_needs_name() {
    EXPECT_NO_LOG=1
    invoke --user
    expect_rc nonzero
    expect_out 'needs a name'
    expect_no_dnf
}

# ---------------------------------------------------------------------------
# Preflight and command line

scenario non_fedora "dry live" "Ubuntu os-release: real run dies, dry run warns"
sc_non_fedora() {
    fx_os_release ID=ubuntu VERSION_ID=24.04 'PRETTY_NAME="Ubuntu 24.04 LTS"'
    invoke --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out 'This script is for Fedora \(found: ubuntu\)'
    else
        expect_rc 0
        expect_out '\(dry-run\) This script is for Fedora \(found: ubuntu\)'
    fi
}

scenario fedora_atomic "dry live" "Fedora Kinoite (ostree-booted): real run dies"
sc_fedora_atomic() {
    touch "$R/run/ostree-booted"
    invoke --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out 'Fedora Atomic \(Kinoite\) uses rpm-ostree'
    else
        expect_rc 0
        expect_out '\(dry-run\) Fedora Atomic'
    fi
}

scenario no_os_release "dry live" "No /etc/os-release: real run dies, dry run only warns"
sc_no_os_release() {
    rm -f "$R/etc/os-release"
    invoke --yes --no-reboot
    expect_out 'etc/os-release not found'
    if is_live; then expect_untouched; else expect_rc 0; expect_out 'Dry run finished'; fi
}

scenario non_kde "dry live" "Not Fedora KDE (Workstation, no plasma-workspace): refused; KDE installed later: allowed"
sc_non_kde() {
    fx_os_release ID=fedora VERSION_ID=41 VARIANT_ID=workstation 'PRETTY_NAME="Fedora Linux 41 (Workstation Edition)"'
    fx_del installed plasma-workspace
    invoke --yes --no-reboot
    expect_out_fixed "This isn't Fedora KDE Plasma (VARIANT_ID=workstation, plasma-workspace not installed)"
    if is_live; then
        expect_untouched
    else
        expect_rc 0
        expect_out '\(dry-run\) This isn.t Fedora KDE Plasma'
    fi
    # Workstation with Plasma added on top is fine.
    fx_add installed plasma-workspace
    invoke --yes --no-reboot
    expect_rc 0
    expect_no_out "isn't Fedora KDE"
}

scenario offline "dry live" "RPM Fusion unreachable: real run dies, dry run warns"
sc_offline() {
    fx_conf FKS_OFFLINE=1
    invoke --yes --no-reboot
    expect_out "Can't download https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-41.noarch.rpm"
    expect_call_line "$CURL_HEAD $(rf_url free 41)"
    expect_call_line "$CURL_HEAD $(rf_url free 41 download1.rpmfusion.org)"
    if is_live; then expect_untouched; else expect_rc 0; fi
}

scenario preflight_mirror_fallback "dry live" "Mirror redirector unreachable, download1 reachable: continues"
sc_preflight_mirror_fallback() {
    fx_conf 'FKS_HEAD_FAIL_RE=^https://mirrors\.rpmfusion\.org/'
    invoke --yes --no-reboot
    expect_success
    expect_call_line "$CURL_HEAD $(rf_url free 41 download1.rpmfusion.org)"
    expect_no_out "Can't download"
}

scenario not_root "user" "Unprivileged: real run refuses, dry run works and logs to TMPDIR"
sc_not_root() {
    invoke --yes --no-reboot
    expect_untouched
    expect_out 'Run this with sudo'
    invoke --dry-run --yes
    expect_rc 0
    expect_out '\(dry-run\) Run this with sudo'
    check "log written to a mktemp file TMPDIR/fedora-kde-setup.XXXXXX.log" compgen -G "$T/tmp/fedora-kde-setup.??????.log"
}

scenario help "dry" "--help prints usage (also when piped) and does nothing"
sc_help() {
    EXPECT_NO_LOG=1
    invoke --help
    expect_rc 0
    expect_out '^Usage: sudo \./fedora-kde-setup\.sh \[options\]$'
    expect_out '--dry-run'
    expect_out '-V, --version'
    check "no command called" not test -s "$CALLS"
}

scenario version "dry" "-V prints the version"
sc_version() {
    EXPECT_NO_LOG=1
    invoke -V
    expect_rc 0
    expect_out '^fedora-kde-setup 1\.0\.0$'
    check "no command called" not test -s "$CALLS"
}

scenario bad_option "dry" "Unknown option is rejected"
sc_bad_option() {
    EXPECT_NO_LOG=1
    invoke --bogus
    expect_rc nonzero
    expect_out 'Unknown option: --bogus'
    expect_no_dnf
}

# ---------------------------------------------------------------------------
# dnf.conf editing

dnfconf_keys_once() {
    local f=$R/etc/dnf/dnf.conf
    expect_count "$f" '^\[main\]$' 1
    expect_count "$f" '^[[:space:]]*fastestmirror[[:space:]]*=' 1
    expect_count "$f" '^[[:space:]]*max_parallel_downloads[[:space:]]*=' 1
    expect_count "$f" '^[[:space:]]*defaultyes[[:space:]]*=' 1
    expect_count "$f" '^fastestmirror=True$' 1
    expect_count "$f" '^max_parallel_downloads=10$' 1
    expect_count "$f" '^defaultyes=True$' 1
    check "dnf.conf: [main] is the first line" test "$(head -n1 "$f")" == "[main]"
}

scenario dnfconf_idempotent "dry live" "dnf.conf: values replaced in place, second run changes nothing"
sc_dnfconf_idempotent() {
    local f=$R/etc/dnf/dnf.conf
    printf '[main]\ngpgcheck=True\n  fastestmirror = False\nmax_parallel_downloads=3\nbest=False\n' > "$f"
    invoke --yes --no-reboot
    if ! is_live; then
        expect_action_line "set fastestmirror=True in $f"
        expect_action_line "set max_parallel_downloads=10 in $f"
        expect_action_line "set defaultyes=True in $f"
        return 0
    fi
    expect_rc 0
    dnfconf_keys_once
    expect_count "$f" '^gpgcheck=True$' 1
    expect_count "$f" '^best=False$' 1
    cp "$f" "$T/dnf.conf.first"
    invoke --force --yes --no-reboot
    expect_rc 0
    check "dnf.conf identical after a second run" cmp -s "$f" "$T/dnf.conf.first"
}

scenario dnfconf_missing "live" "dnf.conf and /etc/dnf missing: created with [main] and the keys"
sc_dnfconf_missing() {
    rm -rf "$R/etc/dnf"
    invoke --yes --no-reboot
    expect_rc 0
    dnfconf_keys_once
}

scenario dnfconf_empty "live" "dnf.conf empty: [main] and the keys added"
sc_dnfconf_empty() {
    : > "$R/etc/dnf/dnf.conf"
    invoke --yes --no-reboot
    expect_rc 0
    dnfconf_keys_once
}

scenario dnfconf_no_main "live" "dnf.conf without [main] and without a final newline"
sc_dnfconf_no_main() {
    printf 'gpgcheck=True' > "$R/etc/dnf/dnf.conf"
    invoke --yes --no-reboot
    expect_rc 0
    dnfconf_keys_once
    expect_count "$R/etc/dnf/dnf.conf" '^gpgcheck=True$' 1
}

# ---------------------------------------------------------------------------
# Safety rails (preflight)

rail_refused() {  # MESSAGE_REGEX: real run dies before any change, dry run only warns
    if is_live; then
        expect_untouched
        expect_out "xx $1"
    else
        expect_rc 0
        expect_out "\\(dry-run\\) $1"
        expect_out 'Dry run finished'
    fi
}

scenario rails_arch "dry live" "aarch64: refused"
sc_rails_arch() {
    fx_conf FKS_ARCH=aarch64
    invoke --yes --no-reboot
    rail_refused 'This script supports x86_64 only \(found: aarch64\)'
}

scenario rails_low_root "dry live" "2 GiB free on /: refused"
sc_rails_low_root() {
    fx_conf FKS_DF_ROOT=2048
    invoke --yes --no-reboot
    rail_refused 'Only 2048 MiB free on /; need at least 6144 MiB'
    expect_call_line "df -Pm -- $R/"
}

scenario rails_low_var "live" "100 MiB free on /var: refused"
sc_rails_low_var() {
    fx_conf FKS_DF_VAR=100
    invoke --yes --no-reboot
    rail_refused 'Only 100 MiB free on /var; need at least 6144 MiB'
}

scenario rails_low_boot "dry live" "120 MiB free on /boot: refused"
sc_rails_low_boot() {
    fx_conf FKS_DF_BOOT=120
    invoke --yes --no-reboot
    rail_refused 'Only 120 MiB free on /boot; need at least 300 MiB'
    expect_call_line "df -Pm -- $R/boot"
}

scenario rails_boot_exact "live" "Exactly 300 MiB on /boot and 6144 MiB on /: allowed"
sc_rails_boot_exact() {
    fx_conf FKS_DF_BOOT=300 FKS_DF_ROOT=6144 FKS_DF_VAR=6144
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'MiB free on'
}

scenario rails_df_fails "live" "df fails for every path: free space unknown, check skipped"
sc_rails_df_fails() {
    fx_conf FKS_DF_ROOT= FKS_DF_VAR= FKS_DF_BOOT=
    invoke --yes --no-reboot
    expect_success
    expect_call '^df -Pm -- '
    expect_no_out 'MiB free on'
}

scenario rails_on_battery "dry live" "Laptop, charger unplugged (AC online=0): refused"
sc_rails_on_battery() {
    fx_battery Discharging 0
    invoke --yes --no-reboot
    rail_refused 'Running on battery. Plug in the charger first'
}

scenario rails_battery_only_discharging "live" "Battery, no AC supply reported, Discharging: refused"
sc_rails_battery_only_discharging() {
    fx_supply BAT0 Battery status=Discharging
    invoke --yes --no-reboot
    rail_refused 'Running on battery'
}

scenario rails_battery_only_full "live" "Battery, no AC supply reported, Full: allowed"
sc_rails_battery_only_full() {
    fx_supply BAT0 Battery status=Full
    invoke --yes --no-reboot
    expect_success
    expect_out 'Form factor +laptop'
    expect_no_out 'Running on battery'
}

scenario rails_usb_c_power "live" "Mains offline but a USB-C supply online: on AC, allowed"
sc_rails_usb_c_power() {
    fx_battery Charging 0
    fx_supply ucsi-source-psy-USBC000:001 USB online=1
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'Running on battery'
}

scenario rails_rpmdb "dry live" "rpm -q rpm fails (broken RPM database): refused"
sc_rails_rpmdb() {
    fx_del installed rpm
    invoke --yes --no-reboot
    rail_refused "The RPM database doesn't respond"
}

scenario rails_pkgmgr_running "dry live" "dnf already running (pgrep -x finds it): refused"
sc_rails_pkgmgr_running() {
    fx_conf FKS_PKG_MGR_RUNNING=1
    invoke --yes --no-reboot
    rail_refused 'Another package manager \(dnf/rpm\) is running'
}

scenario rails_order "live" "Rails run after the user checks and before the lock"
sc_rails_order() {
    fx_conf FKS_ARCH=aarch64
    hold_lock
    invoke --yes --no-reboot
    release_lock
    expect_untouched
    expect_out 'supports x86_64 only'
    expect_no_out 'Another run of this script'
    expect_order '^getent passwd tester' '^uname -m'
}

scenario user_bad_name "dry live" "--user 'Bad;Name': invalid user name refused"
sc_user_bad_name() {
    invoke --user 'Bad;Name' --yes --no-reboot
    expect_out_fixed "'Bad;Name' isn't a valid user name"
    expect_no_call 'Bad;Name'
    if is_live; then
        expect_untouched
    else
        expect_rc 0
        expect_out 'skipped deleting PIM/LibreOffice user data'
    fi
}

scenario user_system "dry live" "--user daemon (UID 2): system account refused"
sc_user_system() {
    invoke --user daemon --yes --no-reboot
    expect_out_fixed "'daemon' is a system account (UID 2); pass the desktop user with --user NAME"
    if is_live; then expect_untouched; else expect_rc 0; fi
}

# ---------------------------------------------------------------------------
# RPM Fusion bootstrap

rf_refused() {  # MESSAGE: dies after the upgrade, before installing the release packages
    expect_rc nonzero
    expect_out_fixed "$1"
    expect_no_action '^dnf5 install -y .*/rpmfusion-'
    expect_no_action 'appstream-data|ffmpeg'
    expect_no_file "$R/var/lib/fedora-kde-setup/done"
    expect_call '^systemctl unmask --runtime packagekit.service$'
}

scenario rf_verified "dry live" "Release packages downloaded over HTTPS, signatures checked, installed from local files"
sc_rf_verified() {
    invoke --yes --no-reboot
    expect_success
    expect_rpmfusion 41
    if is_live; then
        expect_order '^rpmkeys --import' '^curl .* -fsSL '
        expect_no_call 'download1\.rpmfusion\.org'
    fi
}

scenario rf_partial "live" "Only rpmfusion-nonfree-release missing: just that one bootstrapped"
sc_rf_partial() {
    fx_add installed rpmfusion-free-release
    invoke --yes --no-reboot
    expect_success
    expect_rpmfusion 41 nonfree
    expect_no_call '^curl .* -fsSL .*rpmfusion-free-release'
    expect_no_call '^rpmkeys .*rpmfusion-free-'
}

scenario rf_gpgkeys_missing "dry live" "distribution-gpg-keys not installed: installed first, without --skip-unavailable"
sc_rf_gpgkeys_missing() {
    fx_del installed distribution-gpg-keys
    invoke --yes --no-reboot
    expect_success
    expect_action '^dnf5 install -y distribution-gpg-keys$'
    expect_order '^dnf5 install -y distribution-gpg-keys$' '^rpmkeys --import'
}

scenario rf_bad_signature "live" "rpmkeys --checksig: SIGNATURES NOT OK: dies, nothing installed"
sc_rf_bad_signature() {
    fx_conf FKS_CHECKSIG=bad
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package, refusing to install it'
    expect_out 'digests SIGNATURES NOT OK'
}

scenario rf_unsigned "live" "rpmkeys --checksig: digests OK but no signature: dies"
sc_rf_unsigned() {
    fx_conf FKS_CHECKSIG=unsigned
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_no_key "live" "RPM Fusion key missing from distribution-gpg-keys: dies before downloading"
sc_rf_no_key() {
    rm -f "$(rf_key free 41)"
    invoke --yes --no-reboot
    rf_refused "RPM Fusion's signing key for Fedora 41 isn't in distribution-gpg-keys ($R/usr/share/distribution-gpg-keys/rpmfusion)"
    expect_no_call '^curl .* -fsSL '
}

scenario rf_key_latest "live" "Only the -latest RPM Fusion keys exist: used as fallback"
sc_rf_key_latest() {
    local repo
    for repo in free nonfree; do
        rm -f "$(rf_key "$repo" 41)"
        echo "stub key" > "$(rf_key "$repo" latest)"
    done
    invoke --yes --no-reboot
    expect_success
    expect_call_line "rpmkeys --import $(rf_key free latest)"
    expect_call_line "rpmkeys --import $(rf_key nonfree latest)"
    expect_action '^dnf5 install -y .*/rpmfusion-free-release\.noarch\.rpm .*/rpmfusion-nonfree-release\.noarch\.rpm$'
}

scenario rf_mirror_fallback "live" "mirrors.rpmfusion.org download fails: download1.rpmfusion.org used"
sc_rf_mirror_fallback() {
    fx_conf 'FKS_CURL_FAIL_RE=^https://mirrors\.rpmfusion\.org/'
    invoke --yes --no-reboot
    expect_success
    expect_call "^$(re_quote "$CURL_GET") .* $(re_quote "$(rf_url free 41 download1.rpmfusion.org)")$"
    expect_call "^$(re_quote "$CURL_GET") .* $(re_quote "$(rf_url nonfree 41 download1.rpmfusion.org)")$"
    expect_action '^dnf5 install -y .*/rpmfusion-free-release\.noarch\.rpm .*/rpmfusion-nonfree-release\.noarch\.rpm$'
}

scenario rf_download_fails "live" "Both RPM Fusion hosts fail: dies"
sc_rf_download_fails() {
    fx_conf 'FKS_CURL_FAIL_RE=rpmfusion\.org/'
    invoke --yes --no-reboot
    rf_refused "Couldn't download the RPM Fusion free release package"
}

# ---------------------------------------------------------------------------
# Undo information, environment hardening

scenario history_empty "live" "Empty dnf history: undo hint says after #0"
sc_history_empty() {
    fx_conf FKS_HISTORY_LAST=
    invoke --yes --no-reboot
    expect_success
    expect_out_fixed '(this run: transactions after #0);'
    expect_out_fixed 'undo one with "sudo dnf history undo <ID>".'
}

scenario history_dry "dry" "Dry run prints no undo hint"
sc_history_dry() {
    invoke --yes
    expect_success
    expect_no_out 'dnf history list'
}

# Without FKS_ROOT the script must replace the caller's PATH with /usr/sbin:/usr/bin.
# Only --help is run that way: it exits after printing usage with "cat", before any
# other command. A decoy "cat" (a logging stub) heads the caller's PATH; the real cat
# must be used. A control run with FKS_ROOT set must use the decoy.
scenario path_reset "dry" "No FKS_ROOT: caller's PATH replaced (proved with --help and a decoy cat)"
sc_path_reset() {
    local fake=$T/decoy-bin
    mkdir -p "$fake"
    ln -s "$FKS_LIB/stub" "$fake/cat"
    : > "$CALLS"
    ( cd "$T/cwd" && "$SETSID_BIN" -w "$ENV_BIN" -i "PATH=$fake:$SAFEBIN" "FKS_STATE=$S" \
        "FKS_CALLS=$CALLS" LANG=C "$BASH_BIN" "$SCRIPT" --help ) </dev/null > "$OUT" 2>&1
    RC=$?
    expect_rc 0
    expect_out '^Usage: sudo \./fedora-kde-setup\.sh \[options\]$'
    check "caller's PATH not used (decoy cat not called)" not test -s "$CALLS"

    ( cd "$T/cwd" && "$SETSID_BIN" -w "$ENV_BIN" -i "PATH=$fake:$SAFEBIN" "FKS_STATE=$S" \
        "FKS_CALLS=$CALLS" "FKS_ROOT=$R" LANG=C "$BASH_BIN" "$SCRIPT" --help ) </dev/null > "$OUT" 2>&1
    RC=$?
    expect_call '^cat$'
    expect_out "no behaviour defined for 'cat'"
}

# ---------------------------------------------------------------------------
# Test-mode guard, stricter signature checks

scenario fks_root_world_writable "live" "Root run with a world-writable FKS_ROOT: refused before anything runs"
sc_fks_root_world_writable() {
    KEEP_ROOT_OWNER=1 EXPECT_NO_LOG=1
    "${ROOTCMD[@]}" chown 0:0 "$R"
    "${ROOTCMD[@]}" chmod 0777 "$R"
    invoke --yes --no-reboot
    expect_rc 1
    expect_out_fixed 'FKS_ROOT is a test-only setting and must be a root-owned directory nobody else can write to.'
    expect_no_out 'TEST MODE'
    check "no command called" not test -s "$CALLS"
    "${ROOTCMD[@]}" chmod 0755 "$R"
}

scenario fks_root_not_root_owned "live" "Root run with an FKS_ROOT owned by another user: refused"
sc_fks_root_not_root_owned() {
    KEEP_ROOT_OWNER=1 EXPECT_NO_LOG=1
    "${ROOTCMD[@]}" chown 65534:65534 "$R"
    "${ROOTCMD[@]}" chmod 0755 "$R"
    invoke --yes --no-reboot
    expect_rc 1
    expect_out_fixed 'must be a root-owned directory nobody else can write to'
    check "no command called" not test -s "$CALLS"
}

scenario fks_root_test_banner "live" "Accepted FKS_ROOT: TEST MODE banner on stderr"
sc_fks_root_test_banner() {
    invoke --yes --no-reboot
    expect_success
    expect_out_fixed "TEST MODE: FKS_ROOT=$R"
}

scenario rf_sig_not_exact "live" "checksig output has 'signatures OK' only inside a path: dies"
sc_rf_sig_not_exact() {
    fx_conf FKS_CHECKSIG=notexact
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_sig_rc "live" "checksig prints 'digests signatures OK' but exits non-zero: dies"
sc_rf_sig_rc() {
    fx_conf FKS_CHECKSIG=okfail
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_wrong_package "live" "Signed file is another package (rpm -qp name mismatch): dies"
sc_rf_wrong_package() {
    fx_conf FKS_RPM_QP_NAME=evil-package
    invoke --yes --no-reboot
    rf_refused "The downloaded file isn't the rpmfusion-free-release package, refusing to install it"
}

scenario mok_rootdir_kept "live" "Existing /root (0755) is not re-moded when the MOK hash is written"
sc_mok_rootdir_kept() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    mkdir -p "$R/root"
    chmod 0755 "$R/root"
    invoke --yes --no-reboot
    expect_success
    check "existing FKS_ROOT/root keeps mode 755" test "$("${ROOTCMD[@]}" stat -c %a "$R/root")" = 755
    expect_out 'MOK one-time password: a1b2c3d4'
}

scenario user_valid_names "dry" "User names John, 2bob and .anna are accepted"
sc_user_valid_names() {
    local u
    for u in John 2bob .anna; do
        invoke --user "$u" --yes
        expect_rc 0
        expect_no_out "isn't a valid user name"
        expect_out_fixed "cleaning up for user '$u'"
    done
}

scenario user_digits "dry live" "All-digit user name '123': rejected"
sc_user_digits() {
    invoke --user 123 --yes --no-reboot
    expect_out_fixed "'123' isn't a valid user name"
    if is_live; then expect_untouched; else expect_rc 0; fi
}
