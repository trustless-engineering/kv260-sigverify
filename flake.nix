{
  description = "Nix-native development flow for txnverify-fpga";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python312.withPackages (ps: [ ps.pytest ]);
          openSourceTools = with pkgs; [
            bashInteractive
            coreutils
            findutils
            gawk
            git
            gnugrep
            gnumake
            gnused
            iverilog
            python
            ripgrep
            verilator
            yosys
          ];
          boardTools = with pkgs; [
            dtc
            gtkwave
            openfpgaloader
            picocom
            socat
            tio
            ubootTools
          ];
          rustTools = with pkgs; [
            cargo
            clippy
            rustc
            rustfmt
          ];
          linuxTools = with pkgs; nixpkgs.lib.optionals stdenv.hostPlatform.isLinux [ docker ];
        in
        {
          default = pkgs.mkShell {
            packages = openSourceTools ++ boardTools ++ rustTools ++ linuxTools;
            shellHook = ''
              export TXNVERIFY_REPO_ROOT="$PWD"
              echo "txnverify-fpga dev shell"
              echo "  nix run .#test              - run Python/RTL tests"
              echo "  nix run .#petalinux-prepare - generate local PetaLinux metadata"
              echo "  nix run .#build-image       - run the KV260 image build wrapper"
            '';
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          python = pkgs.python312.withPackages (ps: [ ps.pytest ]);
          commonRuntime = with pkgs; [
            coreutils
            git
            gnugrep
          ];
          repoPrelude = ''
            repo_root="''${TXNVERIFY_REPO_ROOT:-}"
            if [[ -z "$repo_root" ]]; then
              if git rev-parse --show-toplevel >/dev/null 2>&1; then
                repo_root="$(git rev-parse --show-toplevel)"
              else
                repo_root="$PWD"
              fi
            fi
            cd "$repo_root"
          '';
          mkApp =
            name: runtimeInputs: text:
            {
              type = "app";
              program = "${
                pkgs.writeShellApplication {
                  inherit name runtimeInputs;
                  text = repoPrelude + text;
                }
              }/bin/${name}";
              meta.description = name;
            };
          pytestRuntime = commonRuntime ++ [
            python
            pkgs.gnumake
            pkgs.iverilog
            pkgs.verilator
          ];
        in
        rec {
          default = test;
          test = mkApp "txnverify-test" pytestRuntime ''
            if [[ $# -eq 0 ]]; then
              set -- tools/tests
            fi
            exec python -m pytest -q "$@"
          '';
          rtl-tests = mkApp "txnverify-rtl-tests" pytestRuntime ''
            exec python -m pytest -q \
              tools/tests/test_fe25519_mul_core_rtl.py \
              tools/tests/test_kv260_sigv_rtl.py \
              tools/tests/test_fixed_base_bench.py \
              tools/tests/test_shared_rtl_edge_cases.py \
              "$@"
          '';
          cargo-test = mkApp "txnverify-cargo-test" (
            commonRuntime
            ++ [
              pkgs.cargo
              pkgs.rustc
            ]
          ) ''
            if [[ $# -eq 0 ]]; then
              set -- --workspace
            fi
            exec cargo test "$@"
          '';
          petalinux-prepare = mkApp "txnverify-petalinux-prepare" (
            commonRuntime ++ [ pkgs.python312 ]
          ) ''
            exec python tools/prepare_petalinux_project.py "$@"
          '';
          build-image = mkApp "txnverify-build-image" (
            commonRuntime
            ++ [
              pkgs.gnumake
              pkgs.python312
            ]
          ) ''
            exec python tools/kv260_build_image.py "$@"
          '';
          petalinux-docker = mkApp "txnverify-petalinux-docker" (
            commonRuntime ++ nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.docker ]
          ) ''
            exec ./tools/kv260_petalinux_docker.sh "$@"
          '';
          petalinux-doctor = mkApp "txnverify-petalinux-doctor" (
            commonRuntime ++ nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.docker ]
          ) ''
            exec ./tools/kv260_petalinux_docker.sh doctor "$@"
          '';
          petalinux-shell = mkApp "txnverify-petalinux-shell" (
            commonRuntime ++ nixpkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.docker ]
          ) ''
            exec ./tools/kv260_petalinux_docker.sh shell "$@"
          '';
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          no-local-home-paths = pkgs.runCommand "txnverify-no-local-home-paths" { nativeBuildInputs = [ pkgs.ripgrep ]; } ''
            cp -R ${self} source
            chmod -R +w source
            if rg --hidden -n '/home/[^/[:space:]]+/txnverify-fpga' source -g '!.git/**'; then
              echo "found committed local username/home path" >&2
              exit 1
            fi
            touch "$out"
          '';
        }
      );
    };
}
