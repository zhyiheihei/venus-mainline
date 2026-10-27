#!/usr/bin/env bash
# 把仓库里的内核侧改动打进内核源码树（幂等，可反复跑）。
#   - drivers/gpu/drm/panel/panel-xiaomi-venus-k2.c  + Kconfig/Makefile 条目
#   - drivers/regulator/userspace-consumer.c 的调试补丁（非独占 get / 容忍 is_enabled）
#   - drivers/pci/controller/dwc/pcie-qcom.c 去掉 suppress_bind_attrs + 加 remove 回调
#   - ath11k WCN6851 补丁（tools/patches/wcn6851 已 apply 过的就不再打）
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
ksrc=${KSRC:-$HOME/.cache/venus-kernel/linux-7.2.6}

[ -d "$ksrc" ] || { echo "找不到内核源码树: $ksrc" >&2; exit 1; }

# 0) venus 触摸驱动（ST FTS over 3-wire SPI，由 stmfts 移植）
cp "$root/kernel/venus/fts-spi-venus.c" "$ksrc/drivers/input/touchscreen/"
KC="$ksrc/drivers/input/touchscreen/Kconfig"
KM="$ksrc/drivers/input/touchscreen/Makefile"
grep -q 'TOUCHSCREEN_VENUS_FTS' "$KC" || cat >> "$KC" <<'EOF'

config TOUCHSCREEN_VENUS_FTS
	tristate "venus (Mi 11) ST FTS touchscreen over SPI"
	depends on SPI
	help
	  STMicroelectronics FingerTipS touchscreen controller used on the
	  Xiaomi Mi 11 (venus), wired over 3-wire SPI. Ported from stmfts.
EOF
grep -q 'fts-spi-venus.o' "$KM" || echo 'obj-$(CONFIG_TOUCHSCREEN_VENUS_FTS) += fts-spi-venus.o' >> "$KM"
echo "touch driver 已加入 Kconfig/Makefile"

# 1) venus 面板驱动
cp "$root/kernel/venus/panel-xiaomi-venus-k2.c" "$ksrc/drivers/gpu/drm/panel/"
python3 - "$ksrc/drivers/gpu/drm/panel/Kconfig" "$ksrc/drivers/gpu/drm/panel/Makefile" <<'PY'
import sys, pathlib
kconf, mk = map(pathlib.Path, sys.argv[1:3])

s = kconf.read_text()
if 'config DRM_PANEL_XIAOMI_VENUS_K2' not in s:
    s += '''
config DRM_PANEL_XIAOMI_VENUS_K2
	tristate "Xiaomi Mi 11 (venus) K2 AMOLED DSI panel"
	depends on OF
	depends on DRM_MIPI_DSI
	depends on BACKLIGHT_CLASS_DEVICE
	select DRM_DISPLAY_DSC_HELPER
	help
	  Say Y here if you want to enable support for the Samsung DDIC panel
	  found in the Xiaomi Mi 11 (venus), which is a 1440x3200 command-mode
	  DSI panel using DSC.

	  To compile this driver as a module, choose M here.
'''
    kconf.write_text(s)

s = mk.read_text()
if 'panel-xiaomi-venus-k2.o' not in s:
    s += 'obj-$(CONFIG_DRM_PANEL_XIAOMI_VENUS_K2) += panel-xiaomi-venus-k2.o\n'
    mk.write_text(s)
print('panel driver 已加入 Kconfig/Makefile')
PY

# 2) pcie-qcom: 允许 unbind/bind 重训链路 + remove 回调
python3 - "$ksrc/drivers/pci/controller/dwc/pcie-qcom.c" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if 'venus: 允许运行时 unbind/bind' not in s:
    s = s.replace('\t.suppress_bind_attrs = true,\n', '')
    s = s.replace('\tsuppress_bind_attrs = true,\n', '')
    # 加 remove 回调
    if 'qcom_pcie_remove' not in s:
        s = s.replace('static struct platform_driver qcom_pcie_driver = {',
'''/* venus: 允许运行时 unbind/bind 重新训练 PCIe 链路(ath11k 需要) */
static void qcom_pcie_remove(struct platform_device *pdev)
{
	struct qcom_pcie *pcie = platform_get_drvdata(pdev);
	struct dw_pcie_rp *pp = &pcie->pci->pp;

	if (pp->bridge)
		dw_pcie_host_deinit(pp);
}

static struct platform_driver qcom_pcie_driver = {''')
        s = s.replace('\t.probe = qcom_pcie_probe,\n', '\t.probe = qcom_pcie_probe,\n\t.remove = qcom_pcie_remove,\n')
    p.write_text(s)
    print('pcie-qcom 已打补丁')
else:
    print('pcie-qcom 已是打过补丁的状态')
PY

echo "完成。内核源码树: $ksrc"

# 6) dpu_encoder_phys_cmd: tearcheck 的 vsync_count 用四舍五入（上游是截断）
python3 - "$ksrc/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_cmd.c" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "\ttc_cfg.vsync_count = vsync_hz /\n\t\t\t\t(mode->vtotal * drm_mode_vrefresh(mode));"
new = ("\t/*\n"
       "\t * venus: 四舍五入而不是截断。19.2MHz/(3280*120)=48.78，截断成 48 等于把假\n"
       "\t * vsync 定在 121.95Hz（快 1.95%%），与面板 120Hz 漂移约每秒撕裂 2 帧；\n"
       "\t * 取 49 → 119.46Hz（慢 0.45%%），漂移降到 1/3.6。\n"
       "\t */\n"
       "\ttc_cfg.vsync_count = DIV_ROUND_CLOSEST(vsync_hz,\n"
       "\t\t\t\tmode->vtotal * drm_mode_vrefresh(mode));")
if "DIV_ROUND_CLOSEST(vsync_hz," in s:
    print("vsync_count 四舍五入已在位")
elif old in s:
    p.write_text(s.replace(old, new)); print("vsync_count 已改为四舍五入")
else:
    print("警告: 没找到待替换的 vsync_count 代码")
PY

# 7) qcom_battmgr: 小米 SM8350 固件对 TTF/TTE/MODEL_NAME 的应答与主线不符（超时或长度错），
#    会让驱动每秒刷 dmesg。这三个属性对 venus 直接返回 -ENODATA。
python3 - "$ksrc/drivers/power/supply/qcom_battmgr.c" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "\tif (battmgr->variant == QCOM_BATTMGR_SC8280XP ||"
add = """\t/*
\t * venus (SM8350 小米固件)：TTF/TTE 请求要么超时(-110)、要么回 132 字节字符串；
\t * MODEL_NAME 只回 12 字节整数。三者都会让驱动每秒打印 payload 长度错误，
\t * 把 dmesg 刷满，所以直接返回 -ENODATA（上层只是不显示这些字段）。
\t */
\tif (battmgr->variant == QCOM_BATTMGR_SM8350 &&
\t    (psp == POWER_SUPPLY_PROP_TIME_TO_FULL_AVG ||
\t     psp == POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG ||
\t     psp == POWER_SUPPLY_PROP_MODEL_NAME))
\t\treturn -ENODATA;

"""
if 'TIME_TO_FULL_AVG ||' in s and 'venus (SM8350 小米固件)' in s:
    print('battmgr 属性补丁已在位')
elif anchor in s:
    p.write_text(s.replace(anchor, add + anchor, 1)); print('battmgr 属性补丁已加')
else:
    print('警告: battmgr 补丁锚点没找到')
PY
