SUMMARY = "KV260 sigverify UIO module autoload configuration"
LICENSE = "AGPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/AGPL-3.0-only;md5=73f1eb20517c55bf9493b7dd6e480788"

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
