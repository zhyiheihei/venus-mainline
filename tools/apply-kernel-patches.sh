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

# 3) userspace-consumer: 允许非独占 get + 容忍 is_enabled() 返回负值
#    缺这一步，WiFi 的五路 regulator-output 会全部 -EBUSY 探测失败，
#    用户态再怎么 echo enabled 都无效，PCIe 链路就永远训练不起来
#    （实测：dmesg 里 "reg-userspace-consumer regulator-wifi_aon: error -EBUSY: Failed to get supplies"）。
python3 - "$ksrc/drivers/regulator/userspace-consumer.c" <<'PYCE'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
changed = False
if 'devm_regulator_bulk_get_exclusive(' in s:
    s = s.replace('devm_regulator_bulk_get_exclusive(', 'devm_regulator_bulk_get(')
    changed = True
old_is_en = """	ret = regulator_is_enabled(pdata->supplies[0].consumer);
	if (ret < 0) {
		dev_err(&pdev->dev, "Failed to get regulator status\\n");
		goto err_enable;
	}
	drvdata->enabled = !!ret;"""
new_is_en = """	ret = regulator_is_enabled(pdata->supplies[0].consumer);
	if (ret < 0) {
		/* venus: 这条轨在 PMIC 侧是"被独占"的，is_enabled() 返回 -EBUSY。
		 * 当作 disabled 处理即可，真正状态由用户态 echo enabled/disabled 决定。 */
		dev_info(&pdev->dev, "is_enabled() -> %d, 当作 disabled 处理\\n", ret);
		ret = 0;
	}
	drvdata->enabled = !!ret;"""
if old_is_en in s:
    s = s.replace(old_is_en, new_is_en); changed = True
elif '当作 disabled 处理' in s:
    pass
else:
    sys.exit('userspace-consumer 补丁锚点没找到')
p.write_text(s)
print('userspace-consumer 已打补丁' if changed else 'userspace-consumer 已是补丁状态')
PYCE

# 4) ath11k: 支持 WCN6851（SM8350 上 WCN6855 的早期版，自报 hw1.1）
#    没有这一步，probe 直接 "Unsupported WCN6855 SOC hardware version: 1 16" 失败(-EOPNOTSUPP)，
#    表现为"PCIe 端点有了、但 wlan0 永远不出现"。对应上游
#    "wifi: ath11k: enable support for WCN6851" 系列里必需的那一半。
python3 - "$ksrc/drivers/net/wireless/ath/ath11k" <<'PYATH'
import sys, pathlib, re
D = pathlib.Path(sys.argv[1]); changed = []

# a) core.h: 枚举
p = D/'core.h'; s = p.read_text()
if 'ATH11K_HW_WCN6851_HW10' not in s:
    s = s.replace("\tATH11K_HW_WCN6855_HW21,",
                  "\tATH11K_HW_WCN6855_HW21,\n\tATH11K_HW_WCN6851_HW10,", 1)
    p.write_text(s); changed.append('core.h')

# b) pci.c: soc_hw_version_major == 1 → hw1.1
p = D/'pci.c'; s = p.read_text()
if 'ATH11K_HW_WCN6851_HW10' not in s:
    # 注意：pci.c 里有两个 "switch (soc_hw_version_major)"（先 QCA6390、后 WCN6855），
    # 必须插在后一个里 —— 插错了不报错但完全不生效（踩过一次）。
    wcn = s.index('case WCN6855_DEVICE_ID:')
    pat = "\t\tswitch (soc_hw_version_major) {\n\t\tcase 2:"
    j = s.index(pat, wcn)
    ins = ("\t\tswitch (soc_hw_version_major) {\n"
           "\t\tcase 1:\n"
           "\t\t\t/* WCN6851: SM8350 平台上的 WCN6855 早期版，自报 hw1.1 */\n"
           "\t\t\tab->hw_rev = ATH11K_HW_WCN6851_HW10;\n"
           "\t\t\tbreak;\n"
           "\t\tcase 2:")
    s = s[:j] + ins + s[j + len(pat):]
    p.write_text(s); changed.append('pci.c')

