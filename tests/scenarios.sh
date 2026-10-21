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

readonly STATE=fedora-kde-setup/done
state_file() { printf '%s' "$R/var/lib/$STATE"; }
readonly STEP_IDS_RE='(dnf|update|codecs|drivers|pim|libreoffice|flathub|firmware|maintenance)'

# Finished steps are recorded as "ID DATE" lines; the summary ends with a 100% line.
expect_success() {
    expect_rc 0
    expect_out 'All [0-9]+ steps? finished\.|[0-9]+ of [0-9]+ steps finished; [0-9]+ needs? attention \(see below\)\.'
    if is_live; then
        check "state file has only 'ID DATE' lines" \
            not grep -Evq "^$STEP_IDS_RE [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}$" "$(state_file)"
        if grep -q '^dnf ' "$(state_file)" 2>/dev/null; then
            expect_count "$R/etc/dnf/dnf.conf" '^fastestmirror=True$' 1
        fi
        if grep -q '^maintenance ' "$(state_file)" 2>/dev/null; then
            expect_grep "$R/etc/systemd/journald.conf.d/00-size.conf" '^SystemMaxUse=500M$'
        fi
    else
        expect_out 'Dry run finished; nothing was changed'
        expect_no_file "$(state_file)"
    fi
}

expect_recorded()     { check "step '$1' recorded as done" grep -q "^$1 2026-01-02 03:04:05$" "$(state_file)"; }
expect_not_recorded() { check "step '$1' not recorded" not grep -qs "^$1 2026-01-02" "$(state_file)"; }

# The review list printed before running ("Ready to start N steps ...:").
will_do() {
    awk '/^  Ready to start [0-9]+ steps?/ { f = 1; seen = 0; next }
         f && /^$/ { if (seen) f = 0; next }
         f { seen = 1; print }' "$OUT"
}
readonly START_YES='|WAIT:Start these|y\n' START_NO='|WAIT:Start these|n\n'
readonly ALL_AND_REMOVALS='dnf,update,codecs,flathub,firmware,maintenance,pim,libreoffice'
# Steps marker on the screen before which something must have happened.
expect_out_before() {  # RE1 RE2: first output line matching RE1 comes before RE2's
    check "output /$1/ comes before /$2/" \
        test "$(first_line "$1" "$OUT")" -lt "$(first_line "$2" "$OUT")"
}
expect_will_do()    { check "Will do lists '$1'" grep -Fq -- "$1" <(will_do); }
expect_no_will_do() { check "Will do doesn't list '$1'" not grep -Fq -- "$1" <(will_do); }

pkg_change_calls() {
    grep -v -- --assumeno "$CALLS" | grep -Eq '^dnf5? ([^ ]+ )*(install|remove|upgrade|swap|config-manager|group)( |$)'
}
expect_no_pkg_change() {  # planning with --assumeno is fine
    check "no package-changing dnf call" not pkg_change_calls
}

expect_untouched() {  # a run that must stop before changing anything
    expect_rc nonzero
    expect_no_pkg_change
    expect_no_call '^systemctl (mask|stop|enable|restart)'
    check "no step recorded" not grep -qs '2026-01-02 03:04:05' "$(state_file)"
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

expect_rm_count() {  # HOME N: exactly N deletions under HOME
    local n
    n=$(grep -cF -- "rm -rf -- $1/" "$T/actions")
    check "exactly $2 deletions under the home (found $n)" test "$n" -eq "$2"
}

expect_suite_deleted() {  # HOME LABEL N: the step's summary line
    expect_out_fixed "Deleted $3 $2 data and settings entries from $1"
}

expect_home_cleaned() {  # HOME
    expect_deleted "$1" "${FX_JUNK[@]}"
    expect_kept "$1" "${FX_DECOYS[@]}"
    expect_file "$T/outside/lo-profile/registrymodifications.xcu"
    expect_rm_count "$1" "${#FX_JUNK[@]}"
    expect_suite_deleted "$1" "KDE PIM" "${#FX_PIM_JUNK[@]}"
    expect_suite_deleted "$1" LibreOffice "${#FX_OFFICE_JUNK[@]}"
}

expect_pim_data_kept() {  # PIM not removed (unselected or failed), LibreOffice removed
    expect_kept "$H" "${FX_PIM_JUNK[@]}"
    expect_deleted "$H" "${FX_OFFICE_JUNK[@]}"
    expect_rm_count "$H" "${#FX_OFFICE_JUNK[@]}"
    expect_suite_deleted "$H" LibreOffice "${#FX_OFFICE_JUNK[@]}"
    if is_live; then expect_not_recorded pim; fi
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
    invoke --only "$ALL_AND_REMOVALS" --yes --no-reboot
    expect_success
    expect_out 'Form factor +laptop'
    expect_out 'Secure Boot +disabled'
    expect_out 'GPU\(s\) +Intel Corporation Alder Lake-P GT2'
    expect_call_line "$CURL_HEAD $(rf_url free 41)"
    expect_call_line "$CURL_HEAD https://mirrors.fedoraproject.org/"
    expect_call_line "$CURL_HEAD https://dl.flathub.org/repo/flathub.flatpakrepo"
    local t
    for t in "Faster DNF downloads" "Full system update" "Media codecs and video acceleration" \
        "Remove KDE PIM (KMail, Kontact, KOrganizer...)" "Remove LibreOffice" \
        "Flathub as Discover's app store" "Firmware updates" "SSD trim + smaller system logs"; do
        expect_will_do "$t"
    done
    expect_no_will_do 'Drivers'
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
    expect_action '^flatpak remote-modify --prio=10 flathub$'
    expect_action '^flatpak remote-modify --disable fedora$'
    expect_no_action 'remote-delete'
    expect_action_line "$(as_user_prefix) kwriteconfig6 --file $H/.config/discoverrc --group ResourcesModel --key currentApplicationBackend flatpak-backend"
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
        expect_out_fixed 'A reboot is recommended so updated system services and libraries are used.'
        expect_grep "$H/.config/discoverrc" '^currentApplicationBackend=flatpak-backend$'
        local id
        for id in dnf update codecs pim libreoffice flathub firmware maintenance; do expect_recorded "$id"; done
        expect_not_recorded drivers
        expect_out 'All 8 steps finished\.'
        expect_out '^  ✔ Step 8 of 8 done'
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
    expect_will_do 'Drivers: NVIDIA GeForce RTX 2060 Rev. A'
    expect_nvidia "$NV_CURRENT_PKGS"
    expect_no_call 'repoquery'
    expect_no_action '^kmodgenca'
    expect_no_action 'mokutil --import'
    expect_no_out 'Secure Boot: create'
    if is_live; then
        expect_call '^systemctl cat nvidia-fallback.service$'
        expect_out "Kernel module 'nvidia' built for $FX_KERNEL"
        expect_out 'A reboot is recommended'
        expect_recorded drivers
    fi
}

scenario nvidia_no_lspci "dry live" "No lspci: NVIDIA RTX 4060 still classified by device ID"
sc_nvidia_no_lspci() {
    fx_missing lspci
    fx_gpu_nvidia "${NV_AD107[@]}"
    invoke --yes --no-reboot
    expect_success
    expect_out 'GPU\(s\) +vendor 0x10de device 0x28e0'
    expect_will_do 'Drivers: NVIDIA vendor 0x10de device 0x28e0'
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
    expect_no_out 'to load the new drivers'
    expect_not_recorded drivers
    expect_out 'Not completed \(see warnings\):'
}

scenario nvidia_turing_sb "dry pty" "Secure Boot on, terminal, no --yes: kmodgenca + interactive MOK import before akmod-nvidia"
sc_nvidia_turing_sb() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    if [[ $MODE == pty ]]; then
        PTY_INPUT=$START_YES
        invoke --no-reboot
    else
        invoke --yes --no-reboot
    fi
    expect_success
    expect_out 'Secure Boot +enabled'
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
        # The password is asked before the long part starts.
        expect_out_before '^== Secure Boot key \(before the long part\)$' 'Step 1 of'
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
    expect_out_fixed 'Type the one-time password you set when the key was first queued (forgot it? sudo mokutil --revoke-import, then run the script again and pick the drivers step)'
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
    expect_not_recorded drivers
}

scenario nvidia_sb_tty_fails "pty" "MOK import fails 3 times on a terminal: driver skipped"
sc_nvidia_sb_tty_fails() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled FKS_MOK_IMPORT_RC=1
    PTY_INPUT=$START_YES
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
    expect_not_recorded drivers
    expect_out 'Not completed \(see warnings\):'
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
    expect_will_do 'Drivers: NVIDIA GeForce GTX 1080'
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
    expect_will_do 'Drivers: NVIDIA GeForce GTX 1080'
    expect_nvidia "$NV_580XX_PKGS"
}

scenario kepler "dry live" "GT 710 (Kepler 0x128b), Secure Boot on: no driver, no key, warning"
sc_kepler() {
    fx_gpu_nvidia "${NV_GK208[@]}"
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    expect_no_will_do 'Drivers'
    expect_no_kmods
}

scenario nforce_igp "dry live" "GeForce 9400M nForce IGP (0x0863): unsupported, nouveau kept"
sc_nforce_igp() {
    fx_gpu_nvidia "${NV_MCP79[@]}" 0x030000 0000:00:10.0
    invoke --yes --no-reboot
    expect_success
    expect_no_will_do 'Drivers'
    expect_no_kmods
}

scenario broadcom_wl "dry live" "BCM4360 (0x43a0) on bcma, no wiphy: broadcom-wl + akmods"
sc_broadcom_wl() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0 bcma
    invoke --yes --no-reboot
    expect_success
    expect_will_do 'Drivers: Broadcom Wi-Fi'
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
    expect_no_will_do 'Drivers'
    expect_no_kmods
}

scenario broadcom_phy_direct "dry live" "BCM4360 with ieee80211/phy0 directly under the (symlinked) PCI device: no wl"
sc_broadcom_phy_direct() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0 brcmsmac
    fx_wifi_phy 0000:02:00.0
    invoke --yes --no-reboot
    expect_success
    check "fixture: sysfs device entry is a symlink" test -L "$R/sys/bus/pci/devices/0000:02:00.0"
    expect_no_will_do 'Drivers'
    expect_no_kmods
}

