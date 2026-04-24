# KV260 Current Status

Status date: 2026-04-24

This note captures the KV260 bring-up state at the point work stopped. It is
intended as the resume point for the next hardware session.

## Latest Update

- 2026-04-24 optimization update: the repo now has a 100 MHz
  resource/performance refactor that meets the sub-`1 ms` RTL cycle target but
  is not yet a timing-clean deployable bitstream.
- The refactor limits the KV260 full bitstream image to one verifier lane,
  switches the PL0 clock target to 100 MHz (`PL0_REF_CTRL=0x01010F00`), and
  replaces the point-core multiplier path with a 5x51 wide multiplier.
- Current RTL cycle measurements are `97,680` cycles for strict valid verify,
  `98,340` cycles for Agave/Zebra-mode valid verify, `14,732` cycles for
  invalid decode rejection, and `97,709` cycles for the KV260 wrapper's last
  processed job.
- The latest point-core fanout cut defaults the multiplier operand staging
  registers (`fe_a`/`fe_b`) every cycle. This removes the previous
  `point_core/fe_a_reg[*]/CE` worst path.
- The latest measured physopt checkpoint used `58,634` LUTs, `42,118` FFs,
  `33` RAMB36 blocks, and `45` DSP48E2 blocks, but still stopped at
  `WNS=-2.403 ns` with `2,492` failing setup endpoints. The current worst
  paths now run from `point_core/step_reg[1]_rep__2` into
  `point_core/out_z_reg[*]/CE`, with related `fe_a_reg[*]/D` and replicated
  point/aux step paths nearby.
- A one-cycle public output/done bus experiment was tested and rejected: it
  improved RTL latency but worsened implementation timing to about
  `WNS=-3.16 ns` during physopt by exposing broader aux/add step-control paths.
- The current live/staged hardware payload described below remains the
  previously validated timing-clean `full` bitstream until the 100 MHz branch
  closes timing.
- The current validated hardware payload is now `full`, not `bringup`.
- The remaining verifier failure was not in the Ed25519 datapath. Temporary
  debug registers showed the full core was latching each `32-bit` job word four
  times, which pointed to a BRAM Port B addressing bug rather than bad
  signature math.
- The root cause was in
  [fpga/kv260_sigv/src/kv260_sigv_top.v](../fpga/kv260_sigv/src/kv260_sigv_top.v):
  the core was producing BRAM word addresses, while Vivado `blk_mem_gen` Port B
  expects byte addresses. The fix now shifts the core job/message addresses left
  by `2` before driving the Port B buses.
- A fresh bitstream-only Vivado rebuild of the `full` image produced
  `system.bit=70b1cfca73dd4db5a8217dfe9e24fb90c40b780dd1c56bc6f107e81a715cd82a`
  with timing closed at `WNS=2.608 ns`, `WHS=0.010 ns`.
- That bitstream was copied onto the live SD boot partition and the board was
  rebooted through the stock QSPI plus SD boot path. The mounted boot partition
  on the running board now reports the same `system.bit` hash.
- On the rebooted board, HTTP `GET /v1/status` on `/run/kv260-sigv.sock` now
  returns `200 OK` with `hardware_mode:"full"`, `hardware_api_version:1`, and
  `ready:true`, and `kv260_sigv_smoke.py --expected-hw-mode full probe` reports
  `HW_MAGIC=0x53494756` and `HW_BUILD=0x00000100`.
- The bounded `full` smoke sequence now passes end to end on hardware:
  `valid -> [true]`, `invalid -> [false]`, and `pair -> [true, false]`.
- One test-harness constraint is now explicit: the daemon uses a single
  monotonic batch counter, so concurrent smoke runs can collide with
  `snapshot batch_id mismatch`. Batch validation should stay serialized.
