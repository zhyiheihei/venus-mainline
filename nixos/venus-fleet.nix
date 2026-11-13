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
    sopsFile = inputs.secrets + "/per-host/wifi/venus.yaml";
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

  systemd.services.venus-boot-activate = {
    description = "venus: boot-time NixOS activation";
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "systemd-sysusers.service"
      "systemd-tmpfiles-setup.service"
      "getty.target"
      "sshd.service"
      "venus-wifi-power.service"
    ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/nix/var/nix/profiles/system/activate";
    };
  };

  lantian.backup.enable = lib.mkForce false;

  boot.extraModulePackages = lib.mkForce [ ];
  boot.kernelModules = lib.mkForce [ ];
  boot.initrd.kernelModules = lib.mkForce [
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
