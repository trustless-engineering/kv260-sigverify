from __future__ import annotations

import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
import re


REPO_ROOT = Path(__file__).resolve().parents[2]
IMAGES_DIR = REPO_ROOT / "petalinux" / "kv260_sigv" / "images" / "linux"
SYSTEM_DTB = IMAGES_DIR / "system.dtb"
ROOTFS_TAR = IMAGES_DIR / "rootfs.tar.gz"
CANONICAL_SMOKE = REPO_ROOT / "tools" / "kv260_sigv_smoke.py"
CANONICAL_IRQ_WATCH = REPO_ROOT / "tools" / "kv260_sigv_irq_watch.py"
CANONICAL_PL_CLOCK_INIT = REPO_ROOT / "tools" / "kv260_sigv_pl_clock_init.py"
PACKAGED_SMOKE = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-tools"
    / "files"
    / "kv260_sigv_smoke.py"
)
PACKAGED_IRQ_WATCH = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-tools"
    / "files"
    / "kv260_sigv_irq_watch.py"
)
PACKAGED_PL_CLOCK_INIT = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-tools"
    / "files"
    / "kv260_sigv_pl_clock_init.py"
)
CANONICAL_MVP = REPO_ROOT / "tools" / "solana_sigverify_mvp.py"
PACKAGED_MVP = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-tools"
    / "files"
    / "solana_sigverify_mvp.py"
)
RECIPE_PATH = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-tools"
    / "kv260-sigv-tools.bb"
)
CANONICAL_DAEMON_DIR = REPO_ROOT / "tools" / "kv260_sigv_daemon"
PACKAGED_DAEMON_DIR = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-daemon"
    / "files"
)
DAEMON_RECIPE_PATH = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-daemon"
    / "kv260-sigv-daemon.bb"
)
DAEMON_CRATES_PATH = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-apps"
    / "kv260-sigv-daemon"
    / "kv260-sigv-daemon-crates.inc"
)
PETALINUX_BSP_CONF = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "conf"
    / "petalinuxbsp.conf"
)
SYSTEM_USER_DTSI = (
    REPO_ROOT
    / "petalinux"
    / "kv260_sigv"
    / "project-spec"
    / "meta-user"
    / "recipes-bsp"
    / "device-tree"
    / "files"
    / "system-user.dtsi"
)


def _tree_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*") if path.is_file())


def _built_image_is_current() -> bool:
    source_paths = [
        CANONICAL_SMOKE,
        PACKAGED_SMOKE,
        CANONICAL_MVP,
        PACKAGED_MVP,
        RECIPE_PATH,
        PETALINUX_BSP_CONF,
        DAEMON_RECIPE_PATH,
        DAEMON_CRATES_PATH,
        *_tree_files(CANONICAL_DAEMON_DIR),
        *_tree_files(PACKAGED_DAEMON_DIR),
    ]
    latest_source_mtime = max(path.stat().st_mtime for path in source_paths)
    return ROOTFS_TAR.stat().st_mtime >= latest_source_mtime


def _quoted_property(text: str, key: str) -> str:
    match = re.search(rf'{re.escape(key)} = "([^"]+)";', text)
    if match is None:
        raise AssertionError(f"missing {key} property")
    return match.group(1)


class Kv260PetalinuxSourceParityTests(unittest.TestCase):
    def test_packaged_sources_match_repo_tools(self) -> None:
        self.assertEqual(PACKAGED_SMOKE.read_text(), CANONICAL_SMOKE.read_text())
        self.assertEqual(PACKAGED_IRQ_WATCH.read_text(), CANONICAL_IRQ_WATCH.read_text())
        self.assertEqual(PACKAGED_PL_CLOCK_INIT.read_text(), CANONICAL_PL_CLOCK_INIT.read_text())
        self.assertEqual(PACKAGED_MVP.read_text(), CANONICAL_MVP.read_text())

    def test_packaged_daemon_sources_match_repo_crate(self) -> None:
        canonical_files = [path.relative_to(CANONICAL_DAEMON_DIR) for path in _tree_files(CANONICAL_DAEMON_DIR)]
        packaged_files = [path.relative_to(PACKAGED_DAEMON_DIR) for path in _tree_files(PACKAGED_DAEMON_DIR)]

        self.assertEqual(packaged_files, canonical_files)
        for relative_path in canonical_files:
            self.assertEqual(
                (PACKAGED_DAEMON_DIR / relative_path).read_bytes(),
                (CANONICAL_DAEMON_DIR / relative_path).read_bytes(),
                str(relative_path),
            )

    def test_recipe_installs_both_tools_as_executables(self) -> None:
        recipe = RECIPE_PATH.read_text()
        self.assertIn("install -m 0755 ${WORKDIR}/kv260_sigv_smoke.py ${D}${bindir}/kv260_sigv_smoke.py", recipe)
        self.assertIn("install -m 0755 ${WORKDIR}/kv260_sigv_irq_watch.py ${D}${bindir}/kv260_sigv_irq_watch.py", recipe)
        self.assertIn(
            "install -m 0755 ${WORKDIR}/kv260_sigv_pl_clock_init.py ${D}${bindir}/kv260_sigv_pl_clock_init.py",
            recipe,
        )
        self.assertIn("install -m 0755 ${WORKDIR}/solana_sigverify_mvp.py ${D}${bindir}/solana_sigverify_mvp.py", recipe)

    def test_daemon_recipe_builds_and_installs_binary(self) -> None:
        recipe = DAEMON_RECIPE_PATH.read_text()
        crates = DAEMON_CRATES_PATH.read_text()
        self.assertIn("inherit cargo cargo-update-recipe-crates systemd", recipe)
        self.assertIn("require kv260-sigv-daemon-crates.inc", recipe)
        self.assertIn("file://kv260_sigv_daemon.service", recipe)
        self.assertIn('SYSTEMD_SERVICE:${PN} = "kv260_sigv_daemon.service"', recipe)
        self.assertIn('SYSTEMD_AUTO_ENABLE:${PN} = "enable"', recipe)
        self.assertIn("ExecStartPre=/usr/bin/kv260_sigv_pl_clock_init.py --quiet", (PACKAGED_DAEMON_DIR / "kv260_sigv_daemon.service").read_text())
        self.assertIn(
            "install -m 0755 ${B}/target/${CARGO_TARGET_SUBDIR}/kv260_sigv_daemon ${D}${bindir}/kv260_sigv_daemon",
            recipe,
        )
        self.assertIn(
            "install -m 0644 ${WORKDIR}/kv260_sigv_daemon.service ${D}${systemd_system_unitdir}/kv260_sigv_daemon.service",
            recipe,
        )
        self.assertIn("crate://crates.io/axum/", crates)
        self.assertIn(".sha256sum", crates)

    def test_petalinux_image_install_includes_daemon_package(self) -> None:
        self.assertIn("kv260-sigv-daemon", PETALINUX_BSP_CONF.read_text())