- The staged host artifacts in
  [artifacts/kv260_sigv](../artifacts/kv260_sigv) have
  been refreshed again. The staged `system.bit` and `manifest.json` now both
  report the validated `full` bitstream hash
  `70b1cfca73dd4db5a8217dfe9e24fb90c40b780dd1c56bc6f107e81a715cd82a`.
- The earlier "MMIO hang" is now explained. Under the stock QSPI/U-Boot plus SD
  boot path, Linux reaches the final UIO nodes with `pl0_ref` still disabled.
  On the live board, `pl0_ref` showed `clk_prepare_count=0`,
  `clk_enable_count=0`, and `CRL_APB.PL0_REF_CTRL` (`0xff5e00c0`) was still at
  `0x00010a00`.
- A bringup-only divider image proved the distinction cleanly: forced-high
  `irq` worked immediately, but an `ap_clk`-driven divider produced no
  interrupts until `PL0_REF_CTRL` was programmed.
- The required PS clock programming is present in the generated XSA handoff.
  `psu_init.c` programs `PL0_REF_CTRL` with mask `0x013f3f07` and value
  `0x01011e00`. Writing that value on the live board immediately made the
  bringup divider interrupt and made raw AXI-Lite reads of `HW_MAGIC` /
  `HW_BUILD` work.
- The repo now contains a persistent Linux-side fix:
  [tools/kv260_sigv_pl_clock_init.py](../tools/kv260_sigv_pl_clock_init.py)
  plus an `ExecStartPre` hook in
  [tools/kv260_sigv_daemon/kv260_sigv_daemon.service](../tools/kv260_sigv_daemon/kv260_sigv_daemon.service).
  Matching packaged copies were added to the PetaLinux recipes.
- That helper and service hook were installed manually onto the live board and
  validated against the full hardware image. With `PL0_REF_CTRL` deliberately
  forced back to the broken stock value `0x00010a00`, restarting
  `kv260_sigv_daemon.service` now succeeds, raw UIO reads return
  `HW_MAGIC=0x53494756` and `HW_BUILD=0x00000100`, and HTTP
  `GET /v1/status` on `/run/kv260-sigv.sock` returns `200 OK`.
- The PetaLinux image has now been rebuilt, and the refreshed
  [artifacts/kv260_sigv](../artifacts/kv260_sigv)
  rootfs does contain `/usr/bin/kv260_sigv_pl_clock_init.py` plus the updated
  `kv260_sigv_daemon.service` with `ExecStartPre=/usr/bin/kv260_sigv_pl_clock_init.py --quiet`.
- The staged SD image was copied onto the card from the host and then booted
  successfully. From the running board, the mounted FAT partition at
  `/run/media/KV260BOOT-mmcblk0p1` matches the staged hashes for `BOOT.BIN`,
  `image.ub`, `system.bit`, `boot.scr`, and `uEnv.txt` exactly.
- The SD boot partition was then refreshed in place from that rebuilt stage.
  The current on-card hashes are:
  `BOOT.BIN=c48645bc72ac761634670f90771f5ca02f7648893641aa34d4e4806b3201a40f`,
  `image.ub=33355f0525de17eb092e5abd847ba8406c14e037a88f9d62c87a099cf2cc7639`,
  `system.bit=c4e58202e98b9c4d64389a0721910a920753971109cd42f37d19cdd5e4597a0e`,
  `boot.scr=6c555e630e15ae1c7446f606cb99cfe5c52a0fde4e9deb2fa4e418c5d598b608`,
  `uEnv.txt=c585eafd30f1f682eb6eae32b7ba1b0e9d4e7a2a7943e0dcb8cc61f37db20451`.
- `bringup` mode was still useful in the middle of the session to prove the
  repaired control path safely. On that intermediate image, `/v1/status`
  returned `200 OK`, `/usr/bin/kv260_sigv_irq_watch.py` observed autonomous
  interrupts on `/dev/uio2`, and
  `kv260_sigv_smoke.py --expected-hw-mode bringup --wait-mode poll run-default --mode pair`
  completed successfully after fixing the smoke tool to use aligned MMIO writes
  instead of bulk `mmap` writes plus `mmap.flush()`.
