# venus-mainline

小米 11（venus，SM8350）的主线 Linux / NixOS 支持。

## 给外部仓库用

```nix
inputs.venus-mainline.url = "github:<owner>/venus-mainline";

nixosConfigurations.<host>.modules = [ inputs.venus-mainline.nixosModules.venus ];
```

模块自带板级默认值：内核 recipe、固件、WiFi（systemd-networkd + wpa_supplicant）、
USB ACM 串口控制台、RTC 同步、显示链路模块。fleet 侧不需要再写板级配置。

内核单独取用：

```nix
lantian.kernel = lib.mkForce (
  pkgsCross.aarch64-multiplatform.callPackage (inputs.venus-mainline + "/nixos/kernel.nix") { }
);
```

交叉使用时编译器进程在 x86_64 上原生执行，产物 hostPlatform 仍是 aarch64-linux。

## 本机独立启机

```bash
tools/make-bootimg.sh /tmp/boot.img         # Image.gz + venus.dtb + 本机 initrd
tools/preflight-flash.sh /tmp/boot.img      # 刷前自检 + 打印刷写计划
```

刷写走 Windows 主机（`tools/win.sh`），只写 `boot_b`：

```bash
tools/win.sh "fastboot flash boot_b /path/boot.img && fastboot reboot"
```

## 红线

绝不 flash：`xbl*`、`xbl_config*`、`abl`、`tz`、`hyp`、`keymaster`、`devcfg`、
`cmnlib*`、`qupfw`、`imagefv`、`persist`、`modemst1/2`、GPT 分区表。
可写：`boot_a/b`、`dtbo_a/b`、`vendor_boot_a/b`、`vbmeta_a/b`、`userdata`。
