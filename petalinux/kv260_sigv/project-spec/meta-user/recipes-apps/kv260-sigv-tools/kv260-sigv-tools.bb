SUMMARY = "KV260 sigverify smoke-test tools"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://kv260_sigv_smoke.py \
           file://kv260_sigv_irq_watch.py \
           file://kv260_sigv_pl_clock_init.py \
           file://solana_sigverify_mvp.py \
"

S = "${WORKDIR}"

inherit allarch

RDEPENDS:${PN} = "python3-core python3-modules"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/kv260_sigv_smoke.py ${D}${bindir}/kv260_sigv_smoke.py
    install -m 0755 ${WORKDIR}/kv260_sigv_irq_watch.py ${D}${bindir}/kv260_sigv_irq_watch.py
    install -m 0755 ${WORKDIR}/kv260_sigv_pl_clock_init.py ${D}${bindir}/kv260_sigv_pl_clock_init.py
    install -m 0755 ${WORKDIR}/solana_sigverify_mvp.py ${D}${bindir}/solana_sigverify_mvp.py
}

FILES:${PN} = "${bindir}/kv260_sigv_smoke.py \
               ${bindir}/kv260_sigv_irq_watch.py \
               ${bindir}/kv260_sigv_pl_clock_init.py \
               ${bindir}/solana_sigverify_mvp.py \
"
