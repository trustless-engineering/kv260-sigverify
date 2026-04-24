SUMMARY = "KV260 sigverify daemon"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
           file://Cargo.toml \
           file://Cargo.lock \
           file://README.md \
           file://kv260_sigv_daemon.service \
           file://src/accelerator.rs \
           file://src/api.rs \
           file://src/error.rs \
           file://src/lib.rs \
           file://src/main.rs \
           file://src/parser.rs \
"

require kv260-sigv-daemon-crates.inc

S = "${WORKDIR}"

inherit cargo cargo-update-recipe-crates systemd

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "kv260_sigv_daemon.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${CARGO_TARGET_SUBDIR}/kv260_sigv_daemon ${D}${bindir}/kv260_sigv_daemon
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kv260_sigv_daemon.service ${D}${systemd_system_unitdir}/kv260_sigv_daemon.service
}

FILES:${PN} = "${bindir}/kv260_sigv_daemon ${systemd_system_unitdir}/kv260_sigv_daemon.service"
