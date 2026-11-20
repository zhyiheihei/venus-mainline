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
    # 不用 networks.<ssid>：nixpkgs 对同一 SSID 会生成 network 块（本机 AP 有两个 BSSID，
    # `…:d4` 认证不过，`…:d5` 可以），而且不带 bssid，实测会黏在 `…:d4` 上反复失败。
    networks = lib.mkForce { };
    extraConfig = ''
      network={
        ssid="moli-1004-backup"
        bssid=be:fc:e7:9e:e8:d5
        key_mgmt=WPA-PSK
        psk="88888888"
        priority=1
      }
    '';
  };
  systemd.services."wpa_supplicant-wlan0" = {
    serviceConfig = {
      Restart = "always";
      RestartSec = 3;
      # nixpkgs 的 wpa_supplicant 模板 + lantian.harden 的默认档（mkOptionDefault，优先级低于
      # 模板）叠加后 ProcSubset 仍是 "pid"，于是该单元在起 mount namespace 时就失败：
      #   wpa_supplicant-wlan0.service: Failed to set up mount namespacing:
      #     /proc/sys/net: No such file or directory
      #   Main process exited, code=exited, status=226/NAMESPACE
      # wpa_supplicant 要读 /proc/sys/net/*（nl80211 能力探测），必须放开 /proc 子集。
      # 与 nixos-config 里 mptcp.service 的处置同理（那边也是 ProcSubset=all + ProtectProc=default）。
      ProcSubset = lib.mkForce "all";
      ProtectProc = lib.mkForce "default";
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
    "wpa_supplicant-wlan0" = {
      enable = "network";
      enableConfinement = false;
    };
  };
  # 以前这里有 `lantian.harden."venus-net-watch".enable` 与
  # `systemd.services.venus-net-watch.serviceConfig.BindPaths`。venus-net-watch 现在只在
  # 调试版存在（venus-hardware.nix 里被 venus.debug.enable 门控），正式版再引用它会在
  # fleet 闭包里凭空造出一个没有 ExecStart 的 venus-net-watch.service（`.service.d/` 覆盖），
  # 启动后必然 failed。正式版不记这份 30 秒一次的网络流水账。

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
