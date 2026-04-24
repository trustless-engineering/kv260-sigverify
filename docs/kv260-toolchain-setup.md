# KV260 Toolchain Setup

## Current Host Status

This workstation is:

- `Ubuntu 24.04.4 LTS`
- `x86_64`

That means:

- `Vivado/Vitis 2025.2` is supported on this host OS
- `PetaLinux 2025.2` is **not** officially listed for Ubuntu `24.04.x`
- AMD documents `Ubuntu 22.04.3`, `22.04.4`, and `22.04.5` as the supported Ubuntu hosts for `PetaLinux 2025.2`

AMD also documents two practical caveats for PetaLinux:

- `/bin/sh` must be `bash`
- Ubuntu hosts need `libtinfo.so.5`

On this machine today:

- `/bin/sh` points to `dash`
- the system exposes `libtinfo.so.6`, not `libtinfo.so.5`
- `docker` is available, which makes an Ubuntu `22.04.x` container or VM the clean path for the full PetaLinux flow

Sources:

- [UG973 2025.2 Supported Operating Systems, released November 20, 2025](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Supported-Operating-Systems)
- [UG973 2025.2 Running the Installer, released November 20, 2025](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Running-the-Installer)
- [UG1144 2025.2 Installation Requirements, released November 20, 2025](https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Installation-Requirements)

## What Is Installed Locally

The open-source side of the FPGA and bring-up toolchain is installed in the user Nix profile:

- `verilator`
- `yosys`
- `iverilog`
- `gtkwave`
- `openFPGALoader`
- `nextpnr-himbaechel-gowin` via a small compatibility wrapper
- `python3-apycula`
- `device-tree-compiler`
- `picocom`
- `socat`
- `tio`
- `ubootTools`

These tools are enough to:

- run the repo RTL regression suite
- run the shared Verilator benches and simulation flow
- use serial and U-Boot image utilities during board bring-up

They do **not** replace the AMD vendor tools needed for:

- `vivado`
- `xsct`
- `bootgen`
- `petalinux-*`

## Recommended Full KV260 Host

For the fully supported KV260 flow, use:

- `Ubuntu 22.04.5 x86_64`
- `Vivado/Vitis 2025.2`
- `PetaLinux 2025.2`

That keeps the hardware export and PetaLinux versions aligned and stays inside AMD's documented host support.

## Repo Bootstrap Script

The repo includes a host bootstrap helper:

- [bootstrap_kv260_toolchain_host.sh](../tools/bootstrap_kv260_toolchain_host.sh)
- [kv260_petalinux_docker.sh](../tools/kv260_petalinux_docker.sh)

It does the following:

- validates host OS and architecture
- warns when the host is not the recommended Ubuntu `22.04.x`
- runs the AMD unified installer in batch mode for `Vivado/Vitis`
- runs the `PetaLinux` installer
- writes an environment helper at `<install-root>/settings-kv260.sh`

The default install root is user-writable:

- `$HOME/Xilinx`

That matches AMD's non-root guidance for PetaLinux and avoids assuming write access to `/opt`.

The repo also includes a Docker launcher for this workstation:

- [kv260_petalinux_docker.sh](../tools/kv260_petalinux_docker.sh)

It builds a reusable `Ubuntu 22.04` container, mounts the repo into it, and persists the container home under:

- `$HOME/.cache/txnverify-fpga/kv260-petalinux/`

## Usage When You Have the AMD Installers

1. Download the AMD installer payloads manually from AMD:
   - `FPGAs_AdaptiveSoCs_Unified_*` for `Vivado/Vitis 2025.2`
   - `petalinux-v2025.2-final-installer.run`
2. Run the bootstrap script:

```bash
./tools/bootstrap_kv260_toolchain_host.sh \
  --vivado-installer /path/to/FPGAs_AdaptiveSoCs_Unified_2025.2_*.bin \
  --petalinux-installer /path/to/petalinux-v2025.2-final-installer.run \
  --install-root "$HOME/Xilinx"
```

3. Source the generated environment:

```bash
source "$HOME/Xilinx/settings-kv260.sh"
```

4. Confirm the vendor tools:

```bash
vivado -version
xsct -version
petalinux-create --help
```

## Recommended Path On This Machine

For this specific host:

- use native `Vivado/Vitis 2025.2` once you have the AMD installer
- use an Ubuntu `22.04.x` VM or Docker/container workflow for `PetaLinux 2025.2`

That avoids forcing unsupported host changes such as globally changing `/bin/sh` on the workstation just to satisfy PetaLinux.

## Docker Workflow On This Machine

Build the Ubuntu `22.04` image:

```bash
./tools/kv260_petalinux_docker.sh build
```

Sanity-check the container:

```bash
./tools/kv260_petalinux_docker.sh doctor
```

Open a shell in the container:

```bash
./tools/kv260_petalinux_docker.sh shell
```

Install `PetaLinux 2025.2` from a host-side installer payload:

```bash
./tools/kv260_petalinux_docker.sh install-petalinux \
  /absolute/path/to/petalinux-v2025.2-final-installer.run
```

The install lands in the container-persistent path:

```bash
$HOME/.cache/txnverify-fpga/kv260-petalinux/home/Xilinx/PetaLinux/2025.2
```

After installation, you can re-enter the workspace and source:

```bash
source "$HOME/Xilinx/PetaLinux/2025.2/settings.sh"
```