scenario broadcom_brcmfmac "dry live" "BCM4350 (0x43a3, brcmfmac chip) unbound: not a wl chip, no wl"
sc_broadcom_brcmfmac() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a3
    invoke --yes --no-reboot
    expect_success
    expect_no_will_do 'Drivers'
    expect_no_kmods
}

scenario broadcom_sb "dry" "Broadcom wl with Secure Boot on: MOK import before broadcom-wl"
sc_broadcom_sb() {
    fx_gpu_intel; fx_wifi_broadcom 0x43a0
    fx_conf FKS_SB=enabled
    invoke --yes --no-reboot
    expect_success
    expect_will_do 'Drivers: Broadcom Wi-Fi'
    expect_order '^mokutil --import' "$(pkg_re broadcom-wl)"
}

vm_case() {  # VIRT EXPECTED_PKG...
    fx_conf "FKS_VIRT=$1" FKS_SB=enabled
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_wifi_broadcom 0x43a0
    invoke --yes --no-reboot
    expect_success
    expect_out "Virtual +$1$"
    expect_will_do "Guest tools for this virtual machine ($1)"
    expect_no_will_do 'Firmware updates'
    local pkg
    for pkg in "${@:2}"; do expect_install "$pkg"; done
    expect_no_kmods
    expect_no_action '^fwupdmgr'
    expect_no_install fwupd
    expect_action '^systemctl mask --runtime packagekit.service$'
    if is_live; then expect_recorded drivers; expect_not_recorded firmware; fi
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
    expect_no_will_do 'Drivers'
    expect_no_will_do 'Guest tools'
    expect_no_kmods
}