- SSH host key state changed across this fresh rootfs boot, and the staged
  image did not preserve root authorized keys. Host access was recovered by
  reinstalling the host's `id_ed25519.pub` into `/root/.ssh/authorized_keys`
  over UART. SSH to `root@192.168.0.241` now works again.
- The active SD boot path is now known. `boot.scr` is the standard PetaLinux
  distro boot script and `uEnv.txt` defines:

```text
uenvcmd=fatload ${devtype} ${devnum}:${distro_bootpart} 0x30000000 system.bit && fpga loadb 0 0x30000000 ${filesize}
```

  So the current boot flow is still the stock QSPI/U-Boot path loading the PL
  bitstream from SD before booting `image.ub`.
- The Linux side is healthy after that boot: `end0` comes up at
  `192.168.0.241`, `/sys/class/fpga_manager/fpga0/state` reports `operating`,
  the expected `/dev/uio0..6` nodes exist with the final address map, and
  `kv260_sigv_daemon.service` is running with `/run/kv260-sigv.sock` present.
- The SD card is not currently write-protected from target Linux. On this boot,
  `cat /sys/block/mmcblk0/ro` returned `0` and the FAT partition mounted read-
  write under `/run/media/KV260BOOT-mmcblk0p1`.
- The daemon's `/v1/status` endpoint is now safe on the live board after the
  helper is installed, because the missing `pl0_ref` clock is enabled before
  the daemon probes hardware.
- A KV260-specific host udev rule and installer are now staged in
  [tools/host/kv260-ftdi-jtag.rules](../tools/host/kv260-ftdi-jtag.rules)
  and
  [tools/host/install_kv260_ftdi_jtag_rules.sh](../tools/host/install_kv260_ftdi_jtag_rules.sh).
  This custom rule is intentionally narrower than AMD's stock FTDI rule: it
  grants `plugdev` access to the raw FT4232 USB node, sets
  `ID_MM_DEVICE_IGNORE=1`, and unbinds only FTDI interface `00` so the JTAG
  side is freed while the UART console on interface `01` remains available.
- That custom host rule has now been installed at
  `/etc/udev/rules.d/59-kv260-ftdi-jtag.rules`, and the KV260 USB device was
  re-enumerated in software. The raw USB node now lands as `root:plugdev` and
  FTDI interface `00` stays unbound from `ftdi_sio`.
- Even after that host-side fix, `hw_server` plus XSCT still shows no JTAG
  targets. A bounded experiment temporarily unbound interface `01` as well,
  which removed the UART console but still did not make the JTAG chain appear.
  So the remaining JTAG visibility problem is not explained by simple FTDI
  driver ownership/binding alone.
- Matching staged boot artifacts now exist in
  [artifacts/kv260_sigv](../artifacts/kv260_sigv),
  including `BOOT.BIN`, `image.ub`, `system.bit`, `uEnv.txt`, the XSA, and
  implementation reports. The staged manifest now reports the active hardware
  mode as `full`, `system.bit` SHA-256
  `70b1cfca73dd4db5a8217dfe9e24fb90c40b780dd1c56bc6f107e81a715cd82a`,
  `WNS=2.608 ns`, and `WHS=0.010 ns`.

## High-Level State

The KV260 now boots the generated PetaLinux image from the microSD card and the
`full` verifier path is working on hardware.

The hardware path had two distinct issues. First, the stock boot path leaves
the PS-generated `pl0_ref` clock off for this design. The Linux-side
`kv260_sigv_pl_clock_init.py` helper now fixes that persistently before the
daemon probes hardware. Second, the `full` core was driving BRAM Port B with
word addresses while Vivado `blk_mem_gen` expects byte addresses. That made the
verifier latch repeated job words and reject even known-good vectors until the
Port B addresses were shifted left by `2` in
[fpga/kv260_sigv/src/kv260_sigv_top.v](../fpga/kv260_sigv/src/kv260_sigv_top.v).

