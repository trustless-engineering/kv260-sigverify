#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Bootstrap the supported AMD toolchain host for KV260 work.

This script is intended for a supported x86_64 Linux machine.
Recommended target for the full KV260 flow:
  - Ubuntu 22.04.x x86_64
  - Vivado/Vitis 2025.2
  - PetaLinux 2025.2

The AMD installer payloads must already be downloaded locally.

Usage:
  bootstrap_kv260_toolchain_host.sh \
    --vitis-installer /path/to/FPGAs_AdaptiveSoCs_Unified_*.bin \
    --petalinux-installer /path/to/petalinux-v2025.2-final-installer.run \
    [--install-root "$HOME/Xilinx"] \
    [--product "Vitis"] \
    [--edition "Vitis Unified Software Platform"] \
    [--modules "Zynq UltraScale+ MPSoC:1,Engineering Sample Devices:0,DocNav:1"] \
    [--skip-vivado] \
    [--skip-petalinux]

Notes:
  - Vivado/Vitis install requires accepting AMD's EULAs.
  - PetaLinux must be installed by a non-root user.
  - The script writes an env helper at:
      <install-root>/settings-kv260.sh
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [[ -f "$path" ]] || die "missing file: $path"
}

linux_id() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}"
    else
        printf 'unknown\n'
    fi
}

linux_version_id() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${VERSION_ID:-unknown}"
    else
        printf 'unknown\n'
    fi
}

warn_if_host_not_recommended() {
    local distro version
    distro="$(linux_id)"
    version="$(linux_version_id)"

    if [[ "$(uname -s)" != "Linux" ]]; then
        die "this script only supports Linux hosts"
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        die "this script only supports x86_64 hosts"
    fi

    if [[ "$distro" != "ubuntu" || "${version%%.*}" != "22" ]]; then
        cat >&2 <<EOF
warning: recommended host for the full KV260 flow is Ubuntu 22.04.x x86_64.
detected host: ${distro} ${version}
continuing because Vivado may still be supported, but PetaLinux 2025.2 support
must be checked against AMD's current release notes for this exact distro/version.
EOF
    fi

    if [[ -L /bin/sh ]] && [[ "$(readlink /bin/sh)" != *bash ]]; then
        cat >&2 <<'EOF'
warning: /bin/sh is not bash.
PetaLinux 2025.2 requires /bin/sh to be bash on the host system.
On Ubuntu, AMD documents using:
  sudo dpkg-reconfigure dash
EOF
    fi
}

write_env_helper() {
    local helper="$1"
    local install_root="$2"
    cat >"$helper" <<EOF
#!/usr/bin/env bash
set -eo pipefail

export PATH="\$HOME/.local/bin:\$PATH"

if [[ -f "${install_root}/Vivado/2025.2/settings64.sh" ]]; then
    # shellcheck disable=SC1091
    source "${install_root}/Vivado/2025.2/settings64.sh"
fi

if [[ -f "${install_root}/2025.2/Vivado/settings64.sh" ]]; then
    # shellcheck disable=SC1091
    source "${install_root}/2025.2/Vivado/settings64.sh"
fi

if [[ -f "${install_root}/Vitis/2025.2/settings64.sh" ]]; then
    # shellcheck disable=SC1091
    source "${install_root}/Vitis/2025.2/settings64.sh"
fi

if [[ -f "${install_root}/2025.2/Vitis/settings64.sh" ]]; then
    # shellcheck disable=SC1091
    source "${install_root}/2025.2/Vitis/settings64.sh"
fi

if [[ -f "${install_root}/PetaLinux/2025.2/settings.sh" ]]; then
    # shellcheck disable=SC1091
    source "${install_root}/PetaLinux/2025.2/settings.sh"
fi
EOF
    chmod +x "$helper"
}

install_vivado() {
    local installer="$1"
    local install_root="$2"
    local product="$3"
    local edition="$4"
    local modules="$5"
    local extract_dir=""
    local config_file=""
    local status=0

    require_file "$installer"
    chmod +x "$installer"

    mkdir -p "$install_root"
    [[ -w "$install_root" ]] || die "install root is not writable: $install_root"

    extract_dir="$(mktemp -d)"
    config_file="${extract_dir}/install_config.txt"

    echo "Extracting AMD web installer to ${extract_dir}"
    "$installer" --keep --noexec --target "$extract_dir" >/dev/null
    [[ -x "${extract_dir}/xsetup" ]] || die "xsetup not found after extracting installer"

    cat >"$config_file" <<EOF
#### ${edition} Install Configuration ####
Edition=${edition}

Product=${product}

# Path where AMD software will be installed.
Destination=${install_root}

# Choose the Products/Devices that you would like to install.
Modules=${modules}
EOF

    echo "Installing Vivado/Vitis to ${install_root}"
    set +e
    "${extract_dir}/xsetup" \
        -a XilinxEULA,3rdPartyEULA \
        -b Install \
        -c "$config_file"
    status=$?
    set -e
    rm -rf "$extract_dir"
    return "$status"
}

install_petalinux() {
    local installer="$1"
    local install_dir="$2"
    local local_installer=""

    require_file "$installer"
    mkdir -p "$install_dir"
    [[ -w "$install_dir" ]] || die "install dir is not writable: $install_dir"

    local_installer="$(mktemp)"
    cp "$installer" "$local_installer"
    chmod +x "$local_installer"

    echo "Installing PetaLinux to ${install_dir}"
    "$local_installer" -y --dir "$install_dir"
    rm -f "$local_installer"
}

main() {
    local vivado_installer=""
    local petalinux_installer=""
    local install_root="${HOME}/Xilinx"
    local product="Vitis"
    local edition="Vitis Unified Software Platform"
    local modules="Zynq UltraScale+ MPSoC:1,Engineering Sample Devices:0,DocNav:1"
    local skip_vivado=0
    local skip_petalinux=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vitis-installer|--vivado-installer)
                vivado_installer="$2"
                shift 2
                ;;
            --petalinux-installer)
                petalinux_installer="$2"
                shift 2
                ;;
            --install-root)
                install_root="$2"
                shift 2
                ;;
            --product)
                product="$2"
                shift 2
                ;;
            --edition)
                edition="$2"
                shift 2
                ;;
            --modules)
                modules="$2"
                shift 2
                ;;
            --skip-vivado)
                skip_vivado=1
                shift
                ;;
            --skip-petalinux)
                skip_petalinux=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    warn_if_host_not_recommended

    if [[ "$skip_vivado" -eq 0 && -z "$vivado_installer" ]]; then
        die "--vitis-installer is required unless --skip-vivado is used"
    fi
    if [[ "$skip_petalinux" -eq 0 && -z "$petalinux_installer" ]]; then
        die "--petalinux-installer is required unless --skip-petalinux is used"
    fi

    if [[ "$skip_vivado" -eq 0 ]]; then
        install_vivado "$vivado_installer" "$install_root" "$product" "$edition" "$modules"
    fi

    if [[ "$skip_petalinux" -eq 0 ]]; then
        install_petalinux "$petalinux_installer" "${install_root}/PetaLinux/2025.2"
    fi

    write_env_helper "${install_root}/settings-kv260.sh" "$install_root"

    cat <<EOF
Completed.

Environment helper:
  source "${install_root}/settings-kv260.sh"

Expected tools after install:
  vivado
  xsct
  petalinux-create
EOF
}

main "$@"
