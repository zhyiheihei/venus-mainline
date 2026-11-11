{ config, lib, options, pkgs, ... }:

let
  # 从 Android 的 modem 分区提取出来的厂商固件（bdwlan ELF 当 board.bin 用，
  # ath11k 见 ELF 头会走 BDF_TYPE_ELF 分支并跳过 CAL 数据）。
  # 这份 blobs 不进 git（upstream linux-firmware 只有 WCN6855 hw2.0/hw2.1，没有 venus 要的 hw1.1），
  # 所以做成 option：本仓库装机用默认的 ./firmware，别的调用方（fleet）自己给一份来源。
  venusFirmware = pkgs.runCommandLocal "venus-firmware" { } ''
    mkdir -p $out/lib/firmware
    cp -r ${config.venus.firmware}/. $out/lib/firmware/
  '';
in
{
  options.venus.firmware = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = ./firmware;
    description = "厂商固件目录（ath11k WCN6851 hw1.1 + qca BT 的 blobs）；null 表示不带固件。";
  };

  # 有 options 时其余配置必须落在 config 里
  config = {
  # ---------- 引导 ----------
  # 板级事实：venus 不装 bootloader（系统由外部工具刷进 boot_b / 走 ABL），
  # 用 mkForce 压掉调用方（例如 fleet 的 boot-params.nix 会开 grub）的默认值。
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
  # 固件由内核从 /run/current-system/firmware 读取（NixOS 里固件是 .zst 压缩的，
  # 而我们的内核没开 FW_LOADER_COMPRESS，所以 venus-firmware 服务会先解压到 /var/lib/venus-fw）
  boot.kernelParams = [ "console=ttyGS0,115200" "consoleblank=0" ];

  # 音频不做（用户明确不需要），但 DTS 里的两颗 CS35L41 功放节点还在，
  # udev 看到 i2c 设备就 auto-load 驱动，然后就是 IRQ 风暴：
  #   irq 210: nobody cared ... handlers: cs35l41_irq [snd_soc_cs35l41]
  #   Disabling IRQ #210
  # 之后触摸停摆、用户态变卡（实测 2026-11-09 08:19）。直接不让它们加载。
  boot.blacklistedKernelModules = [
    "snd_soc_cs35l41" "snd_soc_cs35l41_i2c" "snd_soc_cs35l41_lib"
  ];
  # ---------- 蓝牙（BlueZ；芯片是 WCN6851，AT 固件在 nixos/firmware/qca/）----------
  # BT UART 是 qupv3 SE18 (0x890000)，DTS 里已给它 alias 并挂了 bluetooth 子节点；
  # 电源轨与 WiFi 共用，由 venus-wifi-setup 在运行时打开后再启动 bluetoothd。
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;   # 电源轨还没开时不能上电，交给 venus-wifi-setup 之后启动
  };
  # NM 默认开 WiFi 省电(3=enabled)，ath11k 在省电下会掉流量（表现为连上后 ping 不通）
  environment.etc."NetworkManager/conf.d/99-venus-powersave.conf".text = ''
    [connection]
    wifi.powersave=2
  '';
  # ---------- 串口登录（USB ACM，WiFi 挂了也能进去）----------
  systemd.services."serial-getty@ttyGS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    # gadget 由 venus-acm 在 systemd 里重建，必须先于 getty
    after = [ "venus-acm.service" ];
    requires = [ "venus-acm.service" ];
    serviceConfig = { Restart = "always"; RestartSec = 1; };
  };
  # ---------- venus 专有：WiFi 上电 + PCIe 重训 + 网络 ----------
  # WiFi 上电/重训/关联逻辑写在 /etc 里，服务只负责把它丢到后台 —— 避免 16 秒阻塞启动
  environment.etc."venus-wifi-setup" = {
    mode = "0755";
    text = ''
      set -u
      P=/sys/bus/platform/devices

      # 内核已开 FW_LOADER_COMPRESS_ZSTD，可以直接用 NixOS 的 /run/current-system/firmware

      # 1) 五路 WiFi 电源：只能运行时打开（写进设备树 regulator-boot-on 会开机挂死）。
      #    电压已在 DTS 里按厂商值钉死，这里只负责 enabled/disabled。
      for r in io dig rfa1 rfa2 aon; do
        echo enabled > "$P/regulator-wifi_$r/state" 2>/dev/null || true
      done
      sleep 1

      # 2) 重新训练 PCIe 链路（ath11k 才会枚举到端点）。
      #    实测偶发 "Device not found"，所以失败时拨一次 wlan_en 再重训，最多 3 轮。
      D=/sys/bus/platform/drivers/qcom-pcie
      for t in 1 2 3; do
        echo 1c00000.pcie > "$D/unbind" 2>/dev/null || true
        sleep 2
        echo 1c00000.pcie > "$D/bind" 2>/dev/null || true
        sleep 6
        [ -d /sys/class/net/wlan0 ] && break
        echo "第 $t 轮链路没通, 拨 wlan_en 后重试"
        echo disabled > "$P/regulator-wlan-en-ctl/state" 2>/dev/null || true
        sleep 1
        echo enabled > "$P/regulator-wlan-en-ctl/state" 2>/dev/null || true
        sleep 2
      done

      # 3) 等 ath11k 网卡出现（关了可预测命名，名字就是 wlan0）
      i=0; while [ $i -lt 60 ] && [ ! -d /sys/class/net/wlan0 ]; do sleep 1; i=$((i+1)); done
      [ -d /sys/class/net/wlan0 ] || { echo "ath11k 网卡没出现"; exit 0; }
      echo "ath11k 网卡: wlan0"

      # 关掉省电：ath11k 在 PS 模式下会偶发丢流量（表现为拿到地址后 ping 不通）
      ${pkgs.iw}/bin/iw dev wlan0 set power_save off 2>/dev/null || true

      ${lib.optionalString config.networking.networkmanager.enable (lib.concatStringsSep "\n" [
        "# 5) 交给 NetworkManager：固定 MAC 之后让 NM 接管 wlan0 并连上保存的连接"
        "${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true"
        "${pkgs.networkmanager}/bin/nmcli connection up venus-wifi 2>/dev/null || \\"
        "  ${pkgs.networkmanager}/bin/nmcli connection up <WIFI_SSID> 2>/dev/null || true"
      ])}${lib.optionalString (!config.networking.networkmanager.enable) ''
        ${pkgs.iproute2}/bin/ip link set wlan0 up
      ''}

      # 6) 等拿地址（NM 管 DHCP/静态；我们声明的是静态 <LAN_PHONE_IP>）
      i=0; while [ $i -lt 40 ]; do
        [ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = "1" ] && break
        sleep 1; i=$((i+1))
      done
      ${config.systemd.package}/bin/systemctl restart sshd.service 2>/dev/null || true

      # 7) 自检：没有 wlan0 说明链路/固件失败，至少把 PCIe 重新绑上，别留在未绑定状态
      if [ ! -d /sys/class/net/wlan0 ]; then
        echo "自检失败：wlan0 不存在，重新绑定 PCIe"
        echo 1c00000.pcie > "$D/bind" 2>/dev/null || true
        sleep 5
      fi
      ip -4 -o addr show wlan0 2>/dev/null || echo "警告：wlan0 没有地址"

      # 8) 蓝牙：电源轨（与 WiFi 共用）已开，现在才可以让 BlueZ 上电并下载固件
      /run/current-system/sw/bin/rfkill unblock bluetooth 2>/dev/null || true
      /run/current-system/sw/bin/systemctl start bluetooth.service 2>/dev/null || true
      sleep 3
      # 9) 蓝牙上电：电源轨稳了之后多试几次（芯片的固件下载在 open 时才做，
      #    第一次 open 常因为固件路径/时序返回 Failed，第二次就能成功）
      for i in 1 2 3 4 5 6; do
        /run/current-system/sw/bin/bluetoothctl power on >/dev/null 2>&1 || true
        if /run/current-system/sw/bin/bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
          echo "蓝牙已上电（第 $i 次）"
          break
        fi
        sleep 6
      done
      /run/current-system/sw/bin/hciconfig -a 2>/dev/null | head -4 || true
    '';
  };

  # ---- initrd 阶段就把 ACM 串口建起来：26.11 的 systemd-initrd 若在切换前失败，
  # 用户空间永远起不来、stage-2 的 venus-acm 也就没机会跑，串口就一条日志都没有。
  # 这一段只依赖 configfs + dwc3，放在 initrd.target 之前，失败也不影响正常引导。
  boot.initrd.systemd.services.venus-acm-early = {
    description = "venus: initrd 里建 ACM 串口";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "initrd.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      mkdir -p /sys/kernel/config
      mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config || exit 0
      # dwc3 在 initrd 里 probe 得晚，UDC 出现前建 gadget 会失败（EPERM/ENODEV），
      # 这里等最多 30 秒，每出现就不退让地重试
      n=0
      while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ $n -lt 30 ]; do
        sleep 1
        n=$((n + 1))
      done
      UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
      [ -n "$UDC" ] || exit 0
      G=/sys/kernel/config/usb_gadget/venus
      mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
      echo 0x18d1 > "$G/idVendor"
      echo 0x4ee1 > "$G/idProduct"
      echo 0x0100 > "$G/bcdDevice"
      echo 0x0200 > "$G/bcdUSB"
      echo venus-m1 > "$G/strings/0x409/serialnumber"
      echo Xiaomi > "$G/strings/0x409/manufacturer"
      echo venus > "$G/strings/0x409/product"
      echo ACM > "$G/configs/c.1/strings/0x409/configuration"
      echo 250 > "$G/configs/c.1/MaxPower"
      mkdir -p "$G/functions/acm.GS0"
      ln -sf "$G/functions/acm.GS0" "$G/configs/c.1/acm.GS0" || true
      echo "$UDC" > "$G/UDC" || true
    '';
  };
  # initrd 里的裸 shell：gadget 建好后把 ttyGS0 交给一个交互 shell。
  # 内核 console 在开机时就注册，那时 ttyGS0 还不存在，所以后续 printk 不会
  # 自动出现在串口上；要拿现场只能主动在这个端口上起 shell。
  boot.initrd.systemd.services.venus-serial-shell = {
    description = "venus: initrd 串口交互 shell";
    wantedBy = [ "initrd.target" ];
    after = [ "venus-acm-early.service" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 1;
      ExecStart = "/bin/sh -c 'while [ ! -c /dev/ttyGS0 ]; do sleep 1; done; exec setsid sh -c \"exec sh </dev/ttyGS0 >/dev/ttyGS0 2>&1\"'";
    };
  };

  # ---- 串口在 systemd 启动后会丢（dwc3 重新 probe 把 configfs gadget 拆掉），
  # 而串口是本项目唯一的诊断通道，所以由 systemd 再建一次，并挂一个 getty。
  systemd.services.venus-acm = {
    description = "venus: 重建 USB ACM 串口 (console=ttyGS0)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      mkdir -p /sys/kernel/config
      mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config || true
      UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
      [ -n "$UDC" ] || { echo "没找到 UDC"; exit 0; }
      G=/sys/kernel/config/usb_gadget/venus
      mkdir -p "$G" "$G/strings/0x409" "$G/configs/c.1/strings/0x409"
      echo 0x18d1 > "$G/idVendor"
      echo 0x4ee1 > "$G/idProduct"
      echo 0x0100 > "$G/bcdDevice"
      echo 0x0200 > "$G/bcdUSB"
      echo venus-m1 > "$G/strings/0x409/serialnumber"
      echo Xiaomi > "$G/strings/0x409/manufacturer"
      echo venus > "$G/strings/0x409/product"
      echo ACM > "$G/configs/c.1/strings/0x409/configuration"
      echo 250 > "$G/configs/c.1/MaxPower"
      mkdir -p "$G/functions/acm.GS0"
      ln -sf "$G/functions/acm.GS0" "$G/configs/c.1/acm.GS0" || true
      echo "$UDC" > "$G/UDC" || true
    '';
  };

  # ---- WiFi 掉线取证：把链路/地址/NM 状态周期性落到 /var/log/venus-net.log，
  # 这样即使串口掉了，下次也能从磁盘读到现场
  systemd.services.venus-net-watch = {
    description = "venus: 网络/链路状态记录";
    wantedBy = [ "multi-user.target" ];
    after = [ "venus-wifi-power.service" ];
    serviceConfig = { Type = "simple"; Restart = "always"; RestartSec = 30; };
    script = ''
      # NixOS 的 script 包装带 set -e，而开机时 wlan0 还不存在（wifi-power 是后台跑的），
      # iw 会返回非 0 直接把这个服务打死，所以先 set +e 并等网卡出现。
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
        # 只记录，不动网络：曾经在这里每 30s 调 iw/nmcli 抢 wlan0，
        # 与 NM 自己的调度打架，反而造成连接反复抖动。
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
    description = "venus: WiFi 上电、重训 PCIe、连 WiFi（后台执行，不阻塞启动）";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" "systemd-networkd.service" ];
    # Type=oneshot 若同步跑完会把 multi-user/graphical 一起拖住（实测 16 秒）。
    # 这里只把设置脚本丢到后台就返回，启动流程不再等它。
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 20; };
    script = ''
      ${pkgs.util-linux}/bin/setsid /etc/venus-wifi-setup >/var/log/venus-wifi.log 2>&1 &
      exit 0
    '';
  };

  # ---------- 换内核失败自动回滚（省掉"每次都要人肉进 fastboot"）----------
  # WiFi 起不来 = 内核有问题（PCIe 没 link up 或 ath11k 没绑上），此时系统虽然能跑
  # 但没有网络通道，人又进不去。这个服务在开机 90s 后自检：拿不到地址就把
  # /root/boot_b-good.img（工作版镜像）dd 回 boot_b 并重启，最多连做 3 次。
  # 同时把现场的 dmesg / 网络状态写到 /var/log/venus-bootfail.log（持久化），
  # 回滚后就能直接读到失败原因，不用再靠人肉刷机取证。
  systemd.services.venus-wifi-fallback = {
    description = "venus: WiFi 起不来时自动回滚 boot_b 并落证据";
    wantedBy = [ "multi-user.target" ];
    after = [ "venus-wifi-power.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = with pkgs; [ iproute2 util-linux coreutils gawk ];
    script = ''
      set +e
      sleep 90
      # 注意：这里必须用 path 里给的 ip/dmesg，否则 systemd 的最小 PATH 下
      # "ip: command not found" 会让自检恒失败，把好系统也回滚掉（踩过）。
      if ${pkgs.iproute2}/bin/ip -4 -o addr show wlan0 2>/dev/null | grep -q "inet "; then
        rm -f /var/lib/venus-rollback-count
        exit 0
      fi
      GOOD=/root/boot_b-good.img
      LOG=/var/log/venus-bootfail.log
      {
        echo "===== $(date '+%F %T') 启动失败取证 (uname: $(uname -r), $(uname -v)) ====="
        echo "--- ip -o addr ---"; ${pkgs.iproute2}/bin/ip -o addr
        echo "--- pci 端点 ---"
        for d in /sys/bus/pci/devices/*; do
          echo "$(basename "$d") $(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null) driver=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
        done
        echo "--- dmesg 关键行 ---"
        ${pkgs.util-linux}/bin/dmesg | grep -iE "pcie|ath11k|wcn|reg-userspace|link up|firmware|mhi" | tail -80
      } >> "$LOG" 2>&1
      [ -f "$GOOD" ] || { echo "没有 $GOOD，无法回滚" >> "$LOG"; exit 0; }
      n=$(cat /var/lib/venus-rollback-count 2>/dev/null || echo 0)
      [ "$n" -ge 5 ] && { echo "已回滚 $n 次，停止" >> "$LOG"; exit 0; }
      echo $((n+1)) > /var/lib/venus-rollback-count
      echo "--- 回滚 boot_b ($GOOD) ---" >> "$LOG"
      dd if="$GOOD" of=/dev/sde38 bs=1M conv=fsync >> "$LOG" 2>&1
      sync
      systemctl reboot
    '';
  };
  # ---------- 禁止一切休眠（已实测 system-25 上生效且系统正常）----------
  # 这台机器 suspend 后 USB/串口/WiFi 全部消失，恢复后 ath11k 也不通流量，
  # 表现为"设备失联、按一下电源键又回来"，所以把睡眠相关 target 直接屏蔽。
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.targets.suspend-then-hibernate.enable = false;

  # 电源键/休眠键一律不理
  # 25.05 的 nixpkgs 只有 extraConfig；unstable 只剩 settings.Login（并留了一个会断言失败的 extraConfig stub，不能靠它判断）。
  # 板级模块两边都要能用（本仓库独立装机走 25.05，nixos-config 走 unstable），
  # 以 settings 是否存在来选分支。
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
  # ---------- 电源/性能策略：跟随主线，不自己造开关 ----------
  # 事实：主线 arm64 的 platform_profile 提供者只有笔记本 EC（Acer/Huawei/Lenovo/Hamoa），
  # 同 CPU 的主线机型（sagami / mtp / hdk / star）都没有，所以它们也没有可用的
  # "性能/平衡/省电"开关 —— power-profiles-daemon 在这些机器上都只能报 placeholder。
  # 真正起作用的是内核这一套（本机已在跑，实测）：
  #   cpufreq: schedutil（policy0/4/7 = 1.80/2.42/2.84GHz）
  #   thermal: step_wise + 14 组 cooling-maps，
  #            cooling device = cpufreq-cpu0/cpu4/cpu7、devfreq-3d00000.gpu、ath11k
  # 所以这里不再加自定义调频服务：PPD 关掉（避免界面上给了不起作用的开关），
  # 只保留桌面侧的熄屏/待机策略。
  services.power-profiles-daemon.enable = false;
  # Plasma 的电源管理默认值：只熄屏不睡眠（本机不支持 suspend，已在上方屏蔽）
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
  # 关屏/亮屏：只改背光亮度（DCS 0x51），不动 CRTC，避免 DPMS 恢复不了
  environment.etc."venus-bl-toggle.sh".text = ''
    #!/bin/sh
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

  # 开机把亮度设到 50%（systemd-backlight 会用旧值覆盖，这里排在它之后）
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
  # ---------- 标准内核布局 ----------
  # 内核包由调用方定，本模块不选内核（对标 lt-rpi4：内核在主机配置里用 lantian.kernel 指定）：
  #   - 设备装机：configuration.nix 里走 nixos/kernel-prebuilt.nix（设备上跑的那份预编译产物，P1 未解）
  #   - fleet/正常构建：lantian.kernel = pkgs.callPackage (inputs.venus-mainline + "/nixos/kernel.nix") { }
  # 早期 KMS：stage-1 就点亮面板，之后 stage-1/stage-2 的日志都能显示在屏幕上
  # 我们的内核把 UFS/ext4 等都编成内建，不需要 initrd 里的块设备模块；
  # 但 NixOS 默认会要求 ext2 模块，这里显式限定成我们自己的模块集。
  boot.initrd.availableKernelModules = lib.mkForce [ ];
  # initrd 里带显示模块：preinit 在 fbcon 解绑状态下加载它们（避开 probe 期间绘制导致死锁）
  boot.initrd.kernelModules = [
    "qcom-refgen-regulator" "cec" "drm_display_helper" "drm_dp_aux_bus"
    "drm_exec" "drm_gpuvm" "gpu-sched" "mdt_loader" "ubwc_config"
    "msm" "panel-xiaomi-venus-k2"
    "dm-mod"
  ];

  # ---------- 显示模块尽早加载 ----------
  # 目标：让面板在 stage-2 一开始就点亮，屏幕上就能刷内核/服务日志。
  # 注意：模块进 initrd（真正从第 1 秒起就有日志）需要把自建内核连同模块
  # 一起打成 Nix 包，属于后续工作；目前先做到 stage-2 早启。

  # ---------- 图形（GPU/DRM）----------
  # 让 mesa 的 freedreno（msm_dri.so）和 turnip（vulkan）通过 /run/opengl-driver 可用
  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa ];
  };
  # 显示驱动在内核里是 =m（避免 probe 卡死时连 /init 都起不来），
  # 这里按依赖顺序在开机时加载。
  hardware.firmware = lib.optionals (config.venus.firmware != null) [ venusFirmware ];

  };
}