@unittest.skipUnless(SYSTEM_DTB.exists(), "requires a built KV260 PetaLinux image")
class Kv260PetalinuxArtifactTests(unittest.TestCase):
    def test_system_dtb_exposes_expected_console_and_uio_nodes(self) -> None:
        dtc = shutil.which("dtc")
        if dtc is None:
            self.skipTest("dtc is required")

        with tempfile.TemporaryDirectory() as tmpdir:
            dts_path = Path(tmpdir) / "system.dts"
            subprocess.run(
                [dtc, "-I", "dtb", "-O", "dts", "-o", str(dts_path), str(SYSTEM_DTB)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            text = dts_path.read_text()

        source_dtsi = SYSTEM_USER_DTSI.read_text()
        bootargs = _quoted_property(source_dtsi, "bootargs")
        stdout_path = _quoted_property(source_dtsi, "stdout-path")

        self.assertIn(f'bootargs = "{bootargs}";', text)
        self.assertIn(f'stdout-path = "{stdout_path}";', text)
        self.assertIn('serial0 = "/axi/serial@ff000000";', text)
        self.assertIn('serial1 = "/axi/serial@ff010000";', text)
        self.assertIn('compatible = "generic-uio";', text)
        self.assertIn('reg = <0x00 0xa0000000 0x00 0x10000>;', text)
        self.assertIn('reg = <0x00 0xa0010000 0x00 0x10000>;', text)
        self.assertIn('reg = <0x00 0xa0020000 0x00 0x10000>;', text)

    def test_rootfs_contains_uio_loader_and_sigverify_tools(self) -> None:
        if not _built_image_is_current():
            self.skipTest("the built rootfs predates the current tool sources and recipes")

        required = {
            "./etc/modprobe.d/uio-pdrv-genirq.conf",
            "./etc/modules-load.d/kv260-sigv-uio.conf",
            "./etc/systemd/system/multi-user.target.wants/kv260_sigv_daemon.service",
            "./usr/lib/systemd/system/kv260_sigv_daemon.service",
            "./usr/bin/kv260_sigv_daemon",
            "./usr/bin/kv260_sigv_smoke.py",
            "./usr/bin/kv260_sigv_irq_watch.py",
            "./usr/bin/kv260_sigv_pl_clock_init.py",
            "./usr/bin/solana_sigverify_mvp.py",
        }

        with tarfile.open(ROOTFS_TAR, "r:gz") as archive:
            names = set(archive.getnames())
            self.assertTrue(required.issubset(names), required - names)

            daemon_member = archive.getmember("./usr/bin/kv260_sigv_daemon")
            smoke_member = archive.getmember("./usr/bin/kv260_sigv_smoke.py")
            irq_watch_member = archive.getmember("./usr/bin/kv260_sigv_irq_watch.py")
            mvp_member = archive.getmember("./usr/bin/solana_sigverify_mvp.py")
            smoke_bytes = archive.extractfile(smoke_member).read()
            irq_watch_bytes = archive.extractfile(irq_watch_member).read()
            mvp_bytes = archive.extractfile(mvp_member).read()

        self.assertEqual(daemon_member.mode & 0o111, 0o111)
        self.assertEqual(smoke_member.mode & 0o111, 0o111)
        self.assertEqual(irq_watch_member.mode & 0o111, 0o111)
        self.assertEqual(mvp_member.mode & 0o111, 0o111)
        self.assertEqual(smoke_bytes, CANONICAL_SMOKE.read_bytes())
        self.assertEqual(irq_watch_bytes, CANONICAL_IRQ_WATCH.read_bytes())
        self.assertEqual(mvp_bytes, CANONICAL_MVP.read_bytes())
