
{ config, lib, modulesPath, options, pkgs, venusCross, ... }:

let
  wifiIp = "192.168.0.150";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ./venus-hardware.nix ];

  venus.debug.enable = true;

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
  networking.wireless = {
    enable = true;
    userControlled.enable = false;
    networks."moli-1004-backup" = { psk = "__SECRET_VENUS_WIFI_PSK__"; };
  };
  networking.useNetworkd = true;
  systemd.network.networks."20-wlan0" = {
    matchConfig.Name = "wlan0";
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