container_checks() {
    expect_success
    expect_out 'Virtual +container$'
    expect_no_will_do 'Drivers'
    expect_no_will_do 'Firmware updates'
    expect_out 'Container: skipping systemctl'
    expect_no_action '^systemctl'
    expect_no_call '^systemctl (mask|unmask|stop|enable|restart|reboot)'
    expect_no_kmods
    expect_no_action 'guest-agent|open-vm-tools|hyperv-daemons|virtualbox-guest'
    expect_no_action '^fwupdmgr'
    expect_no_call '^pkcon'
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
    PTY_INPUT=$START_YES
    invoke
    expect_success
    expect_out 'Start these [0-9]+ steps? now\? \[y/N\]'
    expect_no_out 'Reboot now'
    expect_no_call '^systemctl (mask|unmask|stop|enable|restart|reboot)'
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

scenario pk_offline_not_update "dry live" "Staged offline update, update step not selected: left alone"
sc_pk_offline_not_update() {
    ln -s /var/lib/PackageKit/prepared-update "$R/system-update"
    invoke --only codecs --yes --no-reboot
    expect_success
    expect_no_action '^pkcon offline-cancel'
    expect_no_action "rm -f $R/system-update"
    expect_file "$R/system-update"
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
    expect_out_fixed 'Error: this command failed (exit code 1): dnf5 upgrade --refresh -y'
    expect_no_out 'for bug reports'
    check "technical error line only in the log" "${ROOTCMD[@]}" grep -Eq \
        '^ERROR \(for bug reports\): exit 1 at line [0-9]+ in run <- step_update <- run_steps <- main: dnf5 upgrade --refresh -y$' \
        "$R/var/log/fedora-kde-setup.log"
    expect_out_fixed 'The script stopped during step 2 of 6 (Full system update).'
    expect_no_file "$R/var/lib/fedora-kde-setup/done"
    expect_call '^systemctl unmask --runtime packagekit.service$'
    expect_no_action '^dnf5 remove -y'
}

scenario interrupted "live" "Ctrl-C during the upgrade: 'Interrupted', PackageKit unmasked, no marker"
sc_interrupted() {
    fx_conf 'FKS_SIGINT_ON=^dnf5 upgrade --refresh'
    invoke --yes --no-reboot
    expect_rc nonzero
    expect_out_fixed 'Error: Stopped by Ctrl-C'
    expect_out_fixed 'The script stopped during step 2 of 6 (Full system update).'
    expect_out_fixed '  Finished before that: Faster DNF downloads'
    expect_out_fixed '  Running the script again is safe: it shows what is done and skips it.'
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

scenario pim_absent "dry live" "PIM/LibreOffice not installed, data left: --all leaves it; --only cleans it and unowned dirs"
sc_pim_absent() {
    fx_del installed "${FX_PIM[@]}" "${FX_OFFICE[@]}"
    mkdir -p "$R/usr/lib64/libreoffice/program" "$R/usr/share/akonadi/agents" "$R/etc/libreoffice"
    fx_add owned /etc/libreoffice
    invoke --all --yes --no-reboot
    expect_success
    expect_no_will_do 'Remove leftover'
    expect_no_action 'rm -rf'
    expect_home_intact "$H"
    # Leftover data is deleted only when that step is picked explicitly.
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_will_do 'Remove leftover KDE PIM data'
    expect_will_do 'Remove leftover LibreOffice data'
    expect_out 'KDE PIM is not installed'
    expect_out 'LibreOffice is not installed'
    expect_no_call 'remove .*--assumeno'
    expect_no_action '^dnf5 remove -y'
    expect_action '^dnf5 group remove -y --no-packages kde-pim$'
    expect_action '^dnf5 group remove -y --no-packages libreoffice$'
    expect_home_cleaned "$H"
    if is_live; then
        expect_no_file "$R/usr/lib64/libreoffice"
        expect_no_file "$R/usr/share/akonadi"
        expect_file "$R/etc/libreoffice"
        expect_call_line "rpm -qf /usr/lib64/libreoffice"
        expect_recorded pim
        expect_recorded libreoffice
    else
        expect_action_line "rm -rf -- $R/usr/lib64/libreoffice"
        expect_action_line "rm -rf -- $R/usr/share/akonadi"
        expect_no_action_line "rm -rf -- $R/etc/libreoffice"
    fi
}

scenario removal_guard "dry live" "PIM removal would take plasma-workspace: PIM skipped, LibreOffice removed"
sc_removal_guard() {
    fx_add remove_extra 'kmail plasma-workspace sddm libfoo'
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out_fixed 'Removing KDE PIM would also remove core desktop parts (plasma-workspace sddm); unselected it'
    expect_no_will_do 'Remove KDE PIM'
    expect_will_do 'Remove LibreOffice'
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario office_guard "dry live" "LibreOffice removal would take plasma-desktop: its settings kept, PIM data deleted"
sc_office_guard() {
    fx_add remove_extra 'libreoffice-core plasma-desktop'
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out_fixed 'Removing LibreOffice would also remove core desktop parts (plasma-desktop); unselected it'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_no_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_deleted "$H" "${FX_PIM_JUNK[@]}"
    expect_kept "$H" "${FX_OFFICE_JUNK[@]}"
    expect_rm_count "$H" "${#FX_PIM_JUNK[@]}"
    expect_no_will_do 'Remove LibreOffice'
    expect_suite_deleted "$H" "KDE PIM" "${#FX_PIM_JUNK[@]}"
    if is_live; then expect_recorded pim; expect_not_recorded libreoffice; fi
}

scenario remove_fails "live" "dnf5 remove -y fails for KDE PIM: warning, PIM data kept, run completes"
sc_remove_fails() {
    fx_add fail '^dnf5 remove -y akonadi'
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out 'Removing KDE PIM failed'
    expect_out_fixed "Kept KDE PIM data in $H because KDE PIM is still installed"
    expect_out 'Not completed \(see warnings\):'
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario removal_guard_uninstalled "dry" "Protected name in the transaction but not installed: not counted"
sc_removal_guard_uninstalled() {
    fx_add remove_extra 'kmail plasma-login-manager'
    invoke --only pim --yes --no-reboot
    expect_success
    expect_no_out 'core desktop packages'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
}

scenario removal_plan_error "dry live" "dnf5 can't plan the removal (lock error): both batches skipped"
sc_removal_plan_error() {
    fx_conf FKS_DNF_PLAN_ERROR=1
    invoke --only pim,libreoffice,maintenance --yes --no-reboot
    expect_success
    expect_out "Removing KDE PIM isn't possible right now \\(dnf: .*transaction lock.*\\); unselected it"
    expect_out "Removing LibreOffice isn't possible right now \\(dnf: .*\\); unselected it"
    expect_no_will_do 'Remove'
    if is_live; then expect_recorded maintenance; fi
    expect_no_action '^dnf5 remove -y'
    expect_kept "$H" "${FX_JUNK[@]}"
    expect_rm_count "$H" 0
}

scenario kgpg_cascade_yes "dry live" "PIM removal would take kgpg (an app): --yes unselects PIM up front, LibreOffice removed"
sc_kgpg_cascade_yes() {
    fx_add remove_extra 'kmail kgpg'
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out_fixed 'Removing KDE PIM would also remove kgpg; unselected it (--yes never removes extra apps)'
    expect_no_will_do 'Remove KDE PIM'
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_pim_data_kept
}

scenario kgpg_appears_late "live" "An app joins the PIM transaction after the review: PIM skipped at run time, data kept"
sc_kgpg_appears_late() {
    fx_add remove_extra_late 'kmail kgpg'
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_will_do 'Remove KDE PIM'
    expect_out_fixed "Skipped removing KDE PIM: it would now also remove kgpg, which wasn't on the review screen."
    expect_out_fixed "Kept KDE PIM data in $H because KDE PIM is still installed"
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_pim_data_kept
    expect_out '1 of 2 steps finished; 1 needs attention'
}

scenario pim_running "dry live" "PIM processes running: pkill (pattern and akonadi db) before removal"
sc_pim_running() {
    fx_conf FKS_PIM_RUNNING=1
    invoke --only pim --yes --no-reboot
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
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_action_line "$(as_user_prefix) env XDG_RUNTIME_DIR=$rt DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus akonadictl stop"
    expect_action_line "$(as_user_prefix) env -u LC_ALL LANG=$lang XDG_RUNTIME_DIR=$rt DBUS_SESSION_BUS_ADDRESS=unix:path=$rt/bus kbuildsycoca6 --noincremental"
    expect_no_action '^sudo' 
    expect_order 'akonadictl stop' '^dnf5 remove -y'
}

scenario user_junk "dry live" "Home cleanup deletes exactly the listed paths (symlink not followed)"
sc_user_junk() {
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_home_cleaned "$H"
}

# ---------------------------------------------------------------------------
# Flatpak, firmware, kernel modules

scenario flatpak_setup "dry live" "Flatpak + Discover backend missing; Fedora remotes: used one kept at low prio, unused one disabled"
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
    expect_action '^flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo$'
    expect_action '^flatpak remote-modify --no-filter --enable flathub$'
    expect_action '^flatpak remote-modify --prio=10 flathub$'
    expect_action_line "$(as_user_prefix) kwriteconfig6 --file $H/.config/discoverrc --group ResourcesModel --key currentApplicationBackend flatpak-backend"
    expect_no_action 'remote-delete'
    if is_live; then
        # The flatpak command only exists once the package is installed.
        expect_action '^flatpak remote-modify --prio=1 fedora$'
        expect_out "Kept Fedora's 'fedora' Flatpak source enabled because apps are installed from it"
        expect_action '^flatpak remote-modify --disable fedora-testing$'
        expect_no_action '^flatpak remote-modify --disable fedora$'
        expect_grep "$H/.config/discoverrc" '^currentApplicationBackend=flatpak-backend$'
        expect_recorded flathub
    fi
}

scenario flathub_no_kwriteconfig "live" "kwriteconfig6 missing: Discover default not set, warning"
sc_flathub_no_kwriteconfig() {
    fx_missing kwriteconfig6
    invoke --only flathub --yes --no-reboot
    expect_success
    expect_out "Couldn't make Flathub Discover's default source \\(kwriteconfig6 not found\\)"
    expect_no_file "$H/.config/discoverrc"
}

scenario fwupd_fail "dry live" "fwupd not installed, fwupdmgr update fails: warning only"
sc_fwupd_fail() {
    fx_missing fwupdmgr
    fx_conf FKS_FWUPD_RC=1
    invoke --yes --no-reboot
    expect_success
    expect_install fwupd
    expect_action '^fwupdmgr refresh --force$'
    if is_live; then
        expect_out 'fwupdmgr exited with 1'
        expect_not_recorded firmware
        expect_out 'Not completed \(see warnings\):'
    fi
}

scenario fwupd_refresh_fails "live" "fwupdmgr refresh fails and update says nothing to do: firmware not completed"
sc_fwupd_refresh_fails() {
    fx_add fail '^fwupdmgr refresh'
    invoke --only firmware --yes --no-reboot
    expect_success
    expect_out "Couldn't refresh firmware metadata"
    expect_no_out 'Firmware already up to date'
    expect_not_recorded firmware
    expect_out '0 of 1 steps finished; 1 needs attention'
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
    expect_out_fixed 'A reboot is recommended to start the new kernel.'
}

scenario kernel_update_nokmod "live" "New kernel, no kmods: reboot reason is the kernel"
sc_kernel_update_nokmod() {
    fx_gpu_intel
    fx_conf "FKS_UPGRADE_KERNEL=$NEW_KERNEL"
    invoke --yes --no-reboot
    expect_success
    expect_out_fixed 'A reboot is recommended to start the new kernel.'
}

scenario kmod_not_built "live" "akmods build fails: warning, run completes"
sc_kmod_not_built() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_MODS_BUILT=0
    invoke --yes --no-reboot
    expect_success
    expect_out "Kernel module 'nvidia' isn't built yet"
    expect_not_recorded drivers
}

# ---------------------------------------------------------------------------
# Marker, confirmation, reboot

scenario legacy_marker "live" "v1.1 single-date state file: no refusal, firmware shows the date, rewritten as ID lines"
sc_legacy_marker() {
    fx_marker "2025-05-05 10:00:00"
    invoke --status
    expect_rc 0
    expect_status_todo 'Firmware updates' '• last checked 2025-05-05'
    expect_no_out 'already completed'
    invoke --only dnf --yes --no-reboot
    expect_success
    expect_recorded dnf
    local id
    for id in update codecs drivers pim libreoffice flathub firmware maintenance; do
        expect_grep "$(state_file)" "^$id 2025-05-05 10:00:00$"
    done
    expect_count "$(state_file)" '^2025-05-05' 0
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
    PTY_INPUT="$START_YES|WAIT:Reboot now|\n"
    EXPECT_REBOOT=1
    invoke
    expect_success
    expect_out 'Start these [0-9]+ steps now\? \[y/N\]'
    expect_out_fixed 'Save your work in other apps first.'
    expect_out 'Reboot now\? \(recommended\) \[Y/n\]'
    expect_call '^systemctl reboot$'
}

scenario tty_confirm_no "pty" "Terminal: answer n at the review: nothing changes, exit 0"
sc_tty_confirm_no() {
    PTY_INPUT=$START_NO
    invoke --no-reboot
    expect_rc 0
    expect_out '^Nothing was changed\.$'
    expect_no_pkg_change
    expect_no_call '^systemctl (mask|enable|restart)'
    expect_no_file "$(state_file)"
    expect_count "$R/etc/dnf/dnf.conf" 'fastestmirror' 0
}

scenario tty_no_reboot "pty" "Terminal + --no-reboot: no reboot prompt"
sc_tty_no_reboot() {
    PTY_INPUT=$START_YES
    invoke --no-reboot
    expect_success
    expect_no_out 'Reboot now'
}

scenario assume_yes "live" "--yes without --no-reboot: never prompts or reboots"
sc_assume_yes() {
    invoke --yes
    expect_success
    expect_no_out 'Start these'
    expect_no_out 'Reboot now'
    expect_out 'A reboot is recommended'
}

# ---------------------------------------------------------------------------
# Target user

scenario root_no_user "dry live" "Plain root, no SUDO_USER/--user, PIM selected: real run dies"
sc_root_no_user() {
    RUN_ENV=()
    invoke --only pim --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out "Can't tell whose KDE PIM/LibreOffice data to clean up"
    else
        expect_rc 0
        expect_out "user '(root|tester)'"
    fi
}

scenario root_no_user_all "live" "Plain root, no user: --all works (it never removes apps)"
sc_root_no_user_all() {
    RUN_ENV=()
    invoke --all --yes --no-reboot
    expect_success
    expect_no_out "Can't tell whose"
    expect_recorded maintenance
}

scenario root_no_user_update "live" "Plain root, no user: --only update works (no user data involved)"
sc_root_no_user_update() {
    RUN_ENV=()
    invoke --only update --yes --no-reboot
    expect_success
    expect_out "user 'unknown'"
    expect_no_out "Can't tell whose"
    expect_action '^dnf5 upgrade --refresh -y$'
    expect_recorded update
}

scenario sudo_user_root "live" "SUDO_USER=root (sudo from a root shell), PIM selected: real run dies"
sc_sudo_user_root() {
    RUN_ENV=(SUDO_USER=root)
    invoke --only pim --yes --no-reboot
    expect_untouched
    expect_out "Can't tell whose KDE PIM/LibreOffice data to clean up"
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
    invoke --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out "user 'tester'"
    expect_home_cleaned "$H"
}

scenario user_option "dry live" "--user tester overrides SUDO_USER=alice; alice's home untouched"
sc_user_option() {
    RUN_ENV=(SUDO_USER=alice)
    fx_home_junk "$T/home/alice"
    invoke --user tester --only pim,libreoffice --yes --no-reboot
    expect_success
    expect_out "user 'tester'"
    expect_home_cleaned "$H"
    expect_home_intact "$T/home/alice"
    expect_no_action "home/alice"
}

scenario user_eq_form "dry" "--user=tester form"
sc_user_eq_form() {
    RUN_ENV=(SUDO_USER=alice)
    invoke --user=tester --yes
    expect_success
    expect_out "user 'tester'"
}

scenario user_unknown "dry live" "--user ghost: real run dies, dry run warns and skips user data"
sc_user_unknown() {
    invoke --user ghost --only pim --yes --no-reboot
    if is_live; then
        expect_untouched
        expect_out "User 'ghost' doesn't exist"
    else
        expect_rc 0
        expect_out "\\(dry-run\\) User 'ghost' doesn't exist"
        expect_out "\\(dry-run\\) Can't tell whose KDE PIM/LibreOffice data to clean up"
        expect_out "No home directory for 'ghost'; skipped deleting KDE PIM user data"
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

scenario net_fedora_down "dry live" "Fedora mirrors unreachable with the update step: refused"
sc_net_fedora_down() {
    fx_conf 'FKS_HEAD_FAIL_RE=^https://mirrors\.fedoraproject\.org/'
    invoke --only update --yes --no-reboot
    expect_out_fixed "Can't reach Fedora's mirrors (https://mirrors.fedoraproject.org). Check the internet connection."
    expect_no_call 'rpmfusion'
    if is_live; then expect_untouched; else expect_rc 0; fi
}

scenario net_flathub_down "dry live" "Flathub unreachable with the flathub step: refused"
sc_net_flathub_down() {
    fx_conf 'FKS_HEAD_FAIL_RE=^https://dl\.flathub\.org/'
    invoke --only flathub --yes --no-reboot
    expect_out_fixed "Can't reach Flathub (https://dl.flathub.org). Check the internet connection."
    expect_no_call 'rpmfusion|fedoraproject'
    if is_live; then expect_untouched; else expect_rc 0; fi
}

scenario net_probes_by_step "live" "Only the hosts the selected steps need are probed"
sc_net_probes_by_step() {
    invoke --only codecs --yes --no-reboot
    expect_call_line "$CURL_HEAD $(rf_url free 41)"
    expect_no_call 'fedoraproject|dl\.flathub'
    invoke --only firmware --yes --no-reboot
    expect_call_line "$CURL_HEAD https://mirrors.fedoraproject.org/"
    expect_no_call 'rpmfusion|dl\.flathub'
    invoke --only dnf,pim,maintenance --yes --no-reboot
    expect_no_call '^curl'
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
    expect_out '^Examples:$'
    expect_out '^  sudo bash fedora-kde-setup\.sh --all --yes '
    expect_out '--dry-run'
    expect_out '-V, --version'
    check "no command called" not test -s "$CALLS"
}

scenario version "dry" "-V prints the version"
sc_version() {
    EXPECT_NO_LOG=1
    invoke -V
    expect_rc 0
    expect_out '^fedora-kde-setup 1\.2\.0$'
    check "no command called" not test -s "$CALLS"
}

scenario bad_option "dry" "Unknown option is rejected"
sc_bad_option() {
    EXPECT_NO_LOG=1
    invoke --bogus
    expect_rc nonzero
    expect_out_fixed "Error: Unknown option '--bogus'. See --help."
    expect_no_out 'Examples:'
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
        expect_out "Error: $1"
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

scenario rails_order "live" "Safety rails run before the lock (low disk wins over a held lock)"
sc_rails_order() {
    fx_conf FKS_DF_ROOT=100
    hold_lock
    invoke --yes --no-reboot
    release_lock
    expect_untouched
    expect_out 'Only 100 MiB free on /'
    expect_no_out 'Another run of this script'
}

scenario user_bad_name "dry live" "--user 'Bad;Name': invalid user name refused"
sc_user_bad_name() {
    invoke --user 'Bad;Name' --only pim --yes --no-reboot
    expect_out_fixed "'Bad;Name' isn't a valid user name"
    expect_no_call 'Bad;Name'
    if is_live; then
        expect_untouched
    else
        expect_rc 0
        expect_out "\\(dry-run\\) Can't tell whose KDE PIM/LibreOffice data to clean up"
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

# RPM Fusion couldn't be set up: codecs (and drivers) are skipped, the run goes on.
rf_refused() {  # MESSAGE
    expect_rc 0
    expect_out_fixed "$1"
    expect_out_fixed "Skipped the codecs: they come from RPM Fusion, which couldn't be set up"
    expect_no_action '^dnf5 install -y .*/rpmfusion-'
    expect_no_action 'appstream-data|ffmpeg'
    expect_not_recorded codecs
    expect_recorded flathub
    expect_recorded maintenance
    expect_out 'Not completed \(see warnings\):'
    expect_out 'Finished: [0-9]+ of [0-9]+ steps done'
    expect_call '^systemctl unmask --runtime packagekit.service$'
}

scenario rf_fail_drivers "live" "RPM Fusion setup fails with NVIDIA: codecs and drivers skipped, rest runs"
sc_rf_fail_drivers() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_CHECKSIG=bad
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
    expect_out_fixed "Skipped the drivers: they come from RPM Fusion, which couldn't be set up"
    expect_no_action 'install .*akmod-nvidia'
    expect_not_recorded drivers
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

scenario rf_bad_signature "live" "rpmkeys --checksig: SIGNATURES NOT OK: codecs skipped, nothing from RPM Fusion installed"
sc_rf_bad_signature() {
    fx_conf FKS_CHECKSIG=bad
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package, refusing to install it'
    expect_out 'digests SIGNATURES NOT OK'
}

scenario rf_unsigned "live" "rpmkeys --checksig: digests OK but no signature: codecs skipped"
sc_rf_unsigned() {
    fx_conf FKS_CHECKSIG=unsigned
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_no_key "live" "RPM Fusion key missing from distribution-gpg-keys: codecs skipped, nothing downloaded"
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

scenario rf_download_fails "live" "Both RPM Fusion hosts fail: codecs skipped"
sc_rf_download_fails() {
    fx_conf 'FKS_CURL_FAIL_RE=rpmfusion\.org/'
    invoke --yes --no-reboot
    rf_refused "Couldn't download the RPM Fusion free release package"
}

# ---------------------------------------------------------------------------
# Undo information, environment hardening

scenario history_empty "live" "Empty dnf history before the run: no undo line (no start ID)"
sc_history_empty() {
    fx_conf FKS_HISTORY_LAST=
    invoke --yes --no-reboot
    expect_success
    expect_no_out 'dnf history list'
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
    expect_out '^Examples:$'
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

scenario rf_sig_not_exact "live" "checksig output has 'signatures OK' only inside a path: codecs skipped"
sc_rf_sig_not_exact() {
    fx_conf FKS_CHECKSIG=notexact
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_sig_rc "live" "checksig prints 'digests signatures OK' but exits non-zero: codecs skipped"
sc_rf_sig_rc() {
    fx_conf FKS_CHECKSIG=okfail
    invoke --yes --no-reboot
    rf_refused 'Signature check failed for the RPM Fusion free release package'
}

scenario rf_wrong_package "live" "Signed file is another package (rpm -qp name mismatch): codecs skipped"
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
        expect_out_fixed "user '$u'"
    done
}

scenario user_digits "dry live" "All-digit user name '123': rejected"
sc_user_digits() {
    invoke --user 123 --yes --no-reboot
    expect_out_fixed "'123' isn't a valid user name"
    if is_live; then expect_untouched; else expect_rc 0; fi
}

# ===========================================================================
# v1.2: choosing steps, the review screen, status detection, progress, reboot advice

# The menu runs on /dev/tty in the alternate screen. Rows are grouped: RECOMMENDED,
# OPTIONAL, REMOVE APPS. On the Intel laptop (drivers not needed) they are
# 0 dnf, 1 update, 2 codecs, 3 flathub, 4 firmware, 5 maintenance, 6 pim, 7 libreoffice,
# 8 "Continue", 9 "Quit". With an NVIDIA GPU, drivers is row 3 and the rest shift by one.
# Moving wraps around.
readonly UP='\e[A' DOWN='\e[B' ENTER='\n' SPACE=' '
menu_machine() { fx_gpu_intel; fx_wifi_intel; fx_wifi_phy 0000:00:14.3; fx_battery; }
keys() { local k out=""; for k in "$@"; do out+=$k; done; printf '%s' "$out"; }
rep_key() { local i out=""; for (( i = 0; i < $2; i++ )); do out+=$1; done; printf '%s' "$out"; }

expect_menu_shown() {
    expect_out '^  Fedora KDE setup: choose what to do$'
    expect_out '^  ✔ Already done: '
    expect_out '^  RECOMMENDED$'
    expect_out 'Continue with [0-9]+ selected steps?'
    expect_out 'Quit without changes'
    check "alternate screen entered" grep -q $'\e\\[?1049h' "$T/raw.txt"
    check "cursor hidden in the menu" grep -q $'\e\\[?25l' "$T/raw.txt"
    check "alternate screen left and cursor shown again" last_screen_restored
}

last_screen_restored() {  # the last alternate-screen / cursor sequences restore the terminal
    [[ $(grep -ao $'\e\\[?1049[hl]' "$T/raw.txt" | tail -n1) == $'\e[?1049l' ]] &&
        [[ $(grep -ao $'\e\\[?25[lh]' "$T/raw.txt" | tail -n1) == $'\e[?25h' ]]
}

expect_nothing_changed() {  # left without running anything
    expect_no_pkg_change
    expect_no_call '^systemctl (mask|enable|restart|stop|reboot)'
    expect_no_file "$(state_file)"
    expect_home_intact "$H"
}

menu_row_selected() { expect_out "\\[x\\] +$1"; }

menu_frames() {  # the text drawn inside the alternate screen, without escape sequences
    local raw
    raw=$(<"$T/raw.txt")
    raw=${raw#*$'\e[?1049h'}
    raw=${raw%$'\e[?1049l'*}
    sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' <<<"$raw"
}

max_frame_lines() {  # lines of the tallest menu redraw (between clear-screens)
    local raw frame n max=0
    raw=$(<"$T/raw.txt")
    raw=${raw#*$'\e[?1049h'}
    raw=${raw%$'\e[?1049l'*}
    while [[ $raw == *$'\e[H\e[2J'* ]]; do
        raw=${raw#*$'\e[H\e[2J'}
        frame=${raw%%$'\e[H\e[2J'*}
        n=$(printf '%s' "$frame" | grep -c '')
        (( n > max )) && max=$n
    done
    echo "$max"
}

expect_frames_fit_rows() {  # ROWS: every redraw fits the terminal (one line left for the cursor)
    local max
    max=$(max_frame_lines)
    check "every menu frame fits in $1 rows (tallest: $max lines)" test "$max" -le $(( $1 - 1 ))
}

menu_frames_fit() {  # WIDTH: no menu line is wider (in characters)
    local LC_ALL=C.UTF-8 line
    while IFS= read -r line; do
        (( ${#line} <= $1 )) || return 1
    done < <(menu_frames)
}

scenario menu_pick "pty" "Menu: select DNF and maintenance with arrows/Space, Continue, review, y"
sc_menu_pick() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys n "$SPACE" "$(rep_key "$DOWN" 5)" "$SPACE" "$(rep_key "$DOWN" 3)" "$ENTER")$START_YES
    invoke --no-reboot
    expect_success
    expect_menu_shown
    menu_row_selected 'Faster DNF downloads'
    menu_row_selected 'SSD trim \+ smaller system logs'
    expect_out 'Continue with 2 selected steps'
    expect_out '^  Ready to start 2 steps \(usually about 1-2 minutes in total\):$'
    expect_will_do '1. Faster DNF downloads'
    expect_will_do '2. SSD trim + smaller system logs'
    expect_no_will_do 'Full system update'
    expect_out_fixed '  Keep the laptop plugged in until it finishes.'
    expect_no_out 'A reboot will probably be needed'
    expect_no_call '^dnf5 upgrade'
    expect_no_call '^df '
    expect_no_call '^curl'
    expect_no_call '^systemctl mask'
    expect_file "$R/run/fedora-kde-setup.lock"
    expect_recorded dnf
    expect_recorded maintenance
    expect_count "$(state_file)" . 2
    expect_out_fixed 'No reboot needed.'
    expect_no_out 'Reboot now'
}

scenario menu_default_selection "pty" "Menu: the recommended steps not done yet start selected; Continue right away reviews them"
sc_menu_default_selection() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys "$UP" "$UP" "$ENTER")$START_NO
    invoke --no-reboot
    expect_rc 0
    expect_out 'Continue with 5 selected steps'
    expect_out '^  Ready to start 5 steps'
    local t
    for t in "Faster DNF downloads" "Full system update" "Media codecs" "Flathub" "Firmware updates"; do
        expect_will_do "$t"
    done
    expect_no_will_do 'SSD trim'
    expect_no_will_do 'Remove'
    expect_nothing_changed
}

scenario menu_recommended "pty" "Menu: r selects the recommended steps not done yet; n at the review: nothing changed"
sc_menu_recommended() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys r "$UP" "$UP" "$ENTER")$START_NO
    invoke --no-reboot
    expect_rc 0
    local t
    for t in "Faster DNF downloads" "Full system update" "Media codecs and video acceleration" \
        "Flathub as Discover's app store" "Firmware updates"; do expect_will_do "$t"; done
    for t in "Remove" "SSD trim" "Drivers"; do expect_no_will_do "$t"; done
    expect_out 'Continue with 5 selected steps'
    expect_out '^  Ready to start 5 steps \(usually about [0-9]+-[0-9]+ minutes in total\):$'
    expect_out_fixed '  A reboot will probably be needed at the end.'
    expect_out '^Nothing was changed\.$'
    expect_nothing_changed
}

scenario menu_everything "pty" "Menu: a selects everything not done yet except the app removals"
sc_menu_everything() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys a "$UP" "$UP" "$ENTER")$START_NO
    invoke --no-reboot
    local t
    for t in "Faster DNF downloads" "Full system update" "Media codecs" "Flathub" "Firmware updates" "SSD trim"; do
        expect_will_do "$t"
    done
    expect_no_will_do 'Remove'
    expect_out 'Continue with 6 selected steps'
    expect_out '^  REMOVE APPS YOU DON.T USE  \(deletes their data\)$'
    expect_nothing_changed
}

scenario menu_none_continue "pty" "Menu: r then n, Enter on Continue with nothing selected: message; q quits (exit 0)"
sc_menu_none_continue() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys r n "$UP" "$UP" "$ENTER" q)
    invoke --no-reboot
    expect_rc 0
    expect_out 'Continue with 0 selected steps'
    expect_out_fixed 'Select at least one step first: move to it and press Enter or Space.'
    expect_out '^Nothing was changed\.$'
    expect_no_out 'Ready to start'
    expect_nothing_changed
}

scenario menu_quit_keys "pty" "Menu: q, Q, Esc, the Quit row and closed input all quit with exit 0"
sc_menu_quit_keys() {
    AUTO_ALL=0
    menu_machine
    local input
    # (Closed input can't be shown through script(1); menu_ctrl_d types Ctrl-D instead.)
    for input in q Q '\e' "$UP$ENTER" "$UP$SPACE"; do
        PTY_INPUT=$input
        invoke --no-reboot
        expect_rc 0
        expect_out '^Nothing was changed\.$'
        expect_no_out 'Ready to start'
        check "terminal restored (input '$input')" last_screen_restored
        expect_nothing_changed
    done
}

scenario menu_ctrl_d "pty" "Menu: Ctrl-D typed while the menu waits: quits, nothing changed"
sc_menu_ctrl_d() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT="$DOWN|PAUSE|\\x04"
    invoke --no-reboot
    expect_rc 0
    expect_out '^Nothing was changed\.$'
    expect_nothing_changed
}

scenario menu_ctrl_c "pty" "Menu: Ctrl-C while the menu waits: 'Stopped. Nothing was changed.', exit 130, terminal restored"
sc_menu_ctrl_c() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT="$SPACE|PAUSE|\\x03"
    invoke --no-reboot
    expect_rc 130
    expect_out '^Stopped\. Nothing was changed\.$'
    expect_no_out 'The script stopped'
    check "alternate screen left and cursor shown after Ctrl-C" last_screen_restored
    expect_nothing_changed
}

scenario menu_vi_keys "pty" "Menu: j/k/Tab move; k from the top wraps to Quit"
sc_menu_vi_keys() {
    AUTO_ALL=0
    menu_machine
    # j j -> codecs (row 2), Space; Tab x6 -> Continue (row 8); Enter; n at the review.
    PTY_INPUT=$(keys n j j "$SPACE" "$(rep_key '\t' 6)" "$ENTER")$START_NO
    invoke --no-reboot
    expect_will_do '1. Media codecs and video acceleration'
    expect_no_will_do 'Faster DNF'
    expect_nothing_changed
    PTY_INPUT=$(keys k "$ENTER")
    invoke --no-reboot
    expect_rc 0
    expect_out '^Nothing was changed\.$'
}

scenario menu_ss3_arrows "pty" "Menu: application-mode arrows (ESC O B / ESC O A) move too"
sc_menu_ss3_arrows() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys n '\eOB' "$SPACE" '\eOA' '\eOA' '\eOA' "$ENTER")$START_NO
    invoke --no-reboot
    expect_will_do '1. Full system update'
    expect_nothing_changed
}

