# kernel/

mainline 内核构建(M1 里程碑落地),策略:

- 基于 nixpkgs `linuxManualConfig`,版本随 nixos-unstable,不 fork 整个内核仓
- DTS 起步:以主线 `sm8350-sony-xperia-sagami-pdx215.dts` 为模板改 venus(平台基础相同,外设逐项换)
- 补丁放 `patches/`,config 放 `venus.config`(从 `make aarch64_defconfig` + `dtbs` 起步收窄)
- boot.img 打包:Image.gz + dtb + ramdisk,`ubootTools` 的 mkimage 生成 Android boot image v4,`fastboot boot` 测试

参考:pmOS pmaports 里 `linux-sony-pdx215` 的补丁集与 config(对照最直接)。
