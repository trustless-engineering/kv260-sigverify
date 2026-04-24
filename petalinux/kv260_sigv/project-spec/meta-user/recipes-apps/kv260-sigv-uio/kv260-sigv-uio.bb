SUMMARY = "KV260 sigverify UIO module autoload configuration"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://kv260-sigv-uio.conf \
           file://uio-pdrv-genirq.conf \
"

S = "${WORKDIR}"

inherit allarch

RDEPENDS:${PN} = "kernel-module-uio-pdrv-genirq"

do_install() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -d ${D}${sysconfdir}/modprobe.d
    install -m 0644 ${WORKDIR}/kv260-sigv-uio.conf ${D}${sysconfdir}/modules-load.d/kv260-sigv-uio.conf
    install -m 0644 ${WORKDIR}/uio-pdrv-genirq.conf ${D}${sysconfdir}/modprobe.d/uio-pdrv-genirq.conf
}

FILES:${PN} = "${sysconfdir}/modules-load.d/kv260-sigv-uio.conf \
               ${sysconfdir}/modprobe.d/uio-pdrv-genirq.conf \
"