scenario menu_toggle_off "pty" "Menu: Space twice unselects; nothing selected -> message"
sc_menu_toggle_off() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys n "$SPACE" "$SPACE" "$UP" "$UP" "$ENTER" q)
    invoke --no-reboot
    expect_rc 0
    menu_row_selected 'Faster DNF downloads'
    expect_out_fixed 'Select at least one step first'
    expect_nothing_changed
}

scenario menu_help "pty" "Menu: ? shows the help screen, any key goes back"
sc_menu_help() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys '?' x q)
    invoke --no-reboot
    expect_rc 0
    expect_out '^  How to use this checklist$'
    expect_out_fixed '  Press any key to go back.'
    expect_out_fixed '↑↓ move · Enter select · r recommended · a all · n none · ? help · q quit'
    expect_nothing_changed
}

scenario menu_overview "pty" "Menu: done and not-needed steps are one-line summaries on top, not rows"
sc_menu_overview() {
    AUTO_ALL=0
    menu_machine
    printf '[main]\nfastestmirror=True\nmax_parallel_downloads=10\ndefaultyes=True\n' > "$R/etc/dnf/dnf.conf"
    PTY_INPUT='q'
    invoke --no-reboot
    expect_rc 0
    expect_out '^  ✔ Already done: DNF$'
    expect_out '^  – Not needed here: Drivers$'
    check "no selectable row for the done DNF step" not grep -Eq '\[[ x]\] +Faster DNF downloads' "$OUT"
    expect_out '\[[ x]\] +Full system update  • 3 updates available'
    expect_out '^  OPTIONAL$'
}