# c) mhi.c: 复用 qca6390 的 mhi 配置
p = D/'mhi.c'; s = p.read_text()
if 'ATH11K_HW_WCN6851_HW10' not in s:
    s = s.replace("\tcase ATH11K_HW_WCN6855_HW21:",
                  "\tcase ATH11K_HW_WCN6855_HW21:\n\tcase ATH11K_HW_WCN6851_HW10:", 1)
    p.write_text(s); changed.append('mhi.c')

# d) pcic.c: MSI 配置表（与 wcn6855 相同：32 向量 / MHI3 CE10 WAKE1 DP18）
p = D/'pcic.c'; s = p.read_text()
if 'ATH11K_HW_WCN6851_HW10' not in s:
    m = re.search(r"\t\{\n(?:\t\t\.[\s\S]*?)hw_rev = ATH11K_HW_WCN6855_HW20,\n\t\},", s)
    if m:
        block = m.group(0)
        newblk = block.replace('ATH11K_HW_WCN6855_HW20', 'ATH11K_HW_WCN6851_HW10')
        s = s.replace(block, block + '\n' + newblk, 1)
        p.write_text(s); changed.append('pcic.c')

# e) core.c: hw_params 里加一条，复用 wcn6855 hw2.0 的全部参数，只改 name / hw_rev / fw.dir
p = D/'core.c'; s = p.read_text()
if 'wcn6855 hw1.1' not in s:
    lines = s.splitlines(keepends=True)
    i = next(k for k, l in enumerate(lines) if l.strip() == '.name = "wcn6855 hw2.0",')
    start = max(k for k in range(i) if lines[k] == "\t{\n")
    end = next(k for k in range(i, len(lines)) if lines[k] == "\t},\n")
    block = ''.join(lines[start:end + 1])
    newblk = (block.replace('"wcn6855 hw2.0"', '"wcn6855 hw1.1"')
                   .replace('ATH11K_HW_WCN6855_HW20', 'ATH11K_HW_WCN6851_HW10')
                   .replace('"WCN6855/hw2.0"', '"WCN6855/hw1.1"'))
    out = ''.join(lines[:end + 1]) + newblk + ''.join(lines[end + 1:])
    p.write_text(out); changed.append('core.c')

print('ath11k WCN6851 支持: ' + (', '.join(changed) if changed else '已在位'))
PYATH

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

# ---------- 自检：任何一条补丁没落位就报错，避免"静默丢补丁" ----------
fail=0
chk() { grep -q "$1" "$2" || { echo "补丁缺失: $1  在 $2" >&2; fail=1; }; }
chk 'TOUCHSCREEN_VENUS_FTS' "$ksrc/drivers/input/touchscreen/Kconfig"
chk 'DRM_PANEL_XIAOMI_VENUS_K2' "$ksrc/drivers/gpu/drm/panel/Kconfig"
chk 'qcom_pcie_remove' "$ksrc/drivers/pci/controller/dwc/pcie-qcom.c"
chk 'devm_regulator_bulk_get(' "$ksrc/drivers/regulator/userspace-consumer.c"
chk '当作 disabled 处理' "$ksrc/drivers/regulator/userspace-consumer.c"
python3 - "$ksrc/drivers/net/wireless/ath/ath11k/pci.c" <<'PYCHK' || fail=1
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
w = s.index('case WCN6855_DEVICE_ID:')
if s.find('ATH11K_HW_WCN6851_HW10', w) < 0:
    print('补丁缺失: pci.c 的 WCN6851 case 不在 WCN6855 分支里', file=sys.stderr)
    sys.exit(1)
PYCHK
chk 'wcn6855 hw1.1' "$ksrc/drivers/net/wireless/ath/ath11k/core.c"
[ $fail -eq 0 ] || { echo "内核补丁自检失败" >&2; exit 1; }
echo "内核补丁自检通过"
