# venus (Xiaomi Mi 11) 上的 NixOS
#
# 启动链: ABL → boot_b 上的自建内核(7.2.6 + venus.dtb) + NixOS 官方 initrd
#   kernel cmdline 里用 init=/nix/var/nix/profiles/system/init 指定 stage-2
#   （stage-1 默认找 <root>/init，而 --no-bootloader 安装不会创建这个链接）
# 因此不安装 bootloader。

{ config, lib, modulesPath, options, pkgs, ... }:

let
  wifiIp = "<LAN_PHONE_IP>";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ./venus-hardware.nix ];

  # ---------- 内核 ----------
  # P1（重建内核进不到用户态，见 docs/hardware-status.md）没解开前，设备用设备上正在跑的
  # 那份预编译产物；解开后换成：
  #   boot.kernelPackages = pkgs.linuxKernel.packagesFor (pkgs.callPackage ./kernel.nix { });
  boot.kernelPackages = pkgs.linuxKernel.packagesFor (pkgs.callPackage ./kernel-prebuilt.nix { });

  # ---------- 网络 ----------
  networking.hostName = "venus";
  # WiFi 交给 NetworkManager：这样 Plasma 的网络面板（plasma-nm）才能列出/切换 WiFi。
  # 硬件层（五路电源、PCIe 重训、固定 MAC）仍由 venus-wifi-setup 负责，
  # 之后把 wlan0 交给 NM。systemd-networkd 不再管 wlan0。
  networking.useDHCP = false;
  networking.useNetworkd = false;
  networking.usePredictableInterfaceNames = false;
  services.resolved.enable = true;
  networking.nameservers = [ wifiGw "223.5.5.5" ];

  networking.networkmanager = {
    enable = true;
    # 设备是运行后期才出现的，别让 NM 因为"没网卡"就放弃
    settings.main.no-auto-default = "*";
    # 声明式保存一个连接：WPA + 静态地址，出现在 Plasma 的网络列表里
    ensureProfiles.profiles.venus-wifi = {
      connection = {
        id = "<WIFI_SSID>";
        # 固定 uuid：声明式 profile 写在 /run 里（tmpfs，每次启动重建），
        # 不写 uuid 的话 NM 每次都会自生成一个新的 → 同一个 SSID 在 UI 里
        # 出现多条“相同的连接”，互相抢 wlan0（连上→拿 IP→掉→重连）。
        uuid = "7c2f1a84-5b3e-4a91-9d24-1f6c0e8ab3d5";
        type = "wifi";
        interface-name = "wlan0";
        autoconnect = true;
        autoconnect-retries = 0;
      };
      wifi = {
        ssid = "<WIFI_SSID>";
        mode = "infrastructure";
        # BDF 里没有有效 MAC（每次 probe 都变），这里给固定值。
        # 用 NM 的 cloned-mac-address 是官方做法，不再用 ip link set address。
        cloned-mac-address = wifiMac;
      };
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "<WIFI_PASSWORD>";
      };
      ipv4 = {
        method = "manual";
        address1 = "${wifiIp}/24,${wifiGw}";
        dns = "223.5.5.5;${wifiGw};";
        may-fail = false;
      };
      ipv6.method = "ignore";
    };
  };
  # NM 自己不碰其它网卡
  networking.networkmanager.unmanaged = [ "interface-name:lo" ];

  # TODO: 内核的 nftables/LOG 扩展还不完整（ip6tables 里 LOG 规则报 "No such file or directory"），
  # 暂时关掉 NixOS 防火墙；等把 NETFILTER 相关符号补齐再开。
  networking.firewall.enable = false;

  # ---------- 下载代理（局域网 SOCKS5，直连 cache.nixos.org 极慢）----------
  systemd.services.nix-daemon.environment = {
    http_proxy = "socks5h://<LAN_PROXY_IP>:1080";
    https_proxy = "socks5h://<LAN_PROXY_IP>:1080";
    all_proxy = "socks5h://<LAN_PROXY_IP>:1080";
  };
  # ---------- SSH ----------
  services.openssh = {
    enable = true;
    hostKeys = [ { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; } ];
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
  # greetd 负责拉桌面；tty1 不开 sway，保留自动登录方便串口/本地登录
  services.getty.autologinUser = "venus";

  # ---------- 桌面环境（KDE Plasma 6，与本机 NixOS 主机同款）----------
  # 本机主机跑的是 Plasma 6 + greetd(startplasma-wayland)，这里对齐同一套。
  # 选 Plasma 而不是 GNOME 的理由：本机同款，且 Wayland 会话不需要 Xorg。
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";
  security.polkit.enable = true;

  # 用 SDDM（本机主机同款显示管理器）+ 免登录，直接进 Plasma Wayland 会话
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.displayManager.autoLogin = {
    enable = true;
    user = "venus";
  };

  # 桌面用户（Plasma 不接受 root）
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
  # ---------- 日志：持久化 + 限额（标准 systemd 行为）----------
  # 25.05 只有 extraConfig；unstable 只剩 settings.Journal（同样按 settings 是否存在选分支）
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

  # ---------- HiDPI ----------
  # 缩放只由 Plasma 自己管（kscreen-doctor 已经写入用户的 kwinoutputconfig.json：
  # scale=2、transform=Rotated90）。不要在环境变量里再叠一层 GDK_SCALE/QT_SCALE_FACTOR，
  # 否则 Wayland 应用会被二次放大（实测 200% + 200% = 400%）。
  environment.sessionVariables = {
    XCURSOR_SIZE = "32";
  };

  # ---------- 关闭 KDE 屏幕锁定 ----------
  # 没有键盘/触屏解锁手段，一旦锁屏就只能靠重启；且 AMOLED 上黑屏会和"死机"混淆。
  environment.etc."xdg/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=false
    Timeout=0
  '';
  # ---------- 杂项 ----------
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  environment.systemPackages = with pkgs; [
    vim git htop tmux rsync curl wget iw wpa_supplicant usbutils pciutils busybox e2fsprogs zstd
    # 桌面/取色/截图
    imagemagick
  ];
  services.udev.packages = [ pkgs.usbutils ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nixpkgs.config.allowUnfree = true;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  system.stateVersion = "25.05";
}
