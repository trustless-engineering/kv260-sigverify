# KV260 PetaLinux Project

This project packages the timing-clean KV260 hardware shell from
`fpga/kv260_sigv/build/hw/kv260_sigv.xsa` into a bootable PetaLinux image.

## Host Setup

Vivado/Vitis runs on the host:

```bash
nix develop
source "$HOME/Xilinx/settings-kv260.sh"
```

PetaLinux runs in the Docker-backed Ubuntu 22.04 workspace:

```bash
nix run .#petalinux-shell
source "$HOME/Xilinx/PetaLinux/2025.2/settings.sh"
```

## One-Command Flow

Build the FPGA shell, refresh the PetaLinux project, package `BOOT.BIN`,
stage the deployable outputs, and run the QEMU sanity check:

```bash
nix run .#build-image
```

The staged handoff directory defaults to:

```bash
artifacts/kv260_sigv/
```

Run only the non-hardware boot sanity check against the current image:

```bash
nix develop -c ./tools/kv260_qemu_sanity.py
```

## Rebuild Flow

If the PL design changes, rebuild the XSA first:

```bash
cd fpga/kv260_sigv
make bitstream
```

Import the updated hardware description:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
nix run .#petalinux-prepare -- --require-xsa
cd "$REPO_ROOT/petalinux/kv260_sigv"
petalinux-config --silentconfig \
  --get-hw-description "$REPO_ROOT/fpga/kv260_sigv/build/hw/kv260_sigv.xsa"
```

Build the Linux image:

```bash
petalinux-build
```

Package the boot image:

```bash
petalinux-package boot --force \
  --fsbl images/linux/zynqmp_fsbl.elf \
  --u-boot \
  --fpga images/linux/system.bit \
  --pmufw images/linux/pmufw.elf \
  --atf images/linux/bl31.elf
```

## Project Additions

- `project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`
  exposes the control block and both BRAM windows as `generic-uio`; the control
  node now carries the PL completion IRQ once the refreshed XSA is imported.
- `project-spec/meta-user/recipes-kernel/linux/linux-xlnx/bsp.cfg`
  enables `UIO` and `UIO_PDRV_GENIRQ`.
- `project-spec/meta-user/recipes-apps/kv260-sigv-uio`
  autoloads `uio_pdrv_genirq` with `of_id=generic-uio`.
- `project-spec/meta-user/recipes-apps/kv260-sigv-tools`
  installs `kv260_sigv_smoke.py` and `solana_sigverify_mvp.py`; the smoke tool
  now auto-discovers the UIO regions and blocks on the control IRQ instead of
  polling when `/dev/uio*` is available.
- `project-spec/meta-user/recipes-apps/kv260-sigv-daemon`
  builds and installs the Rust `kv260_sigv_daemon` binary so the target image
  exposes the Unix-socket HTTP verification API directly from PS/Linux; the
  package also installs and enables `kv260_sigv_daemon.service` for boot-time
  startup on `/run/kv260-sigv.sock`.

## Expected Artifacts

The main outputs land in `images/linux/`:

- `BOOT.BIN`
- `image.ub`
- `system.dtb`
- `rootfs.ext4`
- `rootfs.tar.gz`

The staged output also includes:

- `kv260_sigv.xsa`
- `reports/timing_summary.rpt`
- `reports/utilization.rpt`
- `reports/clock_utilization.rpt`
- `SHA256SUMS`
- `manifest.json`
- `qemu-sanity.raw.log` when the build flow runs the QEMU check

## Board Bring-Up

Once the physical KV260 is available:

1. On a stock KV260 starter kit, keep the board in its default `QSPI` primary
   boot mode and use the SD card as the secondary boot medium.
2. Copy `boot.scr`, `image.ub`, `system.bit`, and `uEnv.txt` to the FAT SD boot
   partition. `uEnv.txt` loads `system.bit` with `fpga loadb` before Linux boots.
3. Boot the board with the generated image.
4. On target, use `/usr/bin/kv260_sigv_smoke.py` against the exposed UIO
   devices to validate the register block, BRAM windows, interrupt delivery,
   batch-id snapshot behavior, and valid/invalid signature mask behavior.
5. Confirm `systemctl status kv260_sigv_daemon` is healthy, then query
   `GET /v1/status`, `POST /v1/verify-transaction`, and `POST /v1/verify-batch`
   over `/run/kv260-sigv.sock`.
