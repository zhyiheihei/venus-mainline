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
  networking.useDHCP = false;
  # 用 systemd-networkd + resolved 管理地址与 DNS
  networking.useNetworkd = true;
  # 关掉可预测网卡命名，保持 wlan0（脚本/wpa_supplicant 都按这个名字写的）
  networking.usePredictableInterfaceNames = false;
  services.resolved.enable = true;
  networking.nameservers = [ wifiGw "223.5.5.5" ];
  # wlan0 的地址/路由/DNS 交给 systemd-networkd（设备是运行后期才出现，networkd 支持热插）
  systemd.network.networks."20-wlan0" = {
    matchConfig.Name = "wlan0";
    networkConfig = {
      DHCP = "no";
      DNS = [ wifiGw "223.5.5.5" ];
    };
    address = [ "${wifiIp}/24" ];
    routes = [ { Destination = "0.0.0.0/0"; Gateway = wifiGw; } ];
  };
  networking.networkmanager.enable = false;
  networking.wireless = {
    enable = true;
    userControlled.enable = false;
    networks."<WIFI_SSID>" = { psk = "<WIFI_PASSWORD>"; };
  };
  # wlan0 是运行后期才出现的，NixOS 的 network-addresses-wlan0 在开机时找不到设备，
  # 地址由 venus-wifi-power 服务自己加。
  systemd.services."network-addresses-wlan0".enable = false;
  systemd.services."network-setup".enable = false;

  # TODO: 内核的 nftables/LOG 扩展还不完整（ip6tables 里 LOG 规则报 "No such file or directory"），
  # 暂时关掉 NixOS 防火墙；等把 NETFILTER 相关符号补齐再开。
  networking.firewall.enable = false;

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
  systemd.services.venus-wifi-power = {
    description = "venus: WiFi 上电、重训 PCIe、连 WiFi 并配置地址";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" "systemd-networkd.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 180; };
    script = ''
      set -u
      P=/sys/bus/platform/devices

      # 内核已开 FW_LOADER_COMPRESS_ZSTD，可以直接用 NixOS 的 /run/current-system/firmware

      # 1) 五路 WiFi 电源：只能在运行时打开（写进设备树会开机挂死）
      for spec in "io 1800000" "dig 752000" "rfa1 1904000" "rfa2 1352000" "aon 500000"; do
        set -- $spec
        echo "$2" > "$P/regulator-wifi_$1/voltage" 2>/dev/null || true
        echo enabled > "$P/regulator-wifi_$1/state" 2>/dev/null || true
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
        echo disabled > "$P/regulator-wlan_en_ctl/state" 2>/dev/null || true
        sleep 1
        echo enabled > "$P/regulator-wlan_en_ctl/state" 2>/dev/null || true
        sleep 2
      done

      # 3) 等 ath11k 的网卡出现（名字可能是 wlan0 或 wlp1s0，取决于 udev 命名策略）
      IFACE=""
      i=0; while [ $i -lt 60 ]; do
        for n in /sys/class/net/*; do
          b=$(basename "$n")
          [ "$b" = "lo" ] && continue
          [ "$(readlink -f "$n/device/driver" 2>/dev/null | xargs -r basename)" = "ath11k_pci" ] && { IFACE=$b; break; }
        done
        [ -n "$IFACE" ] && break
        sleep 1; i=$((i+1))
      done
      [ -n "$IFACE" ] || { echo "ath11k 网卡没出现"; exit 0; }
      echo "ath11k 网卡: $IFACE"
      # 统一改成 wlan0，脚本/配置都用这个名字
      if [ "$IFACE" != "wlan0" ]; then
        ${pkgs.iproute2}/bin/ip link set "$IFACE" down 2>/dev/null || true
        ${pkgs.iproute2}/bin/ip link set "$IFACE" name wlan0 2>/dev/null || true
      fi
      [ -d /sys/class/net/wlan0 ] || { echo "改名为 wlan0 失败"; exit 0; }

      # 4) 固定 MAC（BDF 里是占位值且每次 probe 都变）
      ${pkgs.iproute2}/bin/ip link set wlan0 down 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip link set wlan0 address ${wifiMac} 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip link set wlan0 up

      # 5) 连 WiFi
      ${config.systemd.package}/bin/systemctl restart wpa_supplicant.service 2>/dev/null || true

      # 6) 等关联完成（地址/DNS 由 systemd-networkd 负责）
      i=0; while [ $i -lt 40 ]; do
        [ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = "1" ] && break
        sleep 1; i=$((i+1))
      done
      ${config.systemd.package}/bin/systemctl restart sshd.service 2>/dev/null || true
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

  # 电源键：交给桌面处理（没有真正 suspend 支持，别让 logind 直接关机）
  services.logind.extraConfig = ''
    HandlePowerKey=ignore
    HandlePowerKeyLongPress=ignore
    HandleLidSwitch=ignore
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
    after = [ "systemd-backlight@backlight:ae94000.dsi.0.service" "venus-drm.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      B=/sys/class/backlight/ae94000.dsi.0/brightness
      [ -e "$B" ] || exit 0
      echo 128 > "$B" 2>/dev/null || true
    '';
  };

  # ---------- 图形（GPU/DRM）----------
  # 让 mesa 的 freedreno（msm_dri.so）和 turnip（vulkan）通过 /run/opengl-driver 可用
  hardware.graphics = {
    enable = true;
    extraPackages = [ pkgs.mesa ];
  };

  # 显示驱动在内核里是 =m（避免 probe 卡死时连 /init 都起不来），
  # 这里按依赖顺序在开机时加载。
  systemd.services.venus-drm = {
    description = "venus: 加载 DRM/显示模块（refgen → msm → panel）";
    wantedBy = [ "multi-user.target" ];
    # 必须早于桌面：Plasma 启动时 DRM 设备得已经存在
    before = [ "greetd.service" "display-manager.service" ];
    after = [ "systemd-udev-settle.service" "venus-wifi-power.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = 120; };
    script = ''
      set -u
      K=/root/ko
      [ -d "$K" ] || exit 0
      # 显示初始化必须在系统起来之后做：早期做会和 PMIC/clock 抢时序导致卡死
      sleep 5
      for m in qcom-pon qcom-refgen-regulator cec drm_display_helper drm_dp_aux_bus \
               drm_exec drm_gpuvm gpu-sched mdt_loader ubwc_config msm \
               panel-xiaomi-venus-k2; do
        ${pkgs.kmod}/bin/modprobe "$m" 2>/dev/null || ${pkgs.kmod}/bin/insmod "$K/$m.ko" 2>/dev/null || true
      done
    '';
  };

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
