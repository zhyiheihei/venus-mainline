{ config, lib, options, pkgs, ... }:

let
  venusFirmware = pkgs.runCommandLocal "venus-firmware" { } ''
    mkdir -p $out/lib/firmware
    cp -r ${./firmware}/. $out/lib/firmware/
  '';
  venusGadget = ''
    venus_usb_log() {
      echo "$(date '+%F %T') [$(cat /proc/1/comm 2>/dev/null)] $*" >> ''${VLOG:-/persistent/venus-usb-state.log} 2>/dev/null || true
    }
    venus_usb_create() {
      mode=''${1:-acm}
      G=/sys/kernel/config/usb_gadget/venus
      mkdir -p "$G" "$G/functions/acm.GS0" || true
      [ "$mode" = full ] && mkdir -p "$G/functions/rndis.usb0" || true
      echo 0x18d1 > "$G/idVendor" || true
      echo 0x4ee1 > "$G/idProduct" || true
      echo 0x0100 > "$G/bcdDevice" || true
      echo 0x0200 > "$G/bcdUSB" || true
      mkdir -p "$G/strings/0x409" || true
      echo venus-m1 > "$G/strings/0x409/serialnumber" || true
      echo Xiaomi > "$G/strings/0x409/manufacturer" || true
      echo venus > "$G/strings/0x409/product" || true
      mkdir -p "$G/configs/c.1/strings/0x409" || true
      echo "ACM" > "$G/configs/c.1/strings/0x409/configuration" || true
      echo 250 > "$G/configs/c.1/MaxPower" || true
      rm -f "$G/configs/c.1/acm.GS0" "$G/configs/c.1/rndis.usb0" || true
      ln -s "$G/functions/acm.GS0" "$G/configs/c.1/acm.GS0" || true
      if [ "$mode" = full ]; then
        ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0" || true
        echo "ACM+RNDIS" > "$G/configs/c.1/strings/0x409/configuration" || true
      fi
    }
    venus_usb_bind() {
      UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
      [ -n "$UDC" ] || { venus_usb_log "no udc"; return 1; }
      echo "$UDC" > /sys/kernel/config/usb_gadget/venus/UDC 2>/dev/null || true
      sleep 1
      venus_usb_log "bind UDC=$UDC state=$(cat /sys/class/udc/$UDC/state 2>/dev/null)"
    }
    venus_usb_unbind() {
      UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
      [ -n "$UDC" ] || return 0
      echo "" > /sys/kernel/config/usb_gadget/venus/UDC 2>/dev/null || true
      sleep 1
      venus_usb_log "unbind UDC=$UDC state=$(cat /sys/class/udc/$UDC/state 2>/dev/null)"
    }
    venus_usb_gadget() {
      force=''${1:-}
      mount -t configfs none /sys/kernel/config 2>/dev/null || true
      G=/sys/kernel/config/usb_gadget/venus
      venus_usb_log "enter force=$force cfgfs=$(mountpoint -q /sys/kernel/config && echo mounted || echo no) gadgets=[$(ls /sys/kernel/config/usb_gadget 2>/dev/null | tr '\n' ' ')] udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -d /sys/class/net/usb0 ] && echo yes || echo no)"

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

      venus_usb_create
      venus_usb_bind
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

  # 固定 wlan0 的 MAC。必须带 [Match]，否则 26.11 的 systemd-networkd 直接判定该文件无效：
  #   "10-wlan0.network: No valid settings found in the [Match] section, ignoring file"
  # （25.05 的 257.0 会容忍，26.11 的 257.10 不容忍）
  # 注意：systemd-networkd 对每个 link 只会选**一个** .network 文件（按文件名排序取第一个
  # 匹配项），不会叠加。所以 MAC 设置不能单独放一个 10-wlan0.network ——
  # 它会抢在 20-wlan0.network（静态 IPv4）之前匹配，导致 20 永远不生效（无 IPv4）。
  # 2026-11-18 实测日志：
  #   wlan0: Configuring with /etc/systemd/network/10-wlan0.network.
  #   （再没有任何 20-wlan0 的行，ip -br addr 只有 IPv6）
  # 因此这里不建独立文件，改为把 MAC 合进 20-wlan0（见 configuration.nix）。
  # 内核没有 CONFIG_RFKILL（device.config 里 "# CONFIG_RFKILL is not set"），
  # /dev/rfkill 不存在；而 nixpkgs 的 wpa_supplicant.service 把 /dev/rfkill 写死在
  # BindPaths 里，缺这个节点时启动直接 226/NAMESPACE：
  #   "Failed to set up mount namespacing: /dev/rfkill: No such file or directory"
  #   "Main process exited, code=exited, status=226/NAMESPACE"
  # 这里补一个字符设备节点只为满足 bind mount（没有 rfkill 驱动，打开会 ENODEV，
  # wpa_supplicant 把它当“无 rfkill”处理，不影响连接）。
  systemd.tmpfiles.rules = [ "c /dev/rfkill 0600 root root 10 242 - -" ];

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
    "pmic_glink_altmode"
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
    # 不能 requires venus-acm：26.11 上 venus-acm 的 After=systemd-udev-settle.service
    # 所指单元已不存在，一旦它失败，getty 就永远不启动 —— 串口彻底失声（2026-11-17 实测）。
    after = [ "venus-acm.service" ];
    # ttyGS0 由 initrd 的 venus-serial 建好；若真没有，agetty 会失败并 3 秒后重试。
    restartIfChanged = false;
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
      D=/sys/bus/platform/drivers/qcom-pcie

      # 取证：先把自己的身份和重训通道的有无写清楚，否则无法区分"脚本没跑/跑了但没权限"
      echo "--- $(date '+%F %T') booted=$(readlink -f /run/booted-system)"
      echo "--- driver bind/unbind: $(ls $D/bind $D/unbind 2>&1 | tr '\n' ' ')"
      echo "--- UDC state: $(cat /sys/class/udc/a600000.usb/state 2>/dev/null)"

      # 照 25.05 已验证的顺序：先写 voltage，再 enabled（只写 state 在 25.05 上不够）
      setv() { [ -w "$P/regulator-wifi_$1/voltage" ] && echo "$2" > "$P/regulator-wifi_$1/voltage" 2>/dev/null || true; }
      setv io 1800000; setv dig 752000; setv rfa1 1904000; setv rfa2 1352000; setv aon 500000
      for r in io dig rfa1 rfa2 aon; do
        echo enabled > "$P/regulator-wifi_$r/state" 2>/dev/null || true
      done
      # wlan_en(gpio64) 是芯片真正的电源使能；exp1 已实证缺 wlan_en 时芯片根本不上电
      echo enabled > "$P/regulator-wlan-en-ctl/state" 2>/dev/null || true
      sleep 1

      # 关键：25.05 是在等网卡之前「无条件」做一次 PCIe unbind/bind 才 link up 的。
      # 26.11 上这段被放在了「等 120 秒之后」，于是整场都等不到 wlan0。
      echo "PCIe 重训（无条件，先做）"
      echo 1c00000.pcie > "$D/unbind" 2>/dev/null && echo "unbind ok" || echo "unbind FAILED"
      sleep 2
      echo 1c00000.pcie > "$D/bind" 2>/dev/null && echo "bind ok" || echo "bind FAILED"
      sleep 3
      echo "--- dmesg(pcie) after retrain:"
      dmesg 2>/dev/null | grep -i 'pcie' | tail -6

      i=0; while [ $i -lt 60 ] && [ ! -d /sys/class/net/wlan0 ]; do sleep 1; i=$((i+1)); done
      [ -d /sys/class/net/wlan0 ] || { echo "ath11k 网卡没出现"; exit 0; }
      echo "ath11k 网卡: wlan0"

      ${pkgs.iw}/bin/iw dev wlan0 set power_save off 2>/dev/null || true

      ${lib.optionalString config.networking.networkmanager.enable (lib.concatStringsSep "\n" [
        "# 5) 交给 NetworkManager：固定 MAC 之后让 NM 接管 wlan0 并连上保存的连接"
        "${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true"
        "${pkgs.networkmanager}/bin/nmcli connection up venus-wifi 2>/dev/null || \\"
        "  ${pkgs.networkmanager}/bin/nmcli connection up moli-1004-backup 2>/dev/null || true"
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

      # PCIe 兜底重训：26.11 上 qcom-pcie 常常 deferred probe 到无人重试，
      # 这里显式 unbind/bind 一次把链路拉起来（25.05 时期就是靠这段才 link up 的）。
      if [ ! -d /sys/class/net/wlan0 ]; then
        echo "PCIe 重训：unbind/bind"
        echo 1c00000.pcie > "$D/unbind" 2>/dev/null || true
        sleep 2
        echo 1c00000.pcie > "$D/bind" 2>/dev/null || true
        i=0
        while [ $i -lt 20 ] && [ ! -d /sys/class/net/wlan0 ]; do sleep 1; i=$((i+1)); done
      fi
      echo "VENUS_WIFI_SETUP_DONE wlan0=$([ -d /sys/class/net/wlan0 ] && echo yes || echo no)"
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
    description = "venus: initrd 建 ACM gadget（shell 分离，不阻塞 switch-root）";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "initrd.target" ];
    before = [ "initrd.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = 25;
      TimeoutStopSec = 1;
      KillSignal = "SIGKILL";
    };
    script = ''
      ${venusGadget}
      VLOG=/tmp/venus-usb-state.log
      mount -t configfs none /sys/kernel/config 2>/dev/null || true
      venus_usb_create acm
      venus_usb_bind
      n=0
      while [ ! -c /dev/ttyGS0 ] && [ $n -lt 5 ]; do
        sleep 1
        n=$((n + 1))
      done
      if [ -c /dev/ttyGS0 ]; then
        ( setsid sh </dev/ttyGS0 >/dev/ttyGS0 2>&1 & ) || true
      fi
      # 关键取证：无论后面 stage-2 是否起得来，都把 initrd 阶段的证据落到 /persistent，
      # 这样即使整机黑屏（无串口、无 WiFi），下次启动别的镜像也能读到这次失败现场。
      # 绝不在 initrd 里自己挂 rootfs：switch-root 前遗留多余挂载是切换失败的已知来源。
      # 落盘只在 sysroot 已挂好时做（它由 sysroot.mount 负责），否则放弃。
      VLOGDIR=/sysroot/persistent
      [ -d "$VLOGDIR" ] || VLOGDIR=""
      if [ -n "${VLOGDIR:-}" ] && [ -d "${VLOGDIR:-/nonexistent}" ]; then
        {
          echo "=== $(date '+%F %T') initrd dmesg ==="
          dmesg 2>/dev/null | tail -200
          echo "=== udc ==="
          cat /sys/class/udc/*/state 2>/dev/null
          echo "=== configfs ==="
          ls /sys/kernel/config/usb_gadget 2>/dev/null
          echo "=== rfkill ==="
          ls -l /dev/rfkill 2>/dev/null
        } > "$VLOGDIR/venus-initrd-boot.log" 2>&1
      fi
      if [ -d /sysroot/persistent ]; then
        VLOG=/sysroot/persistent/venus-usb-state.log
        venus_usb_log "initrd: cfgfs=$([ -d /sys/kernel/config/usb_gadget ] && echo yes || echo no) udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no)"
      fi
    '';
  };

  systemd.services.venus-acm = {
    description = "venus: 记录 stage-2 后的 USB 状态（不重建，避免主机丢掉首次枚举）";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${venusGadget}
      ${config.systemd.package}/bin/systemctl reset-failed venus-serial.service 2>/dev/null || true
      venus_usb_log "stage-2 noop cfgfs=$([ -d /sys/kernel/config/usb_gadget ] && echo yes || echo no) gadgets=[$(ls /sys/kernel/config/usb_gadget 2>/dev/null | tr '\n' ' ')] udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -d /sys/class/net/usb0 ] && echo yes || echo no)"
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

  # 死手：冷启动后两条通道都没起来就自己重启，避免"黑屏 + 无 USB"需要人工进 fastboot。
  # 依据：2026-11-16/17 多次 26.11 冷启动后 WiFi 与 COM 同时消失、现场零日志（无任何
  # 可观察通道），只能靠人按电源+音量键。这里把"没有通道"变成一次自动重试。
  # 计数放在 /persistent，重启 3 次仍不行就放弃自动重启，留给人工（并让 ABL 的
  # 失败计数把槽位判为不可引导，回落到 boot_a 的 Android，仍有 adb/fastboot）。
  # stage-2 取证同样落盘（60 秒后写一次），配合 initrd 的那份可以拼出完整启动链
  # 取证：若盘上放了 /persistent/probe.sh，就在启动 20 秒后自动执行它并落盘结果。
  # 这样不需要靠串口在十几秒窗口里手打命令（此前一直是手动发，多次错过）。
  systemd.services.venus-probe = {
    description = "venus: 若存在 /persistent/probe.sh 则自动执行取证";
    serviceConfig = { Type = "oneshot"; TimeoutStartSec = 180; };
    script = ''
      sleep 20
      if [ -x /persistent/probe.sh ]; then
        /persistent/probe.sh || true
        cp -f /persistent/venus-probe.out /persistent/venus-probe-last.out 2>/dev/null || true
      fi
    '';
  };

  systemd.timers.venus-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "50s"; Unit = "venus-probe.service"; };
  };

  systemd.services.venus-bootdump = {
    description = "venus: 把 stage-2 的关键状态写到 /persistent";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 120; };
    script = ''
      sleep 60
      {
        echo "=== $(date '+%F %T') stage-2 dump ==="
        echo "booted=$(readlink -f /run/booted-system)"
        ${pkgs.iproute2}/bin/ip -br addr
        cat /sys/class/udc/*/state 2>/dev/null
        ls /sys/kernel/config/usb_gadget 2>/dev/null
        ${pkgs.systemd}/bin/systemctl --failed --no-pager | head -20
        ${pkgs.systemd}/bin/systemctl status wpa_supplicant systemd-networkd venus-wifi-power venus-usb-keepalive --no-pager 2>&1 | head -40
        echo "=== devices_deferred（-EPROBE_DEFER 的原因就写在这里，正常日志里一个字都不打）==="
        cat /sys/kernel/debug/devices_deferred 2>&1 | head -40
        echo "=== pcie/phy/regulator 相关 dmesg ==="
        ${pkgs.util-linux}/bin/dmesg 2>/dev/null | grep -iE 'pcie|qmp|phy|regulator-wifi|userspace-consumer|smmu' | head -60
      } > /persistent/venus-stage2-boot.log 2>&1
      ${pkgs.util-linux}/bin/dmesg 2>/dev/null > /persistent/venus-dmesg.log || true
    '';
  };

  # 注意：不能 wantedBy = multi-user.target —— 带 sleep 的 oneshot 会把整个
  # multi-user.target 拖住（2026-11-17 16:09 实测：Startup finished 1min 44s，
  # WiFi/串口/keepalive 全部顺延，等于自杀）。改成 timer 触发。
  systemd.services.venus-deadman = {
    description = "venus: 启动 3 分钟后若 WiFi 与串口都没起来就自动回滚并重启（最多 3 次）";
    serviceConfig = { Type = "oneshot"; TimeoutStartSec = 200; };
    script = ''
      set -u
      S=/persistent/venus-deadman.count
      n=$(cat "$S" 2>/dev/null || echo 0)
      if [ "$n" -ge 3 ]; then
        echo "deadman: 已重试 $n 次，放弃自动重启" | tee -a /persistent/venus-deadman.log
        exit 0
      fi
      ip4=$(${pkgs.iproute2}/bin/ip -4 -br addr show wlan0 2>/dev/null | grep -c 'inet ')
      udc=$(cat /sys/class/udc/a600000.usb/state 2>/dev/null || true)
      echo "deadman: n=$n ip4=$ip4 udc=$udc booted=$(readlink -f /run/booted-system)" | tee -a /persistent/venus-deadman.log
      if [ "$ip4" = "0" ] && [ "$udc" != "configured" ]; then
        echo $((n + 1)) > "$S"
        # 自愈：把 /persistent 里备份的可用 boot.img 写回 boot_b 再重启，
        # 否则这台机一旦刷了坏的引导镜像就只能靠人按住电源+音量键进 fastboot。
        # 备份由部署脚本放在 /persistent/boot-backup-2505.img。
        if [ -f /persistent/boot-backup-2505.img ]; then
          echo "deadman: 回写 boot_b ← /persistent/boot-backup-2505.img"
          dd if=/persistent/boot-backup-2505.img of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync 2>/dev/null
        fi
        sync
        ${pkgs.systemd}/bin/systemctl reboot
      else
        rm -f "$S"
      fi
    '';
  };

  systemd.timers.venus-deadman = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; Unit = "venus-deadman.service"; };
  };

  systemd.services.venus-usb-keepalive = {
    description = "venus: UDC 掉了就重绑（连续检查，每 2 秒）";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "simple"; Restart = "always"; RestartSec = 5; };
    script = ''
      ${venusGadget}
      sleep 5
      mount -t configfs none /sys/kernel/config 2>/dev/null || true
      while true; do
        # gadget 可能不存在（switch_root 后由 stage-2 接管的情形），先补齐再谈绑定
        if [ ! -d /sys/kernel/config/usb_gadget/venus ]; then
          venus_usb_create acm
          venus_usb_log "keepalive: gadget 缺失，已重建"
        fi
        st=$(cat /sys/class/udc/a600000.usb/state 2>/dev/null)
        # 只在“根本没有绑定”时才重绑。state=default 表示已绑定、主机正在枚举，
        # 这时再往 UDC 写设备名会让主机重新枚举，永远走不到 configured：
        # 实测日志（/persistent/venus-usb-state.log，2026-11-17 02:57）表现为
        #   keepalive: state=default rebind / bind UDC=a600000.usb state=default
        # 每 6 秒一次的死循环，主机侧没有 COM、也没有 18D1。
        if [ -z "$st" ] || [ "$st" = "not attached" ]; then
          venus_usb_log "keepalive: state=$st rebind"
          venus_usb_bind
          sleep 3
        fi
        sleep 2
      done
    '';
  };

  systemd.services.venus-usb-watch = {
    description = "venus: 记录 Type-C 角色与 UDC 状态";
    serviceConfig = { Type = "oneshot"; };
    script = ''
      ${venusGadget}
      venus_usb_log "watch cfgfs=$([ -d /sys/kernel/config/usb_gadget ] && echo yes || echo no) data_role=$(cat /sys/class/typec/port0/data_role 2>/dev/null) power_role=$(cat /sys/class/typec/port0/power_role 2>/dev/null) udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -d /sys/class/net/usb0 ] && echo yes || echo no)"
    '';
  };

  systemd.timers.venus-usb-watch = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "60s";
      Unit = "venus-usb-watch.service";
    };
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

  systemd.timers.venus-wifi-retry = {
    description = "venus: 每 60 秒重试 WiFi 上电 + PCIe 重训，直到 wlan0 出现";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "40s"; OnUnitActiveSec = "60s"; Unit = "venus-wifi-power.service"; };
  };

  systemd.services.venus-wifi-power = {
    description = "venus: WiFi 上电、连 WiFi（后台执行，不阻塞启动）";
    enable = true;
    # 25.05 是挂在 multi-user.target、在 udev 稳定之后才通的。这里不再设 Before=
    # （否则 oneshot 会把 target 拖住），改由 venus-wifi-retry.timer 每 60 秒重试，
    # 直到 wlan0 出现才停（脚本内部自己判断，出现即秒退）。
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-udevd.service" ];
    # 必须前台同步跑完：脚本里要做“开五路 regulator → pcie bind 重训 → 等 wlan0”。
    # 之前用 `setsid ... & exit 0` 丢到后台，systemd 立刻认为上电完成，
    # 而 PCIe 在那一刻电源还没就位 → qcom-pcie probe 失败 → deferred probe 没人再触发。
    # 实证：2026-11-17 13:44 那次 26.11 启动的设备日志里
    #   journalctl -b | grep -c pcie  →  0     （整场没有 qcom-pcie 一行）
    #   而同一硬件在 25.05 上每次都有 `qcom-pcie: PCIe Gen.3 x1 link up`
    #   ip addr 只有 lo，没有 wlan0。
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 120; };
    environment.VENUS_BLUETOOTH = lib.boolToString config.venus.bluetooth;
    script = ''
      ${pkgs.util-linux}/bin/setsid /etc/venus-wifi-setup >/var/log/venus-wifi.log 2>&1 &
      # setsid 只是为了脱离控制终端；这里等它真正做完（脚本末尾会写 DONE 标记）
      i=0
      while [ $i -lt 100 ] && ! ${pkgs.gnugrep}/bin/grep -q VENUS_WIFI_SETUP_DONE /var/log/venus-wifi.log 2>/dev/null; do
        sleep 1
        i=$((i + 1))
      done
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
