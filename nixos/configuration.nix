
{ config, lib, modulesPath, options, pkgs, venusCross, ... }:

let
  wifiIp = "192.168.0.68";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ./venus-hardware.nix ];

  venus.debug.enable = false;  # rd.debug/loglevel=8/oops=panic 会把 115200 串口灌爆并让 panic 变致命

  boot.kernelPackages = pkgs.linuxKernel.packagesFor (venusCross.callPackage ./kernel.nix { });

  networking.hostName = "venus";
  networking.useDHCP = false;
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
    userControlled.enable = false;
    networks = { };
    extraConfig = ''
      network={
        ssid="moli-1004-backup"
        bssid=be:fc:e7:9e:e8:d5
        key_mgmt=WPA-PSK
        psk="<WIFI_PSK>"
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
  systemd.services."network-addresses-wlan0".enable = false;
  systemd.services."network-setup".enable = false;

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
  programs.dconf.enable = true;

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
  services.journald =
    lib.optionalAttrs (!(options ? services.journald.settings)) {
      extraConfig = ''
        Storage=persistent
        SystemMaxUse=256M
        SystemMaxFileSize=32M
      '';
    }
    // lib.optionalAttrs (options ? services.journald.settings) {
      settings.Journal = {
        Storage = "persistent";
        SystemMaxUse = "256M";
        SystemMaxFileSize = "32M";
      };
    };

  environment.sessionVariables = {
    XCURSOR_SIZE = "32";
  };

  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
    Timeout=0
  '';
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  environment.systemPackages = with pkgs; [
    nautilus seahorse
    vim git htop tmux rsync curl wget iw wpa_supplicant usbutils pciutils busybox e2fsprogs zstd
    imagemagick
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
