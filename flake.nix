{
  description = "Xiaomi Mi 11 (venus, SM8350) mainline Linux / NixOS port";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          ...
        }:
        {
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              dtc
              openssl
              ncurses
              flex
              bison
              bc
              perl
              cpio
              pahole
              rsync
              pkgsCross.aarch64-multiplatform.buildPackages.gcc
              python3
              jq
              curl
            ];
          };
        };

      flake = {
        nixosModules.venus = {
          imports = [
            ./nixos/venus-hardware.nix
            ./nixos/venus-fleet.nix
          ];
        };
        nixosConfigurations.venus = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./nixos/configuration.nix
          ];
        };

        nixosConfigurations.venus-debug = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./nixos/configuration.nix
            ({ pkgs, ... }: {
              venus.debug.enable = true;
              boot.kernelPackages = inputs.nixpkgs.lib.mkForce (pkgs.linuxKernel.packagesFor (
                pkgs.pkgsCross.aarch64-multiplatform.callPackage ./nixos/kernel.nix { debug = true; }
              ));
            })
          ];
        };
      };
    };
}
