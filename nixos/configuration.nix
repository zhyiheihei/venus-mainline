
{ config, lib, modulesPath, options, pkgs, venusCross, ... }:

let
  wifiIp = "<LAN_PHONE_IP>";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ./venus-hardware.nix ];

  venus.debug.enable = true;

  boot.kernelPackages = pkgs.linuxKernel.packagesFor (venusCross.callPackage ./kernel.nix { });

  networking.hostName = "venus";
  networking.useDHCP = false;
  networking.useNetworkd = false;
  networking.usePredictableInterfaceNames = false;
  services.resolved.enable = true;
  networking.nameservers = [ wifiGw "223.5.5.5" ];

  networking.networkmanager = {
    enable = true;
    settings.main.no-auto-default = "*";
    ensureProfiles.profiles.venus-wifi = {
      connection = {
        id = "<WIFI_SSID>";
        uuid = "7c2f1a84-5b3e-4a91-9d24-1f6c0e8ab3d5";
        type = "wifi";
        interface-name = "wlan0";
        autoconnect = true;
        autoconnect-retries = 0;
      };
      wifi = {
        ssid = "<WIFI_SSID>";
        mode = "infrastructure";
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
  networking.networkmanager.unmanaged = [ "interface-name:lo" ];

  networking.firewall.enable = false;

  systemd.services.nix-daemon.environment = {
    http_proxy = "socks5h://<LAN_PROXY_IP>:1080";
    https_proxy = "socks5h://<LAN_PROXY_IP>:1080";
    all_proxy = "socks5h://<LAN_PROXY_IP>:1080";
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

  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";
  security.polkit.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.displayManager.autoLogin = {
    enable = true;
    user = "venus";
  };

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