The repo-side fixes are implemented, the image boots cleanly, and the current
staged artifacts plus the live boot partition are aligned on the validated
`full` bitstream. The remaining open issues are operational rather than
core-functional: root `authorized_keys` is still not persistent across reboot,
the custom QSPI slot at multiboot offset `0x40` still does not boot cleanly,
and JTAG is still not visible from the host.

The bounded validation now covers all the expected layers:
- boot and Linux bring-up
- PL clock enable from the Linux helper
- direct control-register identity reads
- autonomous PS interrupt delivery through `/dev/uio2`
- BRAM writes and readback through the UIO windows
- full verifier smoke on known-good and known-bad vectors

Earlier in the session, U-Boot's multiboot register had been changed from the
stock Kria boot slot to the custom slot:

```text
zynqmp mmio_read 0xffca0010 -> 0x1f0
zynqmp mmio_write 0xffca0010 0xffffffff 0x40
zynqmp mmio_read 0xffca0010 -> 0x40
reset
```

After that reset, the UART was silent. A later full power cycle recovered the
board and it is now booting Linux again from the SD card through the stock QSPI
path.

## Confirmed Working

- The host sees the KV260 FT4232 USB device and serial ports.
- The active serial console is the stable by-id path
  `if01-port0` at `115200` baud. Do not rely on a fixed `ttyUSB` number after
  the host-side FTDI/JTAG rule is applied; the UART can move between
  `/dev/ttyUSB0` and `/dev/ttyUSB1` across re-enumeration.
- The stock Kria QSPI boot path can reach U-Boot 2023.01.
- The stock boot path can see the microSD card.
- The microSD card is detected by Linux as `mmcblk0`.
- The SD card's first FAT partition contains the generated boot artifacts:
  `BOOT.BIN`, `image.ub`, `system.bit`, `boot.scr`, and `uEnv.txt`.
- The generated `image.ub` boots to PetaLinux 2025.2.
- The Linux system reaches a root shell as `root@kv260sigv`.
- Ethernet comes up at 1 Gbps.
- The mounted SD boot partition on the running board matches the staged host
  artifacts byte-for-byte for `BOOT.BIN`, `image.ub`, `system.bit`, `boot.scr`,
  and `uEnv.txt`.
- The rebuilt staged `rootfs.tar.gz` contains
  `/usr/bin/kv260_sigv_pl_clock_init.py` and the updated
  `/usr/lib/systemd/system/kv260_sigv_daemon.service`.
- The refreshed image boots cleanly from SD and reaches a root shell without
  any manual `devmem` clock fixups.
- `/sys/class/fpga_manager/fpga0/state` reports `operating`.
- `/usr/bin/kv260_sigv_daemon` exists and the systemd service has started.
- `/run/kv260-sigv.sock` exists.
- On the live board, with the manually installed helper on the currently
  running image,
  `systemctl restart kv260_sigv_daemon.service` recovers cleanly from a
  deliberately disabled `PL0_REF_CTRL` state.
- On the live board, raw UIO reads of `HW_MAGIC` / `HW_BUILD` now succeed on
  the full image, and HTTP `GET /v1/status` returns `200 OK`.
- On the currently rebooted `full` image, `/run/kv260-sigv.sock` reports
  `hardware_mode:"full"`, `hardware_api_version:1`, and `ready:true`.
- On the currently rebooted `full` image,
  `python3 /usr/bin/kv260_sigv_smoke.py --expected-hw-mode full probe`
  reports `HW_MAGIC=0x53494756` and `HW_BUILD=0x00000100`.
- On the currently rebooted `full` image, bounded smoke validation succeeds
  end to end: `valid -> [true]`, `invalid -> [false]`, and
  `pair -> [true, false]`.
