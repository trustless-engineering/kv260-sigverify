#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="${KV260_PETALINUX_IMAGE:-txnverify-kv260-petalinux:2025.2}"
STATE_ROOT="${KV260_PETALINUX_STATE_ROOT:-${HOME}/.cache/txnverify-fpga/kv260-petalinux}"
CONTAINER_USER="${KV260_PETALINUX_USER:-$(id -un)}"
CONTAINER_HOME="/home/${CONTAINER_USER}"
CONTAINER_HOME_HOST="${STATE_ROOT}/home"
CONTAINER_INSTALL_ROOT="${CONTAINER_HOME}/Xilinx"
HOST_DOWNLOADS="${KV260_PETALINUX_HOST_DOWNLOADS:-${HOME}/Downloads}"
DOCKERFILE_DIR="${REPO_ROOT}/tools/docker/kv260-petalinux"

usage() {
    cat <<EOF
KV260 Ubuntu 22.04 Docker workspace for PetaLinux 2025.2.

Usage:
  $(basename "$0") build
  $(basename "$0") shell
  $(basename "$0") doctor
  $(basename "$0") exec '<command>'
  $(basename "$0") install-petalinux /absolute/path/to/petalinux-v2025.2-final-installer.run

Environment overrides:
  KV260_PETALINUX_IMAGE
  KV260_PETALINUX_STATE_ROOT
  KV260_PETALINUX_USER
  KV260_PETALINUX_HOST_DOWNLOADS

Notes:
  - The repo is mounted into the container at the same absolute path.
  - Persistent container state lives under:
      ${STATE_ROOT}
  - The container install root is:
      ${CONTAINER_INSTALL_ROOT}
  - Use native host Vivado/Vitis and containerized PetaLinux on this machine.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

ensure_state_dirs() {
    mkdir -p "${CONTAINER_HOME_HOST}"
    mkdir -p "${CONTAINER_HOME_HOST}/Xilinx"
}

image_exists() {
    docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

build_image() {
    ensure_state_dirs
    docker build \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg HOST_GID="$(id -g)" \
        --build-arg HOST_USER="${CONTAINER_USER}" \
        --tag "${IMAGE_NAME}" \
        "${DOCKERFILE_DIR}"
}

ensure_image() {
    if ! image_exists; then
        build_image
    fi
}

docker_run() {
    local -a docker_args
    docker_args=(
        run
        --rm
        --init
        --hostname kv260-petalinux
        -e HOME="${CONTAINER_HOME}"
        -e USER="${CONTAINER_USER}"
        -e REPO_ROOT="${REPO_ROOT}"
        -e INSTALL_ROOT="${CONTAINER_INSTALL_ROOT}"
        -v "${REPO_ROOT}:${REPO_ROOT}"
        -v "${CONTAINER_HOME_HOST}:${CONTAINER_HOME}"
        -w "${REPO_ROOT}"
    )

    if [[ -t 0 && -t 1 ]]; then
        docker_args+=(-it)
    fi

    if [[ -d "${HOST_DOWNLOADS}" ]]; then
        docker_args+=(-v "${HOST_DOWNLOADS}:/mnt/host-downloads:ro")
    fi

    if [[ -n "${KV260_DOCKER_EXTRA_MOUNT_SRC:-}" ]]; then
        docker_args+=(-v "${KV260_DOCKER_EXTRA_MOUNT_SRC}:${KV260_DOCKER_EXTRA_MOUNT_DST}:${KV260_DOCKER_EXTRA_MOUNT_MODE:-rw}")
    fi

    docker_args+=("${IMAGE_NAME}")
    docker "${docker_args[@]}" "$@"
}

cmd_build() {
    build_image
}

cmd_shell() {
    ensure_image
    docker_run /bin/bash -l
}

cmd_doctor() {
    ensure_image
    docker_run bash -lc '
        set -euo pipefail
        source /etc/os-release
        printf "PRETTY_NAME=%s\n" "$PRETTY_NAME"
        printf "/bin/sh -> %s\n" "$(readlink -f /bin/sh)"
        ldconfig -p | grep "libtinfo\\.so\\.5"
        printf "USER=%s\n" "$(whoami)"
        printf "HOME=%s\n" "$HOME"
        ./tools/bootstrap_kv260_toolchain_host.sh --help >/dev/null
        echo "BOOTSTRAP=ok"
    '
}

cmd_exec() {
    ensure_image
    [[ $# -gt 0 ]] || die "exec requires a command string"
    docker_run bash -lc "$*"
}

cmd_install_petalinux() {
    ensure_image
    local installer installer_abs installer_dir installer_name
    installer="${1:-}"
    [[ -n "${installer}" ]] || die "install-petalinux requires an installer path"
    installer_abs="$(readlink -f "${installer}")"
    [[ -f "${installer_abs}" ]] || die "missing installer: ${installer_abs}"
    installer_dir="$(dirname "${installer_abs}")"
    installer_name="$(basename "${installer_abs}")"

    KV260_DOCKER_EXTRA_MOUNT_SRC="${installer_dir}" \
    KV260_DOCKER_EXTRA_MOUNT_DST=/mnt/petalinux-installer \
    KV260_DOCKER_EXTRA_MOUNT_MODE=ro \
    docker_run bash -lc "
        set -euo pipefail
        ./tools/bootstrap_kv260_toolchain_host.sh \
          --skip-vivado \
          --petalinux-installer /mnt/petalinux-installer/${installer_name} \
          --install-root \"${CONTAINER_INSTALL_ROOT}\"
    "
}

main() {
    local cmd="${1:-shell}"
    shift || true

    case "${cmd}" in
        build)
            cmd_build "$@"
            ;;
        shell)
            cmd_shell "$@"
            ;;
        doctor)
            cmd_doctor "$@"
            ;;
        exec)
            cmd_exec "$@"
            ;;
        install-petalinux)
            cmd_install_petalinux "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            die "unknown command: ${cmd}"
            ;;
    esac
}

main "$@"
