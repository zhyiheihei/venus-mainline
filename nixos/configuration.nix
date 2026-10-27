# venus (Xiaomi Mi 11) 上的 NixOS
#
# 启动链: ABL → boot_b 上的自建内核(7.2.6 + venus.dtb) + NixOS 官方 initrd
#   kernel cmdline 里用 init=/nix/var/nix/profiles/system/init 指定 stage-2
#   （stage-1 默认找 <root>/init，而 --no-bootloader 安装不会创建这个链接）
# 因此不安装 bootloader。

{ config, lib, pkgs, modulesPath, ... }:

let
  # 从 Android 的 modem 分区提取出来的厂商固件（bdwlan ELF 当 board.bin 用，
  # ath11k 见 ELF 头会走 BDF_TYPE_ELF 分支并跳过 CAL 数据）
  venusFirmware = pkgs.runCommandLocal "venus-firmware" { } ''
    mkdir -p $out/lib/firmware
    cp -r ${./firmware}/. $out/lib/firmware/
  '';
  wifiIp = "<LAN_PHONE_IP>";
  wifiGw = "192.168.0.1";
  wifiMac = "02:11:22:3c:4d:5e";
in
{
  imports = [ ./hardware-configuration.nix ];

  # ---------- 引导 ----------
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;
  # 固件由内核从 /run/current-system/firmware 读取（NixOS 里固件是 .zst 压缩的，
  # 而我们的内核没开 FW_LOADER_COMPRESS，所以 venus-firmware 服务会先解压到 /var/lib/venus-fw）
  boot.kernelParams = [ "console=ttyGS0,115200" "consoleblank=0" ];

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

  # ---------- 蓝牙（BlueZ；芯片是 WCN6851，AT 固件在 nixos/firmware/qca/）----------
  # BT UART 是 qupv3 SE18 (0x890000)，DTS 里已给它 alias 并挂了 bluetooth 子节点；
  # 电源轨与 WiFi 共用，由 venus-wifi-setup 在运行时打开后再启动 bluetoothd。
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = false;   # 电源轨还没开时不能上电，交给 venus-wifi-setup 之后启动
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

  # ---------- 串口登录（USB ACM，WiFi 挂了也能进去）----------
  systemd.services."serial-getty@ttyGS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig = { Restart = "always"; RestartSec = 1; };
  };
  # greetd 负责拉桌面；tty1 不开 sway，保留自动登录方便串口/本地登录
  services.getty.autologinUser = "venus";

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

      # 5) 交给 NetworkManager：固定 MAC 之后让 NM 接管 wlan0 并连上保存的连接
      ${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true
      ${pkgs.networkmanager}/bin/nmcli connection up venus-wifi 2>/dev/null || \
        ${pkgs.networkmanager}/bin/nmcli connection up <WIFI_SSID> 2>/dev/null || true

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

  # ---------- 禁止一切休眠（已实测 system-25 上生效且系统正常）----------
  # 这台机器 suspend 后 USB/串口/WiFi 全部消失，恢复后 ath11k 也不通流量，
  # 表现为"设备失联、按一下电源键又回来"，所以把睡眠相关 target 直接屏蔽。
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;
  systemd.targets.suspend-then-hibernate.enable = false;

  # 电源键/休眠键一律不理
  services.logind.extraConfig = ''
    HandlePowerKey=ignore
    HandlePowerKeyLongPress=ignore
    HandleLidSwitch=ignore
    HandleSuspendKey=ignore
    HandleHibernateKey=ignore
    IdleAction=ignore
  '';

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



  # ---------- 日志：持久化 + 限额（标准 systemd 行为）----------
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=256M
    SystemMaxFileSize=32M
  '';

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

  # ---------- 标准内核布局：自建内核 + 模块交给 NixOS ----------
  # 这样 /lib/modules/7.2.6 存在、modprobe 可用，initrd 也能用 kernelModules 早期加载显示模块。
  # NixOS 要求 modulesTree 里只有一个内核版本；我们的模块是 7.2.6，
  # 所以把 kernelPackages.kernel 指向这个包（带 modDirVersion/features 等元数据）。
  boot.kernelPackages = lib.mkForce (let
    kernel = (pkgs.callPackage ./kmods-package.nix { }).overrideAttrs (old: {
      passthru = (old.passthru or { }) // {
        modDirVersion = "7.2.6";
        version = "7.2.6";
        features = { };
      };
    });
    base = {
      inherit kernel;
      kernelAtLeast = v: lib.versionAtLeast "7.2.6" v;
      kernelOlder = v: lib.versionOlder "7.2.6" v;
      stdenv = pkgs.stdenv;
    };
  in base // {
    # NixOS 会对 kernelPackages 调 extend()，这里保持可扩展
    extend = f: base // f base base;
  });

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
  # ---------- 杂项 ----------
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  hardware.firmware = [ venusFirmware ];
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
