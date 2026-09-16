# Xiaomi Mi 11 (venus) headless NixOS 配置
# 前提:M1 内核可引导、M2 UFS 确认后,rootfs 落 userdata,内核经 boot_b 引导
{
  lib,
  modulesPath,
  ...
}:
{
  # M1 前用默认内核包占位;M1 落地后切换到 ../kernel 构建的自建 mainline 内核
  # boot.kernelPackages = pkgs.linuxPackages_custom;

  # 高通 arm64 移植期标配 bootargs;UART console 仅在接了拆机测试点时有效
  boot.kernelParams = [
    "clk_ignore_unused"
    "pd_ignore_unused"
    "console=ttyMSM0,115200n8"
  ];

  # 崩溃日志抢救(无串口调试的主要手段)
  # 需要内核 DTS 里配好 ramoops reserved-memory,数值在 M1 定
  boot.pstore.enable = lib.mkDefault true;

  # TODO(M3): USB gadget configfs(NCM 网卡 usb0 + ACM 串口 ttyGS0)
  # TODO(M3): /etc/systemd/network USB NCM 口 DHCP + 主机侧 NAT 文档

  services.openssh = {
    enable = lib.mkDefault true;
    settings = {
      PermitRootLogin = lib.mkDefault "yes";
      PasswordAuthentication = lib.mkDefault true;
    };
  };

  # 开发期临时口令,落盘后换 key 认证并关闭
  users.users.root.initialPassword = lib.mkDefault "<initial-password>";

  networking = {
    useNetworkd = lib.mkDefault true;
    # USB NCM gadget 口走 DHCP(由主机 NAT 出网)
    interfaces."usb0".useDHCP = lib.mkDefault true;
  };

  # 无屏幕环境,不装图形栈
  documentation.enable = lib.mkDefault false;

  system.stateVersion = "25.11";
}