scenario menu_sizes "pty" "Menu at 120x50 shows every explanation; at 60x14 it scrolls and shortens the key help"
sc_menu_sizes() {
    AUTO_ALL=0
    menu_machine
    PTY_ROWS=50 PTY_COLS=120
    PTY_INPUT='q'
    invoke --no-reboot
    expect_out 'Picks the fastest mirror and downloads 10 files at once'
    expect_out 'Removes the office suite if you use something else'
    expect_no_out 'more line'
    PTY_ROWS=18 PTY_COLS=60
    PTY_INPUT='q'
    invoke --no-reboot
    expect_rc 0
    expect_frames_fit_rows 18
    expect_out '↓ [0-9]+ more line\(s\)'
    expect_out_fixed '↑↓ move · Enter select · ? help · q quit'
    expect_no_out 'r recommended'
    check "menu frames fit the 60-column terminal" menu_frames_fit 60
    # Scrolled down to the last row: the top part is hidden behind "↑ N more".
    PTY_INPUT=$(keys "$(rep_key "$DOWN" 7)" q)
    invoke --no-reboot
    expect_out '↑ [0-9]+ more line\(s\)'
}

scenario menu_tiny_terminal "pty" "Menu in a 14-row terminal (smallest the script accepts is 10): every frame must fit"
sc_menu_tiny_terminal() {
    AUTO_ALL=0
    menu_machine
    PTY_ROWS=14 PTY_COLS=80
    PTY_INPUT=$(keys "$(rep_key "$DOWN" 7)" q)
    invoke --no-reboot
    expect_rc 0
    expect_frames_fit_rows 14
}

scenario menu_all_done "pty" "Menu with nothing left: overview + 'Everything ... is already done', exit 0"
sc_menu_all_done() {
    AUTO_ALL=0
    fx_fully_configured
    PTY_INPUT=''
    invoke --no-reboot
    expect_rc 0
    expect_out_fixed 'Everything that applies to this computer is already done.'
    expect_out_fixed 'To redo a step anyway, run the setup again with: --only <step> --force   (see --list-steps)'
    expect_no_out 'Continue with'
    expect_no_pkg_change
}

scenario menu_auto_update "pty" "Menu: drivers auto-selects the update; unselecting the update is refused"
sc_menu_auto_update() {
    AUTO_ALL=0
    fx_gpu_nvidia "${NV_TU106[@]}"
    # Rows: 0 dnf, 1 update, 2 codecs, 3 drivers ... 9 Continue, 10 Quit.
    PTY_INPUT=$(keys n "$DOWN" "$DOWN" "$DOWN" "$SPACE" "$UP" "$UP" "$SPACE" "$UP" "$UP" "$UP" "$ENTER")$START_NO
    invoke --no-reboot
    expect_out 'Full system update  • 3 updates available  \(needed by Drivers\)'
    expect_out_fixed 'The system update is needed by the drivers step; unselect the drivers first.'
    expect_out '^   1\. Full system update +needed by the drivers$'
    expect_will_do 'Drivers: NVIDIA GeForce RTX 2060 Rev. A'
    expect_nothing_changed
}

scenario menu_untick_drivers "pty" "Menu: unselecting drivers also drops the auto-selected update"
sc_menu_untick_drivers() {
    AUTO_ALL=0
    fx_gpu_nvidia "${NV_TU106[@]}"
    PTY_INPUT=$(keys n "$DOWN" "$DOWN" "$DOWN" "$SPACE" "$SPACE" "$(rep_key "$DOWN" 6)" "$ENTER" q)
    invoke --no-reboot
    expect_rc 0
    expect_out_fixed 'Select at least one step first'
    expect_nothing_changed
}

scenario menu_sb_review "pty" "Menu with NVIDIA + Secure Boot: the review says the password comes next; asked before step 1"
sc_menu_sb_review() {
    AUTO_ALL=0
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    PTY_INPUT=$(keys n "$DOWN" "$DOWN" "$DOWN" "$SPACE" "$(rep_key "$DOWN" 6)" "$ENTER")$START_YES
    invoke --no-reboot
    expect_success
    expect_out "Drivers: NVIDIA GeForce RTX 2060 Rev\\. A +Secure Boot: you'll set a one-time password right after this screen"
    expect_out_before '^== Secure Boot key \(before the long part\)$' 'Step 1 of 2'
    expect_call_line "mokutil --import $(mok_cert)"
    expect_order '^mokutil --import' '^dnf5 upgrade --refresh'
}

# --- Removals: only on explicit request, reviewed first ---------------------------

