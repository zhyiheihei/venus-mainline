{ config, lib, options, pkgs, ... }:

let
  venusFirmware = pkgs.runCommandLocal "venus-firmware" { } ''
    mkdir -p $out/lib/firmware
    cp -r ${./firmware}/. $out/lib/firmware/
  '';
  venusGadget = ''
    venus_usb_gadget() {
      force=''${1:-}
      mount -t configfs none /sys/kernel/config 2>/dev/null || true
      G=/sys/kernel/config/usb_gadget/venus

      if [ "$force" != force ] && [ -s "$G/UDC" ] && [ "$(cat /sys/class/udc/$(cat "$G/UDC")/state 2>/dev/null)" = "configured" ]; then
        echo "gadget 已配置: UDC=$(cat "$G/UDC")"
        return 0
      fi

      for u in /sys/kernel/config/usb_gadget/*; do
        [ -d "$u" ] || continue
        echo "" > "$u/UDC" 2>/dev/null || true
        for c in "$u"/configs/*/; do
          [ -d "$c" ] || continue
          for l in "$c"*; do [ -L "$l" ] && rm -f "$l"; done
        done
      done

      UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
      [ -n "$UDC" ] || { echo "没有 UDC"; return 1; }

      mkdir -p "$G" "$G/functions/acm.GS0"
      echo 0x18d1 > "$G/idVendor"
      echo 0x4ee1 > "$G/idProduct"
      echo 0x0100 > "$G/bcdDevice"
      echo 0x0200 > "$G/bcdUSB"
      mkdir -p "$G/strings/0x409"
      echo venus-m1 > "$G/strings/0x409/serialnumber"
      echo Xiaomi > "$G/strings/0x409/manufacturer"
      echo venus > "$G/strings/0x409/product"
      mkdir -p "$G/configs/c.1/strings/0x409"
      echo "ACM" > "$G/configs/c.1/strings/0x409/configuration"
      echo 250 > "$G/configs/c.1/MaxPower"
      rm -f "$G/configs/c.1/acm.GS0"
      ln -s "$G/functions/acm.GS0" "$G/configs/c.1/acm.GS0"

      echo "$UDC" > "$G/UDC" 2>/dev/null || true
      sleep 2
      msg="UDC=$UDC state=$(cat /sys/class/udc/$UDC/state 2>/dev/null)"
      echo "$msg"
      echo "$(date '+%F %T') $msg force=$force" >> /persistent/venus-usb-state.log 2>/dev/null || true
    }
  '';

