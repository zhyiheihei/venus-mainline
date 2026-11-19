{
  config,
  inputs,
  lib,
  LT,
  pkgs,
  self,
  ...
}:
let
  crossPkgs = self.allSystems.x86_64-linux._module.args.pkgs.pkgsCross.aarch64-multiplatform;
in
{
  lantian.kernel = lib.mkForce (crossPkgs.callPackage ./kernel.nix { debug = config.venus.debug.enable; });

  # fleet 用 impermanence："/" 是 tmpfs，只有 /nix 落盘。board 侧不改这个约定
  # （见 hosts/venus/hardware-configuration.nix：用 x-mount.subdir=nix 把同一块
  # ext4 里的 nix/ 挂到 /nix，从而与 fleet 标准兼容）。
  # 板级模块（deadman/bootdump/probe/usb-state）都写 /persistent，这里给一条
  # 符号链指到持久化的 /nix/persistent。
  # fleet（server 角色）不需要 USB gadget：keepalive 是 Type=simple 的常驻循环，
  # 在 nixos-config 的 lantian.harden 策略里必须给 hardening+confinement，
  # 而这块板子只需要 WiFi + SSH，故直接关掉 USB gadget 相关单元。
  systemd.services.venus-usb-keepalive.enable = lib.mkForce false;
  # 串口保留：fleet 里它是唯一在 WiFi 起不来时还能用的诊断通道（getty 是模板实例，
  # nixos-config 的 hardening 策略对 @ 模板豁免）。

  networking.usePredictableInterfaceNames = false;
  networking.wireless = {
    enable = true;
    interfaces = [ "wlan0" ];
    secretsFile = config.sops.secrets."venus-wifi-secrets".path;
    networks."moli-1004-backup" = {
      pskRaw = "ext:psk_venus";
      authProtocols = [ "WPA-PSK" ];
    };
  };
  sops.secrets."venus-wifi-secrets" = {
    # 用 LT.secret 而不是 inputs.secrets + "..."：后者会把整个 secrets 仓库的
    # store 路径（string context）带进系统闭包，触发 nixos-config 的
    # system.forbiddenDependenciesRegexes 断言（secrets-closure.nix）。
    sopsFile = LT.secret "per-host/wifi/venus.yaml";
    key = "wpa-secrets";
    owner = "wpa_supplicant";
    mode = "0400";
  };
  systemd.services."wpa_supplicant-wlan0" = {
    requires = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 3;
    };
  };

  # 删掉 venus-boot-activate：它是 25.05 时代为了让 fleet 的 /etc 生效而手写的
  # "在 sysinit 前跑 activate"。现代 NixOS 的 stage-2 自己会跑 activate，
  # 而这个单元 before=sysinit.target + DefaultDependencies=false，一旦 activate
  # 因为 /nix 尚未就绪或 sops 未解密而阻塞，就会把整个启动卡住
  # —— 2026-11-19 08:14 那次 fleet 冷启动黑屏（背光亮、无串口终端、无网络）高度符合这一形态。

  lantian.backup.enable = lib.mkForce false;

  boot.extraModulePackages = lib.mkForce [ ];
  boot.kernelModules = lib.mkForce [ ];
  # mkAfter 而不是 mkForce：mkForce 会把 nixos-config 侧（minimal-components 与
  # impermanence）配置的 initrd 模块整段替换掉，导致持久盘所需模块可能缺失。
  boot.initrd.kernelModules = lib.mkAfter [
    "qcom-refgen-regulator"
    "cec"
    "drm_display_helper"
    "drm_dp_aux_bus"
    "drm_exec"
    "drm_gpuvm"
    "gpu-sched"
    "mdt_loader"
    "ubwc_config"
    "msm"
    "panel-xiaomi-venus-k2"
    "dm-mod"
  ];

  lantian.harden = {
    "venus-net-watch".enable = "network";
    "wpa_supplicant-wlan0" = {
      enable = "network";
      enableConfinement = false;
    };
  };
  systemd.services.venus-net-watch.serviceConfig.BindPaths = [
    "/sys"
    "/var/log"
  ];

  systemd.network.networks."10-wlan0" = {
    matchConfig.Name = "wlan0";
    address = [ "${LT.this.interconnect.IPv4}/24" ];
    dns = [ "192.168.0.1" ];
    domains = [ "zhyi.xin" ];
    networkConfig.IPv6AcceptRA = "yes";
    routes = [
      {
        Destination = "0.0.0.0/0";
        Gateway = "192.168.0.1";
      }
    ];
  };
}