scenario menu_remove_pim "pty" "Menu: select KDE PIM; review shows what's deleted; type 'delete' for real mail"
sc_menu_remove_pim() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys n "$(rep_key "$DOWN" 6)" "$SPACE" "$(rep_key "$DOWN" 2)" "$ENTER")"$START_YES|WAIT:to confirm|delete\\n"
    invoke --no-reboot
    expect_success
    expect_out '^  REMOVE APPS YOU DON.T USE  \(deletes their data\)$'
    expect_will_do 'Remove KDE PIM (KMail, Kontact, KOrganizer...)'
    expect_out "^      ! deletes: ${#FX_PIM_JUNK[@]} item\\(s\\), [0-9.]+[KMG]? in your home folder$"
    expect_out_fixed "You have mail or contacts in $H/.local/share that will be deleted for good."
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_deleted "$H" "${FX_PIM_JUNK[@]}"
    expect_kept "$H" "${FX_OFFICE_JUNK[@]}"
    expect_recorded pim
}

scenario menu_remove_pim_keep "pty" "Menu: KDE PIM selected, Enter instead of 'delete': PIM kept, nothing else -> nothing changed"
sc_menu_remove_pim_keep() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys n "$(rep_key "$DOWN" 6)" "$SPACE" "$(rep_key "$DOWN" 2)" "$ENTER")"$START_YES|WAIT:to confirm|\\n"
    invoke --no-reboot
    expect_rc 0
    expect_out_fixed 'OK, KDE PIM and its data are kept.'
    expect_out '^Nothing was changed\.$'
    expect_nothing_changed
}

scenario menu_remove_no_mail "pty" "Menu: KDE PIM without real mail/contacts: no 'delete' question"
sc_menu_remove_no_mail() {
    AUTO_ALL=0
    menu_machine
    rm -rf "$H/.local/share/local-mail" "$H/.local/share/contacts"
    PTY_INPUT=$(keys n "$(rep_key "$DOWN" 6)" "$SPACE" "$(rep_key "$DOWN" 2)" "$ENTER")$START_YES
    invoke --no-reboot
    expect_success
    expect_no_out 'to confirm'
    expect_recorded pim
}

scenario menu_remove_apps "pty" "Menu: PIM removal also takes kgpg: review lists it, confirming removes it too"
sc_menu_remove_apps() {
    AUTO_ALL=0
    menu_machine
    fx_add remove_extra 'kmail kgpg'
    PTY_INPUT=$(keys n "$(rep_key "$DOWN" 6)" "$SPACE" "$(rep_key "$DOWN" 2)" "$ENTER")"$START_YES|WAIT:to confirm|delete\\n"
    invoke --no-reboot
    expect_success
    expect_out_fixed '      ! also removes these apps, which use its libraries: kgpg'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_no_out "wasn't on the review screen"
    expect_recorded pim
}

scenario menu_leftover "pty" "Menu: leftover PIM data is never selected by a/r; selecting it explicitly cleans it"
sc_menu_leftover() {
    AUTO_ALL=0
    menu_machine
    fx_del installed "${FX_PIM[@]}"
    PTY_INPUT=$(keys a "$UP" "$UP" "$ENTER")$START_NO
    invoke --no-reboot
    expect_out '\[ \] +Remove leftover KDE PIM data  ◐ partly done: app removed'
    expect_no_will_do 'Remove leftover KDE PIM data'
    expect_nothing_changed
    PTY_INPUT=$(keys n "$(rep_key "$DOWN" 6)" "$SPACE" "$(rep_key "$DOWN" 2)" "$ENTER")"$START_YES|WAIT:to confirm|delete\\n"
    invoke --no-reboot
    expect_success
    expect_will_do '1. Remove leftover KDE PIM data'
    expect_deleted "$H" "${FX_PIM_JUNK[@]}"
    expect_kept "$H" "${FX_OFFICE_JUNK[@]}"
    expect_recorded pim
}

scenario menu_full_run "pty" "Menu: r + maintenance, run everything selected, decline the reboot"
sc_menu_full_run() {
    AUTO_ALL=0
    menu_machine
    PTY_INPUT=$(keys r "$(rep_key "$DOWN" 5)" "$SPACE" "$(rep_key "$DOWN" 3)" "$ENTER")"$START_YES|WAIT:Reboot now|n\\n"
    invoke
    expect_success
    expect_menu_shown
    expect_out 'All 6 steps finished\.'
    expect_out_fixed 'Save your work in other apps first.'
    expect_out 'Reboot now\? \(recommended\) \[Y/n\]'
    expect_out_fixed 'OK. Remember to reboot soon.'
    expect_no_call '^systemctl reboot'
}

# --- Choosing steps with flags --------------------------------------------------

scenario all_never_removes "dry live" "--all (and --all --force) never select the app removals"
sc_all_never_removes() {
    invoke --all --yes --no-reboot
    expect_success
    expect_no_will_do 'Remove'
    expect_no_action '^dnf5 remove -y'
    expect_home_intact "$H"
    invoke --all --force --yes --no-reboot
    expect_no_will_do 'Remove'
}

scenario only_libreoffice "live" "--only libreoffice: LibreOffice removed; PIM, update, RPM Fusion, network untouched"
sc_only_libreoffice() {
    invoke --only libreoffice --yes --no-reboot
    expect_success
    expect_will_do '1. Remove LibreOffice'
    expect_out "^      ! deletes: ${#FX_OFFICE_JUNK[@]} item\\(s\\), .* in your home folder$"
    expect_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_no_action "^dnf5 remove -y $PIM_SORTED$"
    expect_no_call '^dnf5 upgrade|^curl|^rpmkeys'
    expect_deleted "$H" "${FX_OFFICE_JUNK[@]}"
    expect_kept "$H" "${FX_PIM_JUNK[@]}"
    expect_recorded libreoffice
    expect_count "$(state_file)" . 1
    expect_call '^df -Pm'
}

scenario only_codecs "live" "--only codecs: bootstraps RPM Fusion (network probe), no system upgrade"
sc_only_codecs() {
    invoke --only codecs --yes --no-reboot
    expect_success
    expect_call_line "$CURL_HEAD $(rf_url free 41)"
    expect_rpmfusion 41
    expect_no_call '^dnf5 upgrade --refresh'
    expect_recorded codecs
}

scenario only_pim "live" "--only pim with --yes: removed (no 'delete' question), no network check"
sc_only_pim() {
    invoke --only pim --yes --no-reboot
    expect_success
    expect_no_call '^curl'
    expect_no_out 'to confirm'
    expect_action "^dnf5 remove -y $PIM_SORTED$"
    expect_no_action "^dnf5 remove -y $OFFICE_SORTED$"
    expect_recorded pim
}

scenario only_dnf "live" "--only dnf: no rails, no PackageKit pause, no network; lock still taken"
sc_only_dnf() {
    invoke --only=dnf --yes --no-reboot
    expect_success
    expect_no_call '^df |^pgrep -x|^rpm -q --quiet rpm$|^curl|^systemctl mask|^dnf5 history'
    expect_file "$R/run/fedora-kde-setup.lock"
    expect_recorded dnf
    expect_out_fixed 'No reboot needed.'
    expect_out '^All 1 step finished\.|== All 1 step finished\. =='
}

scenario skip_steps "live" "--all --skip codecs,flathub: both left out"
sc_skip_steps() {
    invoke --all --skip codecs,flathub --yes --no-reboot
    expect_success
    expect_no_will_do 'Media codecs'
    expect_no_will_do 'Flathub'
    expect_no_call '^rpmkeys|^flatpak remote'
    expect_recorded maintenance
    expect_not_recorded codecs
}

scenario skip_update_drivers "live" "--all --skip update with NVIDIA: drivers dropped (they need the update)"
sc_skip_update_drivers() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --all --skip update --yes --no-reboot
    expect_success
    expect_out_fixed 'Skipped the drivers: they need the system update, which --skip leaves out'
    expect_no_will_do 'Full system update'
    expect_no_will_do 'Drivers'
    expect_no_call '^dnf5 upgrade --refresh'
    expect_no_action 'akmod-nvidia'
}

scenario only_drivers_dep "dry" "--only drivers with pending updates: update added, 'needed by the drivers'"
sc_only_drivers_dep() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    invoke --only drivers --yes
    expect_success
    expect_out '^   1\. Full system update +needed by the drivers$'
    expect_will_do '2. Drivers: NVIDIA GeForce RTX 2060 Rev. A'
}

scenario flag_errors "dry" "--skip without --all, --only with --all, unknown/empty step IDs: rejected"
sc_flag_errors() {
    EXPECT_NO_LOG=1
    invoke --only pim --skip dnf
    expect_rc 1
    expect_out_fixed -- 'Error: --skip only works together with --all'
    invoke --only pim --all
    expect_rc 1
    expect_out_fixed 'Error: Use either --only or --all, not both'
    invoke --only dnf,foo
    expect_rc 1
    expect_out_fixed "Error: Unknown step 'foo' in --only. Valid steps: dnf update codecs drivers pim libreoffice flathub firmware maintenance"
    invoke --all --skip bar
    expect_rc 1
    expect_out_fixed "Unknown step 'bar' in --skip."
    invoke --only ''
    expect_rc 1
    expect_out_fixed -- '--only needs a list of steps (see --list-steps)'
    check "no command called" not test -s "$CALLS"
}

scenario yes_without_selection "live" "--yes without --only/--all: refused, nothing changed"
sc_yes_without_selection() {
    AUTO_ALL=0
    invoke --yes --no-reboot
    expect_untouched
    expect_out_fixed 'Error: Choose steps with --only ... or --all (see --list-steps). Nothing was changed.'
}

scenario notty_no_flags "dry live" "No terminal, no flags: real run refuses; dry run previews all not-done steps"
sc_notty_no_flags() {
    AUTO_ALL=0
    invoke --no-reboot
    if is_live; then
        expect_untouched
        expect_out_fixed 'No terminal to show the checklist on. Choose steps with --only ... or --all, plus --yes.'
    else
        expect_success
        expect_out_fixed "No terminal for the checklist: previewing every step that isn't done yet (except app removals)"
        expect_will_do 'Full system update'
        expect_will_do 'SSD trim'
        expect_no_will_do 'Remove'
    fi
}

scenario list_steps "dry" "--list-steps prints the grouped step list; runs nothing"
sc_list_steps() {
    EXPECT_NO_LOG=1
    invoke --list-steps
    expect_rc 0
    expect_out '^Steps \(use the IDs with --only and --skip\):$'
    expect_out '^  RECOMMENDED$'
    expect_out '^  OPTIONAL$'
    expect_out "^  REMOVE APPS YOU DON'T USE  \\(deletes their data\\)$"
    expect_out '^    dnf +Faster DNF downloads$'
    expect_out '^    pim +Remove KDE PIM \(KMail, Kontact, KOrganizer\.\.\.\)$'
    expect_out '^    maintenance +SSD trim \+ smaller system logs$'
    expect_out_fixed "--all selects every step that applies and isn't done yet, except the app removals."
    check "no command called" not test -s "$CALLS"
}

