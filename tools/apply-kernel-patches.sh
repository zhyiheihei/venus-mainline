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
