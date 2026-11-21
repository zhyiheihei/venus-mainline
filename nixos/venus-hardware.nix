{ config, lib, options, pkgs, ... }:

let
  # 厂商固件：ath11k WCN6851 hw1.1（4MB）与 Adreno 660 的 zap/gmu/sqe（约 120KB）进 git，
  # 其余（qca 蓝牙、ADSP）只在本机工作区存在。路径必须与驱动请求的名字一致：
  #   lib/firmware/ath11k/...                ath11k
  #   lib/firmware/qcom/a660_{sqe.fw,gmu.bin,zap.mdt,zap.b0*}   adreno（少了 qcom/ 这一级就永远 -2）
  # 做存在性判断：没有本地 firmware 目录（例如只有 partial checkout）则退回 nixpkgs 的
  # linux-firmware，避免求值期报 "path .../nixos/firmware does not exist"。
  hasLocalFirmware = builtins.pathExists ./firmware;
  venusFirmware = pkgs.runCommandLocal "venus-firmware" { } (
    if hasLocalFirmware then ''
      mkdir -p $out/lib/firmware
      cp -r ${./firmware}/. $out/lib/firmware/
    '' else ''
      mkdir -p $out/lib/firmware
    ''
  );
  venusDebug = config.venus.debug.enable;
  venusGadget = ''
    venus_usb_log() {
      echo "$(date '+%F %T') [$(cat /proc/1/comm 2>/dev/null)] $*" >> ''${VLOG:-${if venusDebug then "/nix/persistent/venus-usb-state.log" else "/dev/null"}} 2>/dev/null || true
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
      mkdir -p /sysroot/nix/persistent/venus-debug
      {
        systemctl --no-pager --full list-units --all 2>&1 | head -120
        echo
        systemctl --no-pager --full --failed 2>&1 | head -60
        echo
        journalctl -b --no-pager 2>&1 | tail -500
      } > /sysroot/nix/persistent/venus-debug/initrd.log 2>&1 || true
      sync || true
    '';
  };

  # pstore 搬运：两种形态都要。base 内核本来就开着 PSTORE_RAM/CONSOLE，DTS 也有 ramoops
  # 节点，但记录在内存里 —— 不搬运的话下次启动就没了，而这是内核崩溃唯一的证据来源。
  # 只有 /sys/fs/pstore 非空时才真正干活，开销可忽略。
  systemd.services.venus-pstore-copy = {
    description = "venus: collect pstore from previous crash";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /nix/persistent/venus-debug/pstore
      for f in /sys/fs/pstore/*; do
        [ -f "$f" ] || continue
        cp "$f" "/nix/persistent/venus-debug/pstore/$(date +%Y%m%d-%H%M%S)-$(basename "$f")" 2>/dev/null || true
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
      mkdir -p /nix/persistent/venus-debug
      journalctl -b --no-pager > /nix/persistent/venus-debug/journal.log 2>&1 || true
      systemctl --no-pager --failed > /nix/persistent/venus-debug/failed.log 2>&1 || true
      dmesg > /nix/persistent/venus-debug/dmesg.log 2>&1 || true
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
  # nixpkgs 的 wpa_supplicant.service 把 /dev/rfkill 写死在 BindPaths 里，缺这个节点时
  # 启动直接 226/NAMESPACE（"Failed to set up mount namespacing: /dev/rfkill: No such file
  # or directory"）。内核其实有 CONFIG_RFKILL=y（kernel-config:1645），开机后
  # /sys/class/rfkill/rfkill0 与 /dev/rfkill(10:242) 都由 udev 建出来；这条 tmpfiles 规则
  # 只是给"udev 还没建好就先起 wpa_supplicant"的窗口兜底（同 major/minor，不冲突）。
  # THP 默认是 always；手机上（Android/Google 的做法）是 madvise，避免 khugepaged
  # 把 RSS 撑大、以及在内存紧张时产生延迟尖刺。运行期可随时改回。
  systemd.tmpfiles.rules = [
    "w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise"
    "c /dev/rfkill 0600 root root 10 242 - -"
    "d /nix/persistent 0755 root root -"
  ];

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  boot.kernelParams =
    [
      "console=ttyGS0,115200"
      "consoleblank=0"
      # 板级必需项：WiFi 那五路 userspace-consumer regulator / power domain / clock
      # 若被内核当成 "unused" 关掉，固件虽能加载（fw_version 正常），但 40 秒后
      # `ath11k_pci: wmi command 12291 timeout` / `failed to send WMI_SCAN_CHAN_LIST cmd`，
      # wlan0 永远 DOWN。以前这三条只硬编码在 tools/boot-img.sh 里，导致
      # "配置 ≠ 引导"：用 fleet 闭包自带的 kernel-params 组镜像就会丢掉它们
      # （2026-11-19 16:23/17:00 两次 fleet 启动实测）。现在写进配置，两边都由闭包保证。
      "regulator_ignore_unused"
      "pd_ignore_unused"
      "clk_ignore_unused"
    ]
    ++ lib.optionals config.venus.debug.enable [
    "loglevel=8"
    "ignore_loglevel"
    "pstore.backend=ramoops"
    "oops=panic"
    "panic=30"
    "printk.always_kmsg_dump=1"
    "systemd.log_level=debug"
    "systemd.journald.forward_to_console=1"
    # 26.11 的 initrd 是 systemd-initrd，不读 dracut 的 rd.debug / rd.udev.log_level
    # （那是脚本式 initrd 时代的参数），对应写法是 systemd.log_level（上面已有）与
    # udev.log_level。initrd 里的免密 shell 也从 boot.shell_on_fail 换成
    # boot.initrd.systemd.emergencyAccess（下面单独设）。
    "udev.log_level=debug"
    "sysrq_always_enabled=1"
    ];
  # 调试版：initrd 出错时给一个免密 shell（systemd-initrd 的开关；boot.shell_on_fail 是
  # 脚本式 initrd 时代的参数，在这个 initrd 上不生效）。
  boot.initrd.systemd.emergencyAccess = lib.mkDefault config.venus.debug.enable;

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
  # 原本这里写 NetworkManager 的 powersave 配置，但本机 networking.networkmanager.enable = false，
  # NM 根本不存在，配置文件写了也没人读（省电实际由 wpa_supplicant 侧控制）。
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
      # 正式版就是普通登录提示；`--autologin root` 只在调试版打开。
      # 串口是这块板唯一的物理通道，所以两种形态都保留 getty，只差要不要免密。
      ExecStart = lib.mkForce "${pkgs.util-linux}/bin/agetty ${
        lib.optionalString venusDebug "--autologin root"
      } --noclear -8 %I 115200";
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
    # 挂到 sysinit.target 而不是 initrd.target：initrd.target 带
    # OnFailure=emergency.target（replace-irreversibly），一旦 initrd 里任何一步失败
    # （最典型的是 initrd-find-nixos-closure 解不出 init= 的闭包），它会把排队等
    # initrd.target 的单元**全部取消**，venus-serial 一起没，于是既没有 COM3 也没有网，
    # 现场零日志。2026-11-19 两次 fleet 启动就是这样全黑（16:23 那次 udc=default）。
    # 放到 sysinit.target（更早、且不参与那套 replace-irreversibly），保证无论后面
    # 怎么失败，串口和 initrd 落盘都已经就位。
    wantedBy = [ "sysinit.target" ];
    # 不能再写 `before = [ "sysinit.target" ]`：wantedBy 与 before 同时指向同一个 target
    # 会构成 ordering cycle，systemd 会直接把本单元的任务删掉（实测 journal：
    #   sysinit.target: Found ordering cycle: venus-serial.service/start after sysinit.target/start
    #   sysinit.target: Job venus-serial.service/start deleted to break ordering cycle
    # ）→ initrd 里根本没建 gadget，于是 fleet 版每次都是 udc=not attached、COM3 从不出现。
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
      # initrd 里的 root shell 只在 cmdline 带 `venus.shell=1` 时给（不必换 debug 内核，
      # 平时正式版 cmdline 没有这个参数，就没有免登录面）。tools/boot-img.sh 可加 --shell 生成。
      if [ -c /dev/ttyGS0 ] && grep -qw venus.shell=1 /proc/cmdline; then
        ( setsid sh </dev/ttyGS0 >/dev/ttyGS0 2>&1 & ) || true
      fi
      # 关键取证：无论后面 stage-2 是否起得来，都把 initrd 阶段的证据落到 /nix/persistent，
      # 这样即使整机黑屏（无串口、无 WiFi），下次启动别的镜像也能读到这次失败现场。
      # 绝不在 initrd 里自己挂 rootfs：switch-root 前遗留多余挂载是切换失败的已知来源。
      # 落盘只在 sysroot 已挂好时做（它由 sysroot.mount 负责），否则放弃。
      # 持久盘是 /nix（sysroot 内的 sysroot/nix），所以落盘目录直接取 /sysroot/nix/persistent，
      # 不再自己挂任何东西（switch_root 前遗留挂载是切换失败的已知来源）。
      VLOGDIR=/sysroot/nix/persistent
      if [ -d "$VLOGDIR" ]; then
        {
          echo "=== $(date '+%F %T') initrd dmesg ==="
          dmesg 2>/dev/null | tail -200
          echo "=== udc ==="
          cat /sys/class/udc/*/state 2>/dev/null
          echo "=== configfs ==="
          ls /sys/kernel/config/usb_gadget 2>/dev/null
          echo "=== rfkill ==="
          ls -l /dev/rfkill 2>/dev/null
        } > "$VLOGDIR/venus-initrd-boot.log" 2>&1 || true
      fi
      if [ -d /sysroot/nix/persistent ]; then
        VLOG=/sysroot/nix/persistent/venus-usb-state.log
        venus_usb_log "initrd: cfgfs=$([ -d /sys/kernel/config/usb_gadget ] && echo yes || echo no) udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no)"
      fi
    '';
  };

  systemd.services.venus-acm = {
    description = "venus: 记录 stage-2 后的 USB 状态（不重建，避免主机丢掉首次枚举）";
    path = with pkgs; [ util-linux coreutils bash ];
    wantedBy = [ "multi-user.target" ];
    # 26.11 已没有 systemd-udev-settle.service（见上面 serial-getty 的同一条注释）；
    # 写一个不存在的 unit 名只会让排序彻底失效，改成 udevd 本体。
    after = [ "systemd-udevd.service" ];
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
  # 计数放在 /nix/persistent，重启 3 次仍不行就放弃自动重启，留给人工（并让 ABL 的
  # 失败计数把槽位判为不可引导，回落到 boot_a 的 Android，仍有 adb/fastboot）。
  # stage-2 取证同样落盘（60 秒后写一次），配合 initrd 的那份可以拼出完整启动链
  # 取证：若盘上放了 /nix/persistent/probe.sh，就在启动 20 秒后自动执行它并落盘结果。
  # 这样不需要靠串口在十几秒窗口里手打命令（此前一直是手动发，多次错过）。
  # 调试后门：盘上放 probe.sh 就自动执行。正式版不留这个能力（等于"插上盘就执行脚本"）。
  systemd.services.venus-probe = lib.mkIf venusDebug {
    description = "venus: 若存在 /nix/persistent/probe.sh 则自动执行取证（调试版）";
    serviceConfig = { Type = "oneshot"; TimeoutStartSec = 180; };
    script = ''
      sleep 20
      if [ -x /nix/persistent/probe.sh ]; then
        /nix/persistent/probe.sh || true
        cp -f /nix/persistent/venus-probe.out /nix/persistent/venus-probe-last.out 2>/dev/null || true
      fi
    '';
  };

  systemd.timers.venus-probe = lib.mkIf venusDebug {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "50s"; Unit = "venus-probe.service"; };
  };

  # 一次性启动快照（覆盖写，不增长）：两种形态都保留，正式版只写概要；
  # devices_deferred / pcie dmesg / 单元状态这些 verbose 取证只在调试版做。
  systemd.services.venus-bootdump = {
    description = "venus: 把 stage-2 的关键状态写到 /nix/persistent";
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
        ${lib.optionalString venusDebug ''
        ${pkgs.systemd}/bin/systemctl status wpa_supplicant systemd-networkd venus-wifi-power venus-usb-keepalive --no-pager 2>&1 | head -40
        echo "=== devices_deferred（-EPROBE_DEFER 的原因就写在这里，正常日志里一个字都不打）==="
        cat /sys/kernel/debug/devices_deferred 2>&1 | head -40
        echo "=== pcie/phy/regulator 相关 dmesg ==="
        ${pkgs.util-linux}/bin/dmesg 2>/dev/null | grep -iE 'pcie|qmp|phy|regulator-wifi|userspace-consumer|smmu' | head -60
        ''}
      } > /nix/persistent/venus-stage2-boot.log 2>&1
      ${pkgs.util-linux}/bin/dmesg 2>/dev/null > /nix/persistent/venus-dmesg.log || true
    '';
  };

  # 注意：不能 wantedBy = multi-user.target —— 带 sleep 的 oneshot 会把整个
  # multi-user.target 拖住（2026-11-17 16:09 实测：Startup finished 1min 44s，
  # WiFi/串口/keepalive 全部顺延，等于自杀）。改成 timer 触发。
  # 首次启动把根 ext4 扩到整块分区（镜像 8G，分区 224G）；标记文件保证只做一次。
  systemd.services.venus-grow-nix = {
    description = "venus: 首次启动把 /nix 扩到整块分区";
    wantedBy = [ "multi-user.target" ];
    after = [ "nix.mount" ];
    requires = [ "nix.mount" ];
    path = with pkgs; [ btrfs-progs util-linux coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      [ -e /nix/persistent/.grow-done ] && exit 0
      findmnt --noheadings --output SOURCE --target /nix >/dev/null || exit 0
      # /nix 是 btrfs（fleet 布局），扩容用 btrfs filesystem resize max（对应 opi5p-grow-nix）；
      # 早前这里写的是 resize2fs，对 btrfs 直接失败或空转，镜像 8G 永远长不到 224G。
      btrfs filesystem resize max /nix || exit 1
      sync
      touch /nix/persistent/.grow-done
    '';
  };

  systemd.services.venus-deadman = {
    description = "venus: 连续 3 次（每 90 秒）判定无 IPv4 后取证（调试版回滚并重启，正式版只记录）";
    serviceConfig = { Type = "oneshot"; TimeoutStartSec = 400; };
    script = ''
      set -u
      S=/nix/persistent/venus-deadman.count
      MILESTONE=/nix/persistent/boot-milestone.img
      n=$(cat "$S" 2>/dev/null || echo 0)
      if [ "$n" -ge 3 ]; then
        # 达到上限说明这一串启动已经回滚过 3 次。先看当前是否其实健康：
        # 健康就把计数器清零重新布防（否则这个保护会永久失效 —— 2026-11-19 实测：
        # 上午连刷三次坏镜像把计数顶到 3，之后每次启动都在这里直接 exit，
        # 即使 WiFi 已经好了也不再保护；那天后来设备彻底失联时它一声没吭）。
        if [ "$(${pkgs.iproute2}/bin/ip -4 addr show dev wlan0 2>/dev/null | grep -c 'inet ' || true)" != "0" ]; then
          rm -f "$S"
          echo "deadman: 当前已联网，计数器重置并重新布防" >> /nix/persistent/venus-deadman.log
        else
          echo "deadman: 本次启动已回滚 $n 次，放弃（避免无限重启）" | tee -a /nix/persistent/venus-deadman.log
          exit 0
        fi
      fi
      # 连续 3 次（间隔 90 秒）都判定"无 IPv4 且 UDC 未 configured"才动手。
      # 早前版本只等 240 秒判一次，把"还没起来"当成"起不来"，直接覆盖 boot_b，
      # 毁掉正在进行的实验（2026-11-18 11:34 实测：host 模式实验被回滚成 25.05）。
      bad=0
      i=0
      while [ "$i" -lt 3 ]; do
        sleep 90
        i=$((i + 1))
        # set -e 下 grep -c 零匹配会中止脚本，必须 || true
        # 注意：`ip -4 -br addr` 的简要输出里**没有** "inet" 字样
        # （形如 "wlan0 UP 192.168.0.150/24"），用它 grep 'inet ' 永远是 0，
        # 于是 deadman 误判"无网"并在 3 次后回滚重启 —— 2026-11-18 实测：
        # WiFi 明明通着，设备每 4~5 分钟自己重启一次。必须用非简要输出。
        ip4=$(${pkgs.iproute2}/bin/ip -4 addr show dev wlan0 2>/dev/null | grep -c 'inet ' || true)
        udc=$(cat /sys/class/udc/a600000.usb/state 2>/dev/null || echo none)
        # 判据只看"能不能被连上"，不看 UDC：fleet 角色下 USB gadget 是故意不维护的
        # （venus-fleet.nix 关掉了 venus-usb-keepalive），而 PVE 直通在重新枚举时还会丢设备，
        # 于是 udc=configured 完全不代表可达。2026-11-19 16:23 实测：刷了 fleet 闭包后
        # WiFi 没起来、COM3 也没有，deadman 因 udc=configured 判"健康"而拒绝回滚，设备彻底失联。
        gw=$(cat /sys/class/net/wlan0/gateway 2>/dev/null || true)
        echo "deadman: check $i/3 ip4=$ip4 udc=$udc gw=${gw:-none} booted=$(readlink -f /run/booted-system)" >> /nix/persistent/venus-deadman.log
        if [ "$ip4" = "0" ]; then
          bad=$((bad + 1))
        else
          bad=0
          break
        fi
      done
      # 保护：若当前启动的就是 milestone 对应的闭包，回写毫无意义（会把坏镜像刷回自己），
      # 只记录并放弃。2026-11-18 实测踩过：milestone 在验证前被指向了坏镜像，
      # deadman 于是把它回写了 3 次，设备始终起不来。
      if [ "$(readlink -f /run/booted-system)" = "$(cat /nix/persistent/boot-milestone.closure 2>/dev/null)" ]; then
        echo "deadman: 当前已经是 milestone 闭包，不回写（只记录）" | tee -a /nix/persistent/venus-deadman.log
        exit 0
      fi
      if [ "$bad" -ge 3 ]; then
        # 先把现场留下来：这一步两种形态都做（只读 boot_b，安全）。
        dd if=/dev/disk/by-partlabel/boot_b of=/nix/persistent/boot-lastbad.img bs=1M 2>/dev/null || true
        if [ "${if venusDebug then "1" else "0"}" = "1" ]; then
          # 调试版：自动回滚到里程碑镜像并重启（调试期靠它把设备从"无网无串口"里救回来）。
          echo $((n + 1)) > "$S"
          if [ -f "$MILESTONE" ]; then
            echo "deadman: 回写 boot_b ← $MILESTONE（当前镜像已存 /nix/persistent/boot-lastbad.img）" | tee -a /nix/persistent/venus-deadman.log
            dd if="$MILESTONE" of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync 2>/dev/null || true
            sync
            ${pkgs.systemd}/bin/systemctl reboot
          else
            echo "deadman: 缺 $MILESTONE，只记录不重启" | tee -a /nix/persistent/venus-deadman.log
          fi
        else
          # 正式版：只取证与告警，**不改引导分区、不自动重启**。
          # 依据：fleet 里没有一台主机会改写自己的 boot 或自杀重启（见 nixos-config 的
          # server 角色策略），失败统一交给 OnFailure 告警 + 人工处理。手机只有一个 boot_b，
          # 自动 dd 回写把"这次实验失败"变成"设备被换回旧系统"，反而更难查。
          echo "deadman: 判定无网 3 次，已存 /nix/persistent/boot-lastbad.img；正式版不回写、不重启（调试版才会自动回滚）" | tee -a /nix/persistent/venus-deadman.log
        fi
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
        # 实测日志（/nix/persistent/venus-usb-state.log，2026-11-17 02:57）表现为
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

  systemd.services.venus-usb-watch = lib.mkIf venusDebug {
    description = "venus: 记录 Type-C 角色与 UDC 状态（调试版，每 60 秒写盘）";
    serviceConfig = { Type = "oneshot"; };
    script = ''
      ${venusGadget}
      venus_usb_log "watch cfgfs=$([ -d /sys/kernel/config/usb_gadget ] && echo yes || echo no) data_role=$(cat /sys/class/typec/port0/data_role 2>/dev/null) power_role=$(cat /sys/class/typec/port0/power_role 2>/dev/null) udc=[$(cat /sys/class/udc/*/state 2>/dev/null | tr '\n' ' ')] ttyGS0=$([ -c /dev/ttyGS0 ] && echo yes || echo no) usb0=$([ -d /sys/class/net/usb0 ] && echo yes || echo no)"
    '';
  };

  systemd.timers.venus-usb-watch = lib.mkIf venusDebug {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "60s";
      Unit = "venus-usb-watch.service";
    };
  };

  systemd.services.venus-net-watch = lib.mkIf venusDebug {
    description = "venus: 网络/链路状态记录（调试版，每 30 秒写盘）";
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

  # 调试版专属：把关键状态打到 tty0（手机屏幕）并追加到持久盘。
  # 正式版不做周期打屏/无界写盘（那不是一个常规 Linux 设备的行为）；正式版靠
  # journald 持久化 + venus-bootdump 的一次性快照 + pstore 搬运取证。
  # 需要"无网无串口也能看现场"时，切换到 venus-debug 构建即可。
  systemd.services.venus-console-diag = lib.mkIf venusDebug {
    description = "venus: 周期把关键状态打到 tty0 与持久盘（调试版）";
    path = with pkgs; [ iproute2 systemd util-linux coreutils bash iw ];
    serviceConfig = { Type = "oneshot"; TimeoutStartSec = 60; };
    script = ''
      out=$(
        echo "=== $(date '+%F %T') venus diag ==="
        echo "booted=$(readlink -f /run/booted-system)"
        ip -br addr | sed 's/^/  /'
        echo "--- iw link"
        (iw dev wlan0 link 2>&1 || true) | head -6 | sed 's/^/  /'
        echo "--- failed units"
        systemctl --failed --no-pager --plain 2>&1 | head -8 | sed 's/^/  /'
        echo "--- dmesg"
        dmesg 2>/dev/null | grep -iE 'ath11k|qcom-pcie|regulator-wifi|wlan0' | tail -8 | sed 's/^/  /'
      )
      printf '%s\n\n' "$out" >> /nix/persistent/venus-diag.log 2>/dev/null || true
      printf '\n%s\n' "$out" > /dev/tty0 2>/dev/null || true
    '';
  };

  systemd.timers.venus-console-diag = lib.mkIf venusDebug {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "40s"; OnUnitActiveSec = "120s"; Unit = "venus-console-diag.service"; };
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

  # zram：fleet 的 hardening 组件给的是 memoryPercent = 50 / algorithm = zstd。
  # 这里只把比例提到 100（对齐 fleet 里 hosts/google 的做法），算法保持 fleet 的 zstd；
  # zstd 后端要靠 nixos/kernel-config 里的 CONFIG_ZRAM_BACKEND_ZSTD，否则会被降级成 lzo-rle。
  # 与 fleet 的 hardening 组件一致：没有磁盘 swap 时就启用 zram。standalone 之前
  # zramSwap.enable 是默认 false，所以设备上连 /sys/block/zram0 都不存在（实测无输出），
  # 内核里那些 zstd 后端等于白开。
  zramSwap.enable = lib.mkDefault (config.swapDevices == [ ]);
  zramSwap.algorithm = lib.mkDefault "zstd";
  zramSwap.memoryPercent = lib.mkDefault 100;

  # `services.logind.settings` 在 26.11 必然存在，原来的 `options ?` 双分支只剩死代码。
  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandlePowerKeyLongPress = "ignore";
    HandleLidSwitch = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
  };
  services.power-profiles-daemon.enable = false;
  # 这里原本有 Plasma 5 的 powermanagementprofilesrc（DPMS/调光）；本机无桌面，
  # Plasma 6 也已经改用 powerdevilrc，这段是纯残留，直接删掉。
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
  # 这一行不是死配置：fleet 侧（nixos-config 的 kernel-modules 组件）会把一大堆默认
  # availableKernelModules 塞进来，mkForce [] 才是把 initrd 收成"只要显式列出的模块"。
  # 2026-11-19 试过删掉它，结果 initrd 改用 fleet 的全量模块集，触发 modules-shrunk 构建
  # （在 opi5p 上以 "root module: ahci" 失败），闭包直接构建不出来 —— 已回退。
  boot.initrd.availableKernelModules = lib.mkForce [ ];
  # 这一条**不是**死配置，虽然本仓库里搜不到谁定义了 /run/nullfs：
  # fleet 侧（nixos-config 的 kernel-modules 组件）会定义 `fileSystems."/run/nullfs"`（nullfsvfs，
  # 一个树外内核模块），而 venus-fleet.nix 把 `boot.extraModulePackages` mkForce 成 [] ——
  # 于是那个挂载点在这块板子上永远挂不上。留着 fstab 条目会让 local-fs.target 失败：
  # 2026-11-19 18:12 我把这一行当"死配置"删掉，重新构建后设备启动即死（无 journal、无串口、
  # 无网，只能人工进 fastboot）；把它加回来才恢复。
  # 判据：两个闭包的 fstab 只差这一行
  #   nullfsvfs /run/nullfs nullfsvfs noatime,mode=777,nosuid,nodev,noexec 0 2
  fileSystems."/run/nullfs".enable = lib.mkForce false;

  # msm（Adreno 660 + DPU/DSI）**不能**在 initrd 里加载：cmdline 把固件搜索路径设成
  # firmware_class.path=/run/current-system/firmware，而那是 stage-2 才建立的符号链接；
  # initrd 里既没有 /run/current-system 也没有 /lib/firmware，于是 adreno_request_fw 必然 -2：
  #   msm_dpu ae01000.display-controller: Direct firmware load for qcom/a660_sqe.fw failed with error -2
  # 后果是 GPU 永远起不来（显示还能用，因为 DPU 不依赖 GPU 固件）。放到 stage-2 后路径有效，
  # 同时写进 boot.kernelModules 以保证 fleet 的 pruneKernelModules 不把 msm 从模块树里裁掉。
  boot.initrd.kernelModules = [
    "qcom-refgen-regulator" "cec" "drm_display_helper" "drm_dp_aux_bus"
    "drm_exec" "drm_gpuvm" "gpu-sched" "mdt_loader" "ubwc_config"
    "dm-mod"
  ];
  boot.kernelModules = lib.mkAfter [ "msm" "panel-xiaomi-venus-k2" ];

  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa ];
  };
  hardware.firmware = [ venusFirmware ]
    ++ lib.optionals (!hasLocalFirmware) [ pkgs.linux-firmware ];

  };
}