in
{
  options.venus.debug = {
    enable = lib.mkEnableOption "venus 调试模式（持久化崩溃日志、调试内核、verbose 开机）";
  };

  options.venus.bluetooth = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "是否启用 WCN6851 蓝牙（服务器用途默认关闭，开着会有 rfkill/帧重组报错）。";
  };


  config = {
  boot.initrd.systemd.services.venus-debug-dump = lib.mkIf config.venus.debug.enable {
    description = "venus-debug: dump initrd state to persistent storage";
    wantedBy = [ "initrd.target" ];
    after = [ "sysroot.mount" ];
    before = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /sysroot/persistent/venus-debug
      {
        systemctl --no-pager --full list-units --all 2>&1 | head -120
        echo
        systemctl --no-pager --full --failed 2>&1 | head -60
        echo
        journalctl -b --no-pager 2>&1 | tail -500
      } > /sysroot/persistent/venus-debug/initrd.log 2>&1 || true
      sync || true
    '';
  };

  systemd.services.venus-debug-pstore = lib.mkIf config.venus.debug.enable {
    description = "venus-debug: collect pstore from previous crash";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /persistent/venus-debug/pstore
      for f in /sys/fs/pstore/*; do
        [ -f "$f" ] || continue
        cp "$f" "/persistent/venus-debug/pstore/$(date +%Y%m%d-%H%M%S)-$(basename "$f")" 2>/dev/null || true
        rm -f "$f" 2>/dev/null || true
      done
      sync || true
    '';
  };

  systemd.services.venus-debug-journal = lib.mkIf config.venus.debug.enable {
    description = "venus-debug: snapshot journal to persistent storage";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      mkdir -p /persistent/venus-debug
      journalctl -b --no-pager > /persistent/venus-debug/journal.log 2>&1 || true
      systemctl --no-pager --failed > /persistent/venus-debug/failed.log 2>&1 || true
      dmesg > /persistent/venus-debug/dmesg.log 2>&1 || true
      sync || true
    '';
  };

  systemd.timers.venus-debug-journal = lib.mkIf config.venus.debug.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
    };
  };

  systemd.network.networks."10-wlan0".linkConfig.MACAddress =
    lib.mkDefault "02:11:22:3c:4d:5e";
  systemd.services."wpa_supplicant-wlan0" = lib.mkIf config.networking.wireless.enable {
    serviceConfig = {
      ProcSubset = lib.mkForce "all";
      ProtectProc = lib.mkForce "default";
    };
  };
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.kernelParams =
    [ "console=ttyGS0,115200" "consoleblank=0" ]
    ++ lib.optionals config.venus.debug.enable [
    "loglevel=8"
    "ignore_loglevel"
    "pstore.backend=ramoops"
    "oops=panic"
    "panic=30"
    "printk.always_kmsg_dump=1"
    "systemd.log_level=debug"
    "systemd.journald.forward_to_console=1"
    "rd.debug"
    "rd.udev.log_level=debug"
    "boot.shell_on_fail"
    "sysrq_always_enabled=1"
    ];
  boot.supportedFilesystems = lib.mkForce [
    "btrfs"
    "ext4"
    "vfat"
  ];

  boot.blacklistedKernelModules = [
    "snd_soc_cs35l41" "snd_soc_cs35l41_i2c" "snd_soc_cs35l41_lib"
  ];
  systemd.services.venus-rtc-restore = {
    description = "Restore system clock from hardware RTC";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "ntpd-rs.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.util-linux}/bin/hwclock -s --utc";
    };
  };
  systemd.services.venus-rtc-save = {
    description = "Save system clock to hardware RTC";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/hwclock -w --utc";
    };
  };
  systemd.timers.venus-rtc-save = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = false;
    };
  };

  hardware.bluetooth = {
    enable = config.venus.bluetooth;
    powerOnBoot = false;
  };
  environment.etc."NetworkManager/conf.d/99-venus-powersave.conf".text = ''
    [connection]
    wifi.powersave=2
  '';
  systemd.services."serial-getty@ttyGS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    after = [ "venus-acm.service" ];
    requires = [ "venus-acm.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 3;
      ExecStart = lib.mkForce "${pkgs.util-linux}/bin/agetty --autologin root --noclear -8 %I 115200";
    };
  };

  environment.etc."venus-wifi-setup" = {
    mode = "0755";
    text = ''
      set -u
      P=/sys/bus/platform/devices

      for r in io dig rfa1 rfa2 aon; do
        echo enabled > "$P/regulator-wifi_$r/state" 2>/dev/null || true
      done
      sleep 1

      i=0
      while [ $i -lt 60 ] && [ ! -d /sys/class/net/wlan0 ]; do
        sleep 1
        i=$((i + 1))
      done

      i=0; while [ $i -lt 60 ] && [ ! -d /sys/class/net/wlan0 ]; do sleep 1; i=$((i+1)); done
      [ -d /sys/class/net/wlan0 ] || { echo "ath11k 网卡没出现"; exit 0; }
      echo "ath11k 网卡: wlan0"

      ${pkgs.iw}/bin/iw dev wlan0 set power_save off 2>/dev/null || true

      ${lib.optionalString config.networking.networkmanager.enable (lib.concatStringsSep "\n" [
        "# 5) 交给 NetworkManager：固定 MAC 之后让 NM 接管 wlan0 并连上保存的连接"
        "${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true"
        "${pkgs.networkmanager}/bin/nmcli connection up venus-wifi 2>/dev/null || \\"
        "  ${pkgs.networkmanager}/bin/nmcli connection up <WIFI_SSID> 2>/dev/null || true"
      ])}${lib.optionalString (!config.networking.networkmanager.enable) ''
        ${pkgs.iproute2}/bin/ip link set wlan0 up
      ''}

      i=0; while [ $i -lt 40 ]; do
        [ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = "1" ] && break
        sleep 1; i=$((i+1))
      done
      ${config.systemd.package}/bin/systemctl restart sshd.service 2>/dev/null || true

      if [ ! -d /sys/class/net/wlan0 ]; then
        echo "自检失败：wlan0 不存在，重新绑定 PCIe"
        echo 1c00000.pcie > "$D/bind" 2>/dev/null || true
        sleep 5
      fi
      ip -4 -o addr show wlan0 2>/dev/null || echo "警告：wlan0 没有地址"

      if [ "''${VENUS_BLUETOOTH:-0}" = 1 ]; then
      /run/current-system/sw/bin/rfkill unblock bluetooth 2>/dev/null || true
      /run/current-system/sw/bin/systemctl start bluetooth.service 2>/dev/null || true
      sleep 3
      for i in 1 2 3 4 5 6; do
        /run/current-system/sw/bin/bluetoothctl power on >/dev/null 2>&1 || true
        if /run/current-system/sw/bin/bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
          echo "蓝牙已上电（第 $i 次）"
          break
        fi
        sleep 6
      done
      /run/current-system/sw/bin/hciconfig -a 2>/dev/null | head -4 || true
      fi
    '';
  };

  systemd.services.venus-wifi-check = {
    description = "venus: 检查 wlan0 是否有地址（只记录，不重训）";
    serviceConfig = { Type = "oneshot"; };
    path = with pkgs; [ iproute2 ];
    script = ''
      if ip -4 -o addr show wlan0 2>/dev/null | grep -q "inet "; then
        exit 0
      fi
      echo "wlan0 没有地址（不重训，等下一次人工介入）"
      ip -o link show wlan0 2>&1 | head -2
    '';
  };

  systemd.timers.venus-wifi-check = {
    enable = lib.mkDefault false;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
      Unit = "venus-wifi-check.service";
    };
  };

  boot.initrd.systemd.services.venus-serial = {
    description = "venus: initrd 串口 shell";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "initrd.target" ];
    before = [ "initrd.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 3;
    };
    script = ''
      ${venusGadget}
      venus_usb_gadget || true
      n=0
      while [ ! -c /dev/ttyGS0 ] && [ $n -lt 20 ]; do
        sleep 1
        n=$((n + 1))
      done
      [ -c /dev/ttyGS0 ] || exit 1
      exec sh </dev/ttyGS0 >/dev/ttyGS0 2>&1
    '';
  };

  systemd.services.venus-acm = {
    description = "venus: 重建 USB ACM 串口 (console=ttyGS0)";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${venusGadget}
      venus_usb_gadget force
    '';
  };


  networking.networkmanager.ensureProfiles.profiles = lib.mkIf config.networking.networkmanager.enable {
    venus-usb = {
      connection = {
        id = "venus-usb";
        uuid = "b8c1f0a2-3d44-4c8e-9f61-72a0d5e19c33";
        type = "ethernet";
        interface-name = "usb0";
        autoconnect = true;
        autoconnect-priority = 10;
      };
      ipv4 = {
        method = "shared";
        may-fail = true;
      };
      ipv6.method = "ignore";
    };
  };

  systemd.network.networks."30-usb0" = lib.mkIf (!config.networking.networkmanager.enable) {
    matchConfig.Name = "usb0";
    address = [ "192.168.42.1/24" ];
    networkConfig.ConfigureWithoutCarrier = true;
  };

  systemd.services.venus-net-watch = {
    description = "venus: 网络/链路状态记录";
    wantedBy = [ "multi-user.target" ];
    after = [ "venus-wifi-power.service" ];
    serviceConfig = { Type = "simple"; Restart = "always"; RestartSec = 30; };
    script = ''
      set +e
      while [ ! -d /sys/class/net/wlan0 ]; do sleep 5; done
      while true; do
        {
          echo "=== $(date '+%F %T')"
          ${pkgs.iw}/bin/iw dev wlan0 link 2>&1 | head -8
          ${pkgs.iproute2}/bin/ip -4 -o addr show wlan0 2>&1
          ${pkgs.networkmanager}/bin/nmcli -t -f GENERAL.STATE,IP4.ADDRESS device show wlan0 2>&1 | head -3
          echo "carrier=$(cat /sys/class/net/wlan0/carrier 2>/dev/null)"
        } >> /var/log/venus-net.log 2>&1
        sz=$(${pkgs.coreutils}/bin/stat -c %s /var/log/venus-net.log 2>/dev/null || echo 0)
        if [ "$sz" -gt 262144 ]; then
          ${pkgs.coreutils}/bin/tail -c 100000 /var/log/venus-net.log > /var/log/venus-net.log.tmp
          ${pkgs.coreutils}/bin/mv /var/log/venus-net.log.tmp /var/log/venus-net.log
        fi
        sleep 30
      done
    '';
  };

  systemd.services.venus-wifi-power = {
    description = "venus: WiFi 上电、连 WiFi（后台执行，不阻塞启动）";
    enable = lib.mkDefault false;
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "sysinit.target" ];
    after = [ "venus-boot-activate.service" ];
    before = [ "sysinit.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 20; };
    environment.VENUS_BLUETOOTH = lib.boolToString config.venus.bluetooth;
    script = ''
      ${pkgs.util-linux}/bin/setsid /etc/venus-wifi-setup >/var/log/venus-wifi.log 2>&1 &
      exit 0
    '';
  };

  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.targets.suspend-then-hibernate.enable = false;

  services.logind =
    lib.optionalAttrs (!(options ? services.logind.settings)) {
      extraConfig = ''
        HandlePowerKey=ignore
        HandlePowerKeyLongPress=ignore
        HandleLidSwitch=ignore
        HandleSuspendKey=ignore
        HandleHibernateKey=ignore
        IdleAction=ignore
      '';
    }
    // lib.optionalAttrs (options ? services.logind.settings) {
      settings.Login = {
        HandlePowerKey = "ignore";
        HandlePowerKeyLongPress = "ignore";
        HandleLidSwitch = "ignore";
        HandleSuspendKey = "ignore";
        HandleHibernateKey = "ignore";
        IdleAction = "ignore";
      };
    };
  services.power-profiles-daemon.enable = false;
  environment.etc."xdg/powermanagementprofilesrc".text = ''
    [AC][DimDisplay]
    idleTime=120000

    [AC][DPMSControl]
    idleTime=300000

    [Battery][DimDisplay]
    idleTime=60000

    [Battery][DPMSControl]
    idleTime=180000

    [LowBattery][BrightnessControl]
    value=40
  '';
  environment.etc."venus-bl-toggle.sh".text = ''
    BL=/sys/class/backlight/ae94000.dsi.0
    S=/run/venus-bl-saved
    case "$1" in
      off) cat $BL/brightness > $S 2>/dev/null; echo 0 > $BL/brightness ;;
      on)  [ -s $S ] && cat $S > $BL/brightness || echo 128 > $BL/brightness ;;
      *)   cur=$(cat $BL/brightness); if [ "$cur" = "0" ]; then
             [ -s $S ] && cat $S > $BL/brightness || echo 128 > $BL/brightness
           else
             echo $cur > $S; echo 0 > $BL/brightness
           fi ;;
    esac
  '';
  environment.etc."venus-bl-toggle.sh".mode = "0755";

  systemd.services.venus-brightness = {
    description = "venus: 开机设置面板亮度";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-backlight@backlight:ae94000.dsi.0.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      B=/sys/class/backlight/ae94000.dsi.0/brightness
      [ -e "$B" ] || exit 0
      echo 128 > "$B" 2>/dev/null || true
    '';
  };
  boot.initrd.availableKernelModules = lib.mkForce [ ];
  fileSystems."/run/nullfs".enable = lib.mkForce false;

  boot.initrd.kernelModules = [
    "qcom-refgen-regulator" "cec" "drm_display_helper" "drm_dp_aux_bus"
    "drm_exec" "drm_gpuvm" "gpu-sched" "mdt_loader" "ubwc_config"
    "msm" "panel-xiaomi-venus-k2"
    "dm-mod"
  ];

  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa ];
  };
  hardware.firmware = [ venusFirmware ];

  };
}