scenario nothing_to_do "live" "Fully set-up VM + --all: 'Nothing to do', nothing changed"
sc_nothing_to_do() {
    fx_fully_configured
    cp "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
    invoke --all --yes --no-reboot
    expect_rc 0
    expect_out_fixed 'Nothing to do: the selected steps are already done (--force runs them again).'
    expect_no_pkg_change
    expect_no_call '^systemctl (mask|enable|restart)'
    expect_no_file "$(state_file)"
    check "dnf.conf unchanged" cmp -s "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
}

scenario force_rerun "live" "Fully set-up VM + --all --force: every applicable non-removal step reruns, no needless reboot"
sc_force_rerun() {
    fx_fully_configured
    cp "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
    invoke --all --force --yes --no-reboot
    expect_success
    local t
    for t in "Faster DNF downloads" "Full system update" "Media codecs" "Guest tools for this virtual machine (kvm)" \
        "Flathub" "SSD trim"; do expect_will_do "$t"; done
    expect_no_will_do 'Firmware'
    expect_no_will_do 'Remove'
    check "dnf.conf byte-identical (values already set)" cmp -s "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
    expect_out 'fastestmirror is already set'
    expect_out 'RPM Fusion already installed'
    # Nothing was pending, so the upgrade changed nothing: no reboot advice from it.
    expect_out_fixed 'No reboot needed.'
    expect_out 'All 6 steps finished\.'
}

scenario only_done_skipped "live" "--only with an already-done step: listed under Skipped"
sc_only_done_skipped() {
    printf '[main]\nfastestmirror=True\nmax_parallel_downloads=10\ndefaultyes=True\n' > "$R/etc/dnf/dnf.conf"
    invoke --only dnf,maintenance --yes --no-reboot
    expect_success
    expect_out 'Skipped:'
    expect_out_fixed 'Faster DNF downloads (already done; --force runs it again)'
    expect_not_recorded dnf
    expect_recorded maintenance
}

scenario only_not_applicable "live" "--only firmware in a VM: says it doesn't apply, not that it's 'already done'"
sc_only_not_applicable() {
    fx_conf FKS_VIRT=kvm
    invoke --only firmware --yes --no-reboot
    expect_rc 0
    expect_out_fixed 'Skipping Firmware updates: not available in a virtual machine'
    expect_no_out 'already done'
    expect_no_pkg_change
}

scenario two_steps_fail "live" "Two steps not completed: summary says '2 need attention', exit 0"
sc_two_steps_fail() {
    fx_add unavailable gstreamer1-plugins-bad-freeworld
    fx_conf FKS_FWUPD_RC=1
    invoke --only dnf,codecs,firmware --yes --no-reboot
    expect_rc 0
    expect_out_fixed '1 of 3 steps finished; 2 need attention (see below).'
    expect_out 'Not completed \(see warnings\):'
    expect_recorded dnf
}

scenario akmods_already_built "live" "Modules already built for the newest kernel: no akmods/kernel-devel, reboot still advised"
sc_akmods_already_built() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_UPDATES=0
    fx_add modules "$FX_KERNEL nvidia"
    invoke --only drivers --yes --no-reboot
    expect_success
    expect_no_will_do 'Full system update'
    expect_out "Kernel modules \\(nvidia\\) already built for $FX_KERNEL"
    expect_no_call '^akmods'
    expect_no_action 'kernel-devel'
    expect_out_fixed 'A reboot is recommended to load the new drivers.'
    expect_recorded drivers
}

scenario akmods_built_loaded "live" "Driver reinstalled, module built and loaded: no reboot needed"
sc_akmods_built_loaded() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_UPDATES=0
    fx_add modules "$FX_KERNEL nvidia"
    mkdir -p "$R/sys/module/nvidia"
    invoke --only drivers --yes --no-reboot
    expect_success
    expect_no_call '^akmods'
    expect_out_fixed 'No reboot needed.'
}

scenario dnfconf_keep_higher "live" "dnf.conf: keeps max_parallel_downloads=20 and an existing true value"
sc_dnfconf_keep_higher() {
    printf '[main]\nfastestmirror=1\nmax_parallel_downloads=20\n' > "$R/etc/dnf/dnf.conf"
    invoke --status
    expect_status_todo 'Faster DNF downloads' '◐ partly done: some settings missing'
    invoke --only dnf --yes --no-reboot
    expect_success
    expect_out 'fastestmirror is already set'
    expect_out 'Kept your max_parallel_downloads=20'
    expect_count "$R/etc/dnf/dnf.conf" '^max_parallel_downloads=20$' 1
    expect_count "$R/etc/dnf/dnf.conf" '^fastestmirror=1$' 1
    expect_count "$R/etc/dnf/dnf.conf" '^defaultyes=True$' 1
    expect_no_out 'set max_parallel_downloads'
}

scenario dnfconf_already_set "live" "dnf.conf already set: --only dnf --force leaves the file byte-identical"
sc_dnfconf_already_set() {
    printf '[main]\ngpgcheck=True\nfastestmirror=True\nmax_parallel_downloads=10\ndefaultyes=True\n' > "$R/etc/dnf/dnf.conf"
    cp "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
    invoke --only dnf --force --yes --no-reboot
    expect_success
    check "dnf.conf byte-identical" cmp -s "$R/etc/dnf/dnf.conf" "$T/dnf.conf.before"
    expect_no_out '\$ set '
}

# --- Status detection ------------------------------------------------------------
# --status prints the overview ("✔ Already done", "– Not needed") and a grouped
# "Still to do" list.

expect_status_done() { expect_out "^      ✔ $1 \\($2\\)\$"; }
expect_status_todo() { expect_out "^      \\[ \\] $1  ${2:-}\$"; }
expect_status_na()   { expect_out_fixed "      $1 ($2)"; }

status_unchanged_checks() {
    expect_rc 0
    expect_out '^  Still to do$'
    expect_out_fixed 'Nothing was changed. Run without --status to pick steps.'
    expect_no_pkg_change
    expect_no_call '^systemctl (mask|enable|restart|stop)|^curl|^df '
    expect_no_file "$R/run/fedora-kde-setup.lock"
    expect_no_out 'Ready to start|Continue with|Quit without changes'
    check "no menu screen in --status" not grep -q $'\e\\[?1049h' "$T/raw.txt"
}

scenario status_fresh "live user" "--status on a fresh laptop: todo/partial/n-a; no changes; works without root"
sc_status_fresh() {
    menu_machine
    local before
    before=$(tree_state "$R" "$T/home")
    invoke --status
    status_unchanged_checks
    check "fake root and homes unchanged by --status" test "$before" == "$(tree_state "$R" "$T/home")"
    expect_out '^  ✔ Already done on this computer$'
    expect_out '^      nothing yet$'
    expect_out '^  – Not needed on this computer$'
    expect_status_na 'Drivers for your hardware' 'nothing needed: your graphics and Wi-Fi use built-in drivers'
    expect_out '^    RECOMMENDED$'
    expect_out "^    REMOVE APPS YOU DON'T USE  \\(deletes their data\\)\$"
    expect_status_todo 'Faster DNF downloads'
    expect_status_todo 'Full system update' '• 3 updates available'
    expect_status_todo 'Media codecs and video acceleration'
    expect_status_todo 'Remove KDE PIM \(KMail, Kontact, KOrganizer\.\.\.\)' '• currently installed'
    expect_status_todo 'Remove LibreOffice' '• currently installed'
    expect_status_todo "Flathub as Discover's app store" \
        "◐ partly done: missing Flathub, Fedora's duplicate Flatpak source disabled, Flathub as Discover's default"
    expect_status_todo 'Firmware updates' '• not checked yet'
    expect_status_todo 'SSD trim \+ smaller system logs'
    expect_out_before '^    RECOMMENDED$' '^    OPTIONAL$'
    expect_out_before '^    OPTIONAL$' '^    REMOVE APPS'
    if [[ $MODE == user ]]; then
        expect_no_out 'Run this with sudo'
        expect_call '^dnf5 -q check-upgrade$'
    else
        expect_call '^dnf5 -q check-upgrade --refresh$'
    fi
}

scenario status_configured "live" "--status on a fully set-up VM: everything done, firmware n/a"
sc_status_configured() {
    fx_fully_configured
    invoke --status
    status_unchanged_checks
    expect_status_done 'Faster DNF downloads' 'already set'
    expect_status_done 'Full system update' 'up to date'
    expect_status_done 'Media codecs and video acceleration' 'installed'
    expect_status_done 'Guest tools for this virtual machine \(kvm\)' 'installed'
    expect_status_done 'Remove KDE PIM \(KMail, Kontact, KOrganizer\.\.\.\)' 'already removed'
    expect_status_done 'Remove LibreOffice' 'already removed'
    expect_status_done "Flathub as Discover's app store" 'already set up'
    expect_status_done 'SSD trim \+ smaller system logs' 'already set up'
    expect_status_na 'Firmware updates' 'not available in a virtual machine'
    expect_out '^      nothing: everything that applies is done$'
}

