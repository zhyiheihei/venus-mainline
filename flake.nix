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
          # 内核交叉编译与刷机调试工具链
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              # 内核构建(host 侧工具)
              dtc
              ubootTools # mkimage
              openssl
              ncurses # menuconfig
              flex
              bison
              bc
              perl
              cpio
              pahole # BTF
              rsync
              # aarch64 交叉工具链
              pkgsCross.aarch64-multiplatform.buildPackages.gcc
              # 刷机与调试
              android-tools # fastboot / adb
              # 固件与参考资料处理
              jq
              curl
              # pmOS 对照(查 pmaports 补丁与 DTS 写法)
              pmbootstrap
            ];
          };
        };

      flake = {
        nixosConfigurations.venus = inputs.nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            ./hosts/venus
          ];
        };
      };
    };
}
