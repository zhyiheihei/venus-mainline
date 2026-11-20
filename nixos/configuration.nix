
{ config, lib, modulesPath, options, pkgs, venusCross, venusKernelPackages ? null, ... }:

let
  wifiIp = "192.168.0.68";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ./venus-hardware.nix ];

  venus.debug.enable = lib.mkDefault false;

  boot.kernelPackages =
    if venusKernelPackages != null then venusKernelPackages false
    else pkgs.linuxKernel.packagesFor (venusCross.callPackage ./kernel.nix { });

  networking.hostName = "venus";
    networking.usePredictableInterfaceNames = false;
  services.resolved.enable = true;
  networking.nameservers = [ wifiGw "223.5.5.5" ];

  # WiFi 走 wpa_supplicant（与 25.05 已验证的那条线一致）。
  # 26.11 的 NetworkManager 路径在 venus 上起不来：NM 报
  #   "Couldn't initialize supplicant interface: Failed to D-Bus activate wpa_supplicant service"
  # 导致 wlan0 一直 unavailable；而 networking.wireless 直接给 wpa_supplicant + 固定 IP，实测可用。
  networking.networkmanager.enable = false;
  # 不再用 networks.<ssid> 让 nixpkgs 自动生成（它会生成两条同 SSID 的 network 块，
  # 一条带 SAE/FT-SAE、一条不带，再叠加全局 pmf=1）。实测（2026-11-18 16:17 启动）：
  #   wlan0: authenticate with be:fc:e7:9e:e8:d5     ← 这个 BSSID 能过
  #   wlan0: authenticate with be:fc:e7:9e:e8:d4     ← 之后一直黏在这个 BSSID 上失败
  # 同一 SSID 在 AP 上对应两个 BSSID（2.4G/5G 两个 radio），协商参数与其中一个
  # radio 不匹配就永远轮不回来，表现为"WiFi 时好时坏"。
  # 改成单一 network 块，只钉 BSSID。
  # 钉死能用的 BSSID（:d4 认证过不了），但**不再钉频率**：2026-11-19 实测该 AP 已从
  # ch36(5180) 换到 ch60(5300)，`scan_freq=5180` 让 wpa_supplicant 只扫 5180，永远扫不到
  # 这个 BSS → 关联失败 → 无 IPv4。实测：`iw dev wlan0 link` → Connected to
  # be:fc:e7:9e:e8:d5, freq 5300.0；`nmcli` → moli-1004-backup BE:FC:E7:9E:E8:D5 CHAN 60。
  networking.wireless = {
    enable = true;
    userControlled = false;
    networks = { };
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
  networking.useNetworkd = true;
  systemd.network.networks."20-wlan0" = {
    matchConfig.Name = "wlan0";
    # MAC 必须与静态地址在同一个 .network 文件里：networkd 每个 link 只用一个文件，
    # 早前拆成 10-wlan0(MAC) + 20-wlan0(IPv4) 时，20 从未生效 → 只有 IPv6、无 192.168.0.150。
    linkConfig.MACAddress = "02:11:22:3c:4d:5e";
    networkConfig = {
      DHCP = "no";
      DNS = [ wifiGw "223.5.5.5" ];
    };
    address = [ "${wifiIp}/24" ];
    routes = [ { Destination = "0.0.0.0/0"; Gateway = wifiGw; } ];
  };
  networking.firewall.enable = false;

  systemd.services.nix-daemon.environment = {
    http_proxy = "socks5h://192.168.0.1:1080";
    https_proxy = "socks5h://192.168.0.1:1080";
    all_proxy = "socks5h://192.168.0.1:1080";
  };
  services.openssh = {
    enable = true;
    # / 是 tmpfs，host key 必须放持久盘，否则每次冷启动都会换 key（fleet 同样用这个路径）
    hostKeys = [ { type = "ed25519"; path = "/nix/persistent/etc/ssh/ssh_host_ed25519_key"; } ];
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAXn2roZsbvURS+faytLLz2OE1gemC19RMNsPj3Ypnha 2386656187@qq.com"
    ];
    initialPassword = "venus";
  };
  services.getty.autologinUser = "venus";

  # 无桌面：这台机在 fleet 里是 server 角色（见 hosts/venus）。桌面栈此前是
  # 冷启动失败的可疑因素之一，按用户要求整个去掉，只保留串口 + SSH。
  security.polkit.enable = true;

  users.users.venus = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" "video" "render" "input" "audio" ];
    initialPassword = "venus";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAXn2roZsbvURS+faytLLz2OE1gemC19RMNsPj3Ypnha 2386656187@qq.com"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # 内存/回收调优：这一组与 nixos-config 的 minimal-components/kernel.nix 里
  # `kernel.sysctl` 给所有 fleet 主机的一致（standalone 之前一个都没设，全是内核默认）。
  # 依据（ArchWiki zram 与 Pop!_OS 的取值，也是内核文档对"内存内 swap"的建议）：
  #   - 无盘 swap 可用时 swappiness 应显著高于 60（文档给 133~200 的推导）
  #   - page-cluster 默认 3 = 一次预读 8 页；zram 没有寻道开销，预读只会白解压，设 0
  #   - watermark_boost_factor=0 避免突发 reclaim 抖动；watermark_scale_factor=125 让 kswapd 早介入
  # 内存/回收调优 + 与 fleet 一致的加固项（仅 standalone；fleet 有自己的那份）。
  # 两个实测到的坑：
  #  1) 整块 `boot.kernel.sysctl = lib.mkDefault { … }` 在这个 submodule 上会被整块吞掉
  #     （求值后一个键都不出现）→ 必须逐键赋值。
  #  2) 每个 key 是 unique-merge，nixpkgs 已定义的键（如 kernel.kptr_restrict）不能再定义一次，
  #     否则报 "defined multiple times" → 只写 nixpkgs 没定义的键。
  # 只在非 fleet 构建生效：fleet 的 minimal-components/kernel.nix 已统一给了这一组，
  # 判据是 fleet 才引入定义 `options.lantian` 的模块。
  boot.kernel.sysctl = lib.mkMerge [
    (lib.mkIf (!(options ? lantian)) {
      "vm.swappiness" = lib.mkDefault 180;
      "vm.page-cluster" = lib.mkDefault 0;
      "vm.watermark_boost_factor" = lib.mkDefault 0;
      "vm.watermark_scale_factor" = lib.mkDefault 125;
      "vm.oom_kill_allocating_task" = lib.mkDefault 1;
      "kernel.dmesg_restrict" = lib.mkDefault 1;
      "kernel.yama.ptrace_scope" = lib.mkDefault 1;
      "kernel.kexec_load_disabled" = lib.mkDefault 1;
      "kernel.nmi_watchdog" = lib.mkDefault 0;
    })
  ];

  # `services.journald.settings` 在 26.11 必然存在，原来那套
  # `lib.optionalAttrs (options ? services.journald.settings)` 双分支只剩死代码，
  # 只保留新写法。mkDefault：fleet 侧（nixos-config 的 journald 组件）统一 1G/100M，
  # 正式版跟它对齐，别用本地值覆盖；standalone 时这些默认值照旧生效。
  services.journald.settings.Journal = lib.mkDefault {
    Storage = "persistent";
    SystemMaxUse = "256M";
    SystemMaxFileSize = "32M";
  };

  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  environment.systemPackages = with pkgs; [
    vim git htop tmux rsync curl wget iw wpa_supplicant usbutils pciutils busybox e2fsprogs zstd
  ];
  services.udev.packages = [ pkgs.usbutils ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  # 绝不自动 GC：`nix.gc.automatic` 跑的是 `nix-collect-garbage -d`，它删掉旧 generation 之后
  # 会把**不可达**的 store 路径一并删掉。这台机的 profile 经常被手动指来指去
  # （25.05 ⇄ 26.11 来回切），于是一次 GC 就能把正在运行的系统删成半空：
  #   Cannot execute /run/current-system/sw/bin/bash: No such file or directory
  # （2026-11-17 03:43 那次 26.11 启动的落盘日志里 stage-2 一切正常，
  #   但一分钟后 wpa_supplicant/gadget 帮手全部 exec 失败、Wi-Fi 与 USB 同时消失）
  # 需要清理时人工 `nix-collect-garbage --delete-older-than 30d`，并先给要保留的闭包建 GC 根。
  nix.gc.automatic = false;
  nixpkgs.config.allowUnfree = true;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  system.stateVersion = "25.05";
}
