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

      flake =
        let
          nixpkgs = inputs.nixpkgs;
          venusCrossFor = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform;
          venusHostPkgs = nixpkgs.legacyPackages.aarch64-linux;
          venusKernelPackages = debug: venusHostPkgs.linuxKernel.packagesFor (
            venusCrossFor.callPackage ./nixos/kernel.nix { inherit debug; }
          );
        in
        {
        nixosModules.venus = {
          imports = [
            ./nixos/venus-hardware.nix
            ./nixos/venus-fleet.nix
            ./nixos/boot-image.nix
            ./nixos/boot-sync.nix
          ];
          boot.kernelPackages = inputs.nixpkgs.lib.mkForce (venusKernelPackages false);
        };
        nixosConfigurations.venus = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            venusCross = venusCrossFor;
            inherit inputs;
            inherit venusKernelPackages;
          };
          modules = [
            ./nixos/configuration.nix
          ];
        };

        nixosConfigurations.venus-debug = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          specialArgs = {
            venusCross = venusCrossFor;
            inherit inputs;
            inherit venusKernelPackages;
          };
          modules = [
            ./nixos/configuration.nix
            ({ pkgs, ... }:
              {
                venus.debug.enable = true;
                boot.kernelPackages = inputs.nixpkgs.lib.mkForce (venusKernelPackages true);
              })
          ];
        };
      };
    };
}