- On the refreshed `bringup` image, a local UNIX-socket GET to
  `/run/kv260-sigv.sock` returns `200 OK` and reports
  `hardware_mode:"bringup"` / `hardware_api_version:1` with `ready:false`
  because the daemon still expects `full/1`.
- On the refreshed `bringup` image, `/usr/bin/kv260_sigv_irq_watch.py`
  successfully observes autonomous interrupts on `/dev/uio2` and
  `kv260_sigv_top@a0000000` increments cleanly in `/proc/interrupts`.
- On the refreshed `bringup` image, a bounded
  `kv260_sigv_smoke.py --expected-hw-mode bringup --wait-mode poll run-default --mode pair`
  run succeeds end to end after patching the tool to use aligned MMIO writes.
- The device tree exposes UIO regions for the accelerator and BRAM windows.
- The UIO map visible from Linux matches the intended final address map:
  `uio0=0xA0020000`, `uio1=0xA0010000`, `uio2=0xA0000000`.
- `cat /sys/block/mmcblk0/ro` currently returns `0` and the FAT partition is
  mounted read-write.
- SSH access to `root@192.168.0.241` has been restored after the fresh boot.
- The repo-side Python unit tests passed after the control-path implementation:

```text
python3 -m unittest discover -s tools
31 tests OK
```

## Confirmed Problems

### SSH access is still not persistent across reboot

The repo copy and the packaged PetaLinux recipe copy of `kv260_sigv_smoke.py`
now avoid bulk `mmap` writes and `mmap.flush()` on MMIO-backed UIO mappings.
That change is now rebuilt into the staged rootfs, written onto the SD card,
booted, and validated on the live board.

What still does not persist across reboot is root SSH access. The image
continues to regenerate host keys and comes up without the host's
`authorized_keys`, so SSH access still has to be restored over UART after each
fresh boot.

### Boot path is inconsistent

The board is currently booting Linux through the stock Kria QSPI firmware plus
the SD `boot.scr`/`uEnv.txt` path. That path definitely loads the staged 2025.2
`system.bit` from SD with `fpga loadb` and then boots the staged `image.ub`,
but it does not leave `pl0_ref` enabled for this design. That is now proven.
The rebuilt image compensates with the Linux-side helper, so the stock boot
path is workable even though the PS clock programming is still missing before
Linux starts. The custom 2025.2 FSBL/U-Boot path may still be worth recovering
later, but it is no longer required to explain the earlier PS-to-PL AXI
failure.

### Custom QSPI slot is not booting cleanly

The custom image was previously flashed to QSPI offset `0x200000`, corresponding
to multiboot offset `0x40`. Earlier in the session, that slot reached custom
U-Boot 2025.01.

At the stop point, manually setting `CSU_MULTI_BOOT` to `0x40` and resetting
produced no UART output. This needs recovery/debug before relying on the custom
slot.

### JTAG is not currently usable from the host

`hw_server` can start and listen on TCP port `3121`, but XSCT still shows no
JTAG targets. The FT4232 USB device is visible as `0403:6011`. The host-side
udev fix is now installed and active, so the raw USB node is no longer the
main blocker.

The host inspection now points to a more precise fix than the earlier ad hoc
ACL attempt:

- all FT4232 interfaces are currently bound to `ftdi_sio`
- the live UART console is on interface `01` (`/dev/ttyUSB1`)
- `ModemManager` is active and the FTDI ports are marked
  `ID_MM_CANDIDATE=1`

Because of that, AMD's stock FTDI rule should not be applied blindly on this
host. The custom rule now installed on the host frees only interface `00` for
JTAG and leaves interface `01` alone for UART. That fixed permissions and
driver ownership as intended, but JTAG targets still do not enumerate. The next
likely step is to bypass the FTDI path entirely with the direct `J3` JTAG
header and an external cable, or to debug board-level JTAG routing/boot-state
assumptions rather than host permissions.

## SD Card Contents At Last Inspection

The SD FAT partition contained:

