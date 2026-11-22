{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.venus.bootImage;
  linux = import ./linux-source.nix { inherit pkgs lib; };

  # 与内核同源的 DTB：从打过补丁的内核源码树里就地编译板级 DTS。
  # fleet 闭包用的是预编译内核包（没有 dtbs/），所以不能指望
  # ${config.system.build.kernel}/dtbs —— 自己编是唯一保证六件套同源的办法。
  venusDtb = pkgs.buildPackages.runCommandLocal "sm8350-xiaomi-venus.dtb" {
    nativeBuildInputs = [
      pkgs.buildPackages.gcc
      pkgs.buildPackages.dtc
    ];
  } ''
    src=${linux.patchedSrc}/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts
    gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
      -I ${linux.patchedSrc}/include \
      -I ${linux.patchedSrc}/arch/arm64/boot/dts \
      -I ${linux.patchedSrc}/arch/arm64/boot/dts/qcom \
      -o venus.dts "$src"
    dtc -I dts -O dtb -o $out venus.dts
  '';

  # cmdline 与 tools/boot-img.sh 的 --from-kernel-params 分支逐字对应：
  # 丢掉 init= / console= / 配色 / 与 venus 无关的 tuning 项，再去重、补回板级
  # 三条 *_ignore_unused（WiFi 五路 userspace-consumer regulator 靠它们不被回收）。
  dropPatterns = [
    "init=.*"
    "console=.*"
    "vt\\.default_(red|grn|blu)=.*"
    "swapaccount=1"
    "delayacct"
    "ibt=off"
    "split_lock_detect=.*"
    "kfence\\.sample_interval=.*"
    "damon_stat\\.enabled=.*"
    "sysctl\\.vm\\.mem_profiling=.*"
    "rcuupdate\\.rcu_cpu_stall_suppress=.*"
    "nmi_watchdog=.*"
  ];
  keepParam = p: lib.all (pat: builtins.match pat p == null) dropPatterns;
  dedup = lib.foldl' (acc: p: if lib.elem p acc then acc else acc ++ [ p ]) [ ];
  deduped = dedup (builtins.filter keepParam config.boot.kernelParams);
  boardParams = builtins.filter (p: !(lib.elem p deduped)) [
    "regulator_ignore_unused"
    "pd_ignore_unused"
    "clk_ignore_unused"
  ];
  cmdline = lib.concatStringsSep " " (
    [
      "console=ttyGS0,115200"
      "console=tty0"
    ]
    ++ deduped
    ++ boardParams
    ++ [
      "init=/nix/var/nix/profiles/system/init"
      "firmware_class.path=/run/current-system/firmware"
    ]
  );

  kernelImage = "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";

  # 设备侧只负责"把这个文件 dd 到 boot_a/boot_b"，所以镜像必须在构建期组好。
  # 参数与 tools/boot-img.sh 完全一致（同一份 mkbootimg，pin 在 tools/mkbootimg/），
  # 因此两边对同一闭包应当产出**字节相同**的 boot.img —— 这一点在验收时用 md5 对比。
  bootImage = pkgs.buildPackages.runCommandLocal "venus-boot.img" {
    nativeBuildInputs = [
      pkgs.buildPackages.gzip
      pkgs.buildPackages.python3
    ];
  } ''
    cp -r ${../tools/mkbootimg} mkbootimg
    chmod -R u+w mkbootimg
    export PYTHONPATH=$PWD/mkbootimg
    gzip -9 -n -c ${kernelImage} > kernel.gz
    cat kernel.gz ${venusDtb} > kernel-dtb
    python3 mkbootimg/mkbootimg.py \
      --header_version 2 \
      --kernel kernel-dtb \
      --ramdisk ${initrd} \
      --dtb ${venusDtb} \
      --cmdline "${cmdline}" \
      --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
      --dtb_offset 0x01f00000 --tags_offset 0x00000100 --pagesize 4096 \
      --os_version 14.0.0 --os_patch_level 2099-12 \
      -o $out
  '';
in
{
  options.venus.bootImage = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        在闭包里生成 venus-boot.img（kernel + DTB + initrd + cmdline），
        供 venus-boot-sync 写进 boot_a/boot_b。
      '';
    };
    cmdline = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "写进 boot.img 的 cmdline（与 tools/boot-img.sh 同源）。";
    };
    dtb = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "从内核源码树编出的板级 DTB。";
    };
  };

  config = lib.mkIf cfg.enable {
    system.extraSystemBuilderCmds = ''
      ln -s ${bootImage} $out/venus-boot.img
    '';
    system.build.venusBootImage = bootImage;
    venus.bootImage.cmdline = cmdline;
    venus.bootImage.dtb = venusDtb;
  };
}