scenario status_partial "live" "--status with half-done steps: partial notes for each kind"
sc_status_partial() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_CHECK_UPGRADE_RC=1
    printf '[main]\nfastestmirror=True\n' > "$R/etc/dnf/dnf.conf"
    fx_add installed rpmfusion-free-release rpmfusion-nonfree-release akmod-nvidia
    fx_add modules "$FX_KERNEL nvidia"
    fx_del installed "${FX_PIM[@]}" "${FX_OFFICE[@]}"
    rm -rf "${FX_OFFICE_JUNK[@]/#/$H/}"
    printf '[core]\n[remote "fedora"]\nxa.disable=true\n[remote "flathub"]\nurl=x\nxa.filter=/usr/share/flatpak/fedora-flathub.filter\n' \
        > "$R/var/lib/flatpak/repo/config"
    mkdir -p "$H/.config"; printf '[ResourcesModel]\ncurrentApplicationBackend=flatpak-backend\n' > "$H/.config/discoverrc"
    mkdir -p "$R/etc/systemd/journald.conf.d" "$R/var/lib/fedora-kde-setup"
    printf '[Journal]\nSystemMaxUse=500M\n' > "$R/etc/systemd/journald.conf.d/00-size.conf"
    printf 'firmware 2026-03-04 05:06:07\n' > "$(state_file)"
    invoke --status
    status_unchanged_checks
    expect_status_todo 'Faster DNF downloads' '◐ partly done: some settings missing'
    expect_status_todo 'Full system update' "• couldn't check for updates"
    expect_status_todo 'Media codecs and video acceleration' \
        '◐ partly done: missing ffmpeg, gstreamer1-plugins-bad-freeworld, gstreamer1-plugins-ugly and 2 more'
    expect_status_todo 'Drivers: NVIDIA GeForce RTX 2060 Rev\. A' '◐ partly done: missing a reboot to load it'
    expect_status_todo 'Remove leftover KDE PIM data' '◐ partly done: app removed, data still in your home folder'
    expect_status_done 'Remove LibreOffice' 'already removed'
    expect_status_todo "Flathub as Discover's app store" '◐ partly done: missing the full \(unfiltered\) Flathub'
    expect_status_todo 'Firmware updates' '• last checked 2026-03-04'
    expect_status_todo 'SSD trim \+ smaller system logs' '◐ partly done: partly set up'
}

scenario status_drivers "live" "--status drivers: not installed / module missing / not loaded (+SB) / loaded"
sc_status_drivers() {
    fx_gpu_nvidia "${NV_TU106[@]}"
    fx_conf FKS_SB=enabled
    invoke --status
    expect_status_todo 'Drivers: NVIDIA GeForce RTX 2060 Rev\. A'
    fx_add installed akmod-nvidia
    invoke --status
    expect_status_todo 'Drivers: NVIDIA .*' '◐ partly done: missing nvidia module for the running kernel'
    fx_add modules "$FX_KERNEL nvidia"
    invoke --status
    expect_status_todo 'Drivers: NVIDIA .*' '◐ partly done: missing a reboot to load it \(and Secure Boot key enrollment\)'
    mkdir -p "$R/sys/module/nvidia"
    invoke --status
    expect_status_done 'Drivers: NVIDIA GeForce RTX 2060 Rev\. A' 'installed'
}

scenario status_flathub "live" "--status flathub: disabled remote, Fedora remote still used, Discover default"
sc_status_flathub() {
    mkdir -p "$H/.config"; printf '[ResourcesModel]\ncurrentApplicationBackend=flatpak-backend\n' > "$H/.config/discoverrc"
    printf '[remote "fedora"]\nurl=oci\n[remote "flathub"]\nurl=x\nxa.disable=true\n' > "$R/var/lib/flatpak/repo/config"
    invoke --status
    expect_status_todo "Flathub as Discover's app store" "◐ partly done: missing Flathub enabled, Fedora's duplicate Flatpak source disabled"
    # Apps installed from Fedora's remote: it may stay enabled.
    printf '[remote "fedora"]\nurl=oci\n[remote "flathub"]\nurl=x\n' > "$R/var/lib/flatpak/repo/config"
    fx_add flatpak_origins fedora
    invoke --status
    expect_status_done "Flathub as Discover's app store" 'already set up'
    rm -f "$H/.config/discoverrc"
    invoke --status
    expect_status_todo "Flathub as Discover's app store" "◐ partly done: missing Flathub as Discover's default"
}

scenario status_container "live" "--status in a container: drivers/firmware n/a, fstrim counts as done"
sc_status_container() {
    touch "$R/run/.containerenv"
    mkdir -p "$R/etc/systemd/journald.conf.d"
    printf '[Journal]\nSystemMaxUse=500M\n' > "$R/etc/systemd/journald.conf.d/00-size.conf"
    invoke --status
    status_unchanged_checks
    expect_status_na 'Drivers for your hardware' 'not needed in a container'
    expect_status_na 'Firmware updates' 'not available in a container'
    expect_status_done 'SSD trim \+ smaller system logs' 'already set up'
}

scenario status_after_run "live" "After a run, --status lists those steps as done"
sc_status_after_run() {
    menu_machine
    invoke --only "$ALL_AND_REMOVALS" --yes --no-reboot
    expect_success
    invoke --status
    expect_status_done 'Faster DNF downloads' 'already set'
    expect_status_done 'Full system update' 'up to date'
    expect_status_done 'Media codecs and video acceleration' 'installed'
    expect_status_done 'Remove KDE PIM \(KMail, Kontact, KOrganizer\.\.\.\)' 'already removed'
    expect_status_done 'Remove LibreOffice' 'already removed'
    expect_status_done "Flathub as Discover's app store" 'already set up'
    expect_status_done 'SSD trim \+ smaller system logs' 'already set up'
    expect_status_todo 'Firmware updates' '• last checked 2026-01-02'
}

# --- Progress and reboot advice ----------------------------------------------------

progress_percents() {  # ERE -> the percentages of the matching lines, in order
    grep -E "$1" "$OUT" | grep -oE '[0-9]+%' | tr -d %
}
monotonic_from_0() {  # reads numbers: non-decreasing and starting at 0; $1 = required last value
    local prev=-1 n first="" last=""
    while read -r n; do
        [[ -z $first ]] && first=$n
        (( n >= prev )) || return 1
        prev=$n last=$n
    done
    [[ $first == 0 && ( -z ${1:-} || $last == "$1" ) ]]
}

scenario progress_plain "live" "No terminal: '== Step i of n · Title · time (N%) ==' headers, rising; done lines; verdict"
sc_progress_plain() {
    menu_machine
    invoke --all --yes --no-reboot
    expect_success
    local i
    for i in 1 2 3 4 5 6; do
        expect_out "^== Step $i of 6 · .* \\([0-9]+%\\) ==\$"
        expect_out "^  ✔ Step $i of 6 done \\([0-9]+ s\\)\$"
    done
    expect_out '^== Step 1 of 6 · Faster DNF downloads · under a minute \(0%\) ==$'
    expect_out '^== Step 2 of 6 · Full system update · usually 5-30 min \([0-9]+%\) ==$'
    expect_out '^== All 6 steps finished\. ==$'
    check "percentages rise from 0" monotonic_from_0 < <(progress_percents '^== Step [0-9]+ of')
    check "no bar characters without a terminal" not grep -q '█' "$OUT"
}

scenario progress_tty "pty" "Terminal: '━━ Step ━━' headers with bars, window title, final 100% bar"
sc_progress_tty() {
    menu_machine
    invoke --all --yes --no-reboot
    expect_success
    expect_out '^━━ Step 1 of 6 · Faster DNF downloads · under a minute ━━$'
    expect_out '^\[░{24}\]   0%$'
    expect_out '^━━ All 6 steps finished\. ━━$'
    expect_out '^\[█{24}\] 100%$'
    check "bar percentages rise from 0 to 100" monotonic_from_0 100 < <(progress_percents '^\[[█░]{24}\] +[0-9]+%$')
    check "window title shows the step" grep -q $'\e\\]0;fedora-kde-setup · Step 1/6 · 0%\a' "$T/raw.txt"
    check "window title says done at the end" grep -q $'\e\\]0;fedora-kde-setup: done\a' "$T/raw.txt"
}

scenario reboot_declined "pty" "Reboot advised after the update: prompt shown, 'n' declines"
sc_reboot_declined() {
    menu_machine
    PTY_INPUT="$START_YES|WAIT:Reboot now|n\\n"
    invoke
    expect_success
    expect_out_fixed 'A reboot is recommended so updated system services and libraries are used.'
    expect_out_fixed 'Save your work in other apps first.'
    expect_out 'Reboot now\? \(recommended\) \[Y/n\]'
    expect_out_fixed 'OK. Remember to reboot soon.'
    expect_no_call '^systemctl reboot'
}

scenario reboot_eof "pty" "Reboot prompt answered with Ctrl-D (EOF): treated as no, no reboot"
sc_reboot_eof() {
    menu_machine
    PTY_INPUT="$START_YES|WAIT:Reboot now|\\x04"
    invoke
    expect_success
    expect_out 'Reboot now\? \(recommended\) \[Y/n\]'
    expect_no_call '^systemctl reboot'
}

scenario reboot_not_needed "pty" "Only DNF + maintenance: 'No reboot needed', no prompt"
sc_reboot_not_needed() {
    menu_machine
    PTY_INPUT=$START_YES
    invoke --only dnf,maintenance
    expect_success
    expect_out_fixed 'No reboot needed.'
    expect_no_out 'Reboot now'
}

scenario typeahead_flushed "pty" "Keys typed during the run are thrown away before the reboot question"
sc_typeahead_flushed() {
    menu_machine
    EXPECT_REBOOT=0
    # A stray "y" typed while the steps run must not answer "Reboot now?".
    PTY_INPUT="$START_YES|WAIT:Step 2 of|y\\n|WAIT:Reboot now|n\\n"
    invoke
    expect_success
    expect_no_call '^systemctl reboot'
    expect_out_fixed 'OK. Remember to reboot soon.'
}

scenario folder_hint "live" "Script run from a folder named fedora-kde-postinstall: suggests deleting it; other names: no hint"
sc_folder_hint() {
    mkdir -p "$T/dl/fedora-kde-postinstall" "$T/dl/other"
    cp "$SCRIPT" "$T/dl/fedora-kde-postinstall/fedora-kde-setup.sh"
    cp "$SCRIPT" "$T/dl/other/fedora-kde-setup.sh"
    SCRIPT_UNDER_TEST=$T/dl/fedora-kde-postinstall/fedora-kde-setup.sh
    invoke --only dnf --yes --no-reboot
    expect_success
    expect_out_fixed "After the reboot you can delete the download folder: rm -rf $T/dl/fedora-kde-postinstall"
    SCRIPT_UNDER_TEST=$T/dl/other/fedora-kde-setup.sh
    invoke --only maintenance --yes --no-reboot
    expect_success
    expect_no_out 'delete the download folder'
}

scenario folder_hint_dry "dry" "Dry run never suggests deleting the folder"
sc_folder_hint_dry() {
    mkdir -p "$T/dl/fedora-kde-postinstall"
    cp "$SCRIPT" "$T/dl/fedora-kde-postinstall/fedora-kde-setup.sh"
    SCRIPT_UNDER_TEST=$T/dl/fedora-kde-postinstall/fedora-kde-setup.sh
    invoke --only dnf --yes
    expect_success
    expect_no_out 'delete the download folder'
}
