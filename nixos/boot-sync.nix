{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.venus.bootSync;

  # 抄 postmarketOS 的 boot-deploy 思路：更新时在系统内重组 boot.img 并 dd 到
  # boot 分区，写前写后各算一次 md5（boot-deploy-functions.sh 的 copy()/
  # flash_android_bootimg() 就是这么干的）。区别是我们不猜槽位：两槽都写、
  # 逐个读回校验，b 先写，中途掉电时 a 还是完整的。
  script = pkgs.writeShellScript "venus-boot-sync" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    img="''${1:-}"
    tag="''${BOOT_SYNC_TAG:-activation}"
    log=/nix/persistent/venus-boot-sync.log
    say() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$tag" "$*" >> "$log" 2>/dev/null || true; }

    [ -n "$img" ] && [ -f "$img" ] || { say "no image ($img), skip"; exit 0; }
    [ "$(head -c 8 "$img")" = "ANDROID!" ] || { say "bad magic in $img, skip"; exit 0; }
    size=$(stat -c %s "$img")
    md5=$(md5sum "$img" | cut -c1-32)
    [ "$size" -gt 8388608 ] || { say "image too small ($size bytes), skip"; exit 0; }

    changed=0
    for slot in boot_b boot_a; do
      dev=/dev/disk/by-partlabel/$slot
      if [ ! -e "$dev" ]; then say "$slot not present, skip"; continue; fi
      cur=$(head -c "$size" "$dev" | md5sum | cut -c1-32)
      if [ "$cur" = "$md5" ]; then say "$slot already $md5"; continue; fi
      if [ "$changed" = 0 ]; then
        # 只保留一份"被覆盖前"的内容，够人工回滚用（deadman 另有 boot-milestone.img）
        dd if="$dev" of=/nix/persistent/boot-replaced.img bs=1M 2>/dev/null || true
        sync
        say "saved previous $slot to boot-replaced.img"
        changed=1
      fi
      say "writing $slot: $size bytes, was $cur, want $md5"
      if ! dd if="$img" of="$dev" bs=1M conv=fsync 2>/dev/null; then
        say "ERROR dd failed for $slot"; exit 1
      fi
      sync
      back=$(head -c "$size" "$dev" | md5sum | cut -c1-32)
      if [ "$back" != "$md5" ]; then say "ERROR $slot readback $back != $md5"; exit 1; fi
      say "$slot verified $back"
      sleep 2
    done

    if [ "$changed" = 1 ]; then
      cp "$img" /nix/persistent/boot-current.img 2>/dev/null || true
      sync
      say "boot partitions synced to $md5"
    fi
  '';
in
{
  options.venus.bootSync = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        激活（switch-to-configuration）与每次启动时，把闭包里的 venus-boot.img
        写进 boot_a/boot_b（内容相同则跳过）。这样内核 / initrd / DTB 变更不再需要
        手工刷机，只需要一次 apply + reboot。
      '';
    };
  };

  config = lib.mkIf (cfg.enable && config.venus.bootImage.enable) {
    assertions = [
      {
        assertion = config.system.boot.loader.kernelFile == "Image";
        message = "venus-boot-sync 假定内核文件名是 Image（ABL 只认这个）";
      }
    ];

    system.activationScripts.venusBootSync = {
      # 在 /nix 与 /nix/persistent 挂好之后跑；activation 由 stage-2 执行。
      text = ''
        BOOT_SYNC_TAG=activation ${pkgs.bash}/bin/bash ${script} "$systemConfig/venus-boot.img" || \
          echo "venus-boot-sync failed (see /nix/persistent/venus-boot-sync.log)" >&2
      '';
    };

    # 兜底：激活时没写成功（或有人手工切了 profile），下次启动再对一次。
    systemd.services.venus-boot-sync = {
      description = "Sync venus boot.img into boot_a/boot_b";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash ${script} /run/current-system/venus-boot.img";
        # fleet 的加固策略会关掉设备节点、只读挂 /nix，这里必须放行真实写盘
        PrivateDevices = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        ProtectSystem = lib.mkForce false;
        ProtectHome = lib.mkForce false;
        DevicePolicy = lib.mkForce "auto";
        ReadWritePaths = lib.mkForce [ "/dev" "/nix/persistent" ];
        SystemCallFilter = lib.mkForce [ ];
        SystemCallArchitectures = lib.mkForce [ ];
        CapabilityBoundingSet = lib.mkForce [ "" ];
      };
    };
  };
}