```text
BOOT.BIN
FLASHED.OK
boot.scr
boot.scr.pre-recovery
image.ub
system.bit
uEnv.txt
uEnv.txt.pre-recovery
```

The active `boot.scr` is the standard PetaLinux distro boot script. The active
`uEnv.txt` injects a `uenvcmd` that loads `system.bit` with `fpga loadb` before
`image.ub` is booted. `FLASHED.OK` is still present on the partition, and the
older `boot.scr.pre-recovery`/`uEnv.txt.pre-recovery` files are still present as
artifacts from the earlier recovery flow, but the currently mounted active
files have the expected staged hashes.

Before the next serious boot-path experiment, prefer cleaning the FAT partition
from the host so there is no ambiguity about which backup files are still
present, even though the active files are now known.

## Useful Commands For Next Session

Serial console:

```bash
SER=/dev/serial/by-id/usb-Xilinx_ML_Carrier_Card_XFL15KDTUSIW-if01-port0
stty -F "$SER" 115200 raw -echo -crtscts
timeout 90s cat -v "$SER"
```

Send a command to the UART:

```bash
SER=/dev/serial/by-id/usb-Xilinx_ML_Carrier_Card_XFL15KDTUSIW-if01-port0
printf 'help\r' > "$SER"
```

Fix serial permissions after USB re-enumeration:

```bash
sudo setfacl -m u:$USER:rw /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3
```

Check `hw_server`:

```bash
pgrep -af 'hw_server|loader -exec hw_server'
ss -ltnp | rg '3121|hw_server'
```

Start `hw_server` if needed:

```bash
$HOME/.cache/txnverify-fpga/kv260-petalinux/home/Xilinx/PetaLinux/2025.2/components/xsct/bin/hw_server
```

Check XSCT targets:

```bash
XSCT=$HOME/.cache/txnverify-fpga/kv260-petalinux/home/Xilinx/PetaLinux/2025.2/components/xsct/bin/xsct
"$XSCT" -eval 'connect -url tcp:localhost:3121; targets; jtag targets; exit'
```

## Recommended Resume Plan

1. Decide whether to keep iterating in `bringup` or to restage the `full`
   verifier image with the same Linux-side clock helper.
2. While the staged payload is still `bringup`, continue with the safer platform
   proof points first:
   - expected bringup mode is reported
   - autonomous IRQ delivery is stable
   - bounded smoke runs complete cleanly without Ethernet/UART wedging
3. If the next step is `full`, restage a `full` image and validate it with the
   same sequence:
   - `/v1/status`
   - raw identity probe
   - bounded smoke run
4. Only after the SD/rootfs path is stable, decide whether recovering the
   custom QSPI slot is still worth the effort.

## Open Technical Questions

- Why did the custom QSPI slot at multiboot offset `0x40` stop producing UART
  output after it had previously reached U-Boot 2025.01?
- Should the `pl0_ref` enable remain a Linux-side helper, or should it be
  moved into a recovered custom boot path later?
- Is the PL reset input in the Vivado block design correctly driven after warm
  resets, not only after power-on?
- Is `maxihpm0_fpd_aclk` correctly clocked and reset in every boot path?
- Are the UIO mappings and generated addresses exactly aligned with the final
  Vivado address map?
- Why did the earlier target Linux session report the microSD block device as
  read-only when the current boot exposes it read-write?

## Current Bottom Line

The KV260 is now past the PS/PL AXI bring-up problem. The missing piece was the
disabled `pl0_ref` clock under the stock boot path, and that is fixed on the
live board by the new clock-init helper plus daemon pre-start hook.

The remaining work is no longer packaging. The rebuilt image is staged, the SD
card is refreshed, the helper is in the packaged rootfs, and the refreshed
`bringup` image has now booted cleanly. The next step is to keep the validation
bounded in `bringup` mode or deliberately restage `full`, rather than falling
back into uncontrolled MMIO retries.
