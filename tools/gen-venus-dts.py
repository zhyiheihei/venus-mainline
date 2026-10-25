#!/usr/bin/env python3
"""从 star(Mi 11 Ultra)主线 DTS 生成 venus 的 DTS。

star 是公开资料里唯一一份能在这代小米 SM8350 手机上跑主线内核的设备树
(https://patchew.org/linux/20231021-sakuramist-mi11u-v2-0-fa82c91ecaf0@gmail.com/)。
本脚本只做「改身份 + 换 venus 实测值 + 按阶段裁剪」这一层转换, 其余一律照抄 star,
避免我们自己手写设备树反复踩坑。

用法: tools/gen-venus-dts.py [--stage 1|2]
  stage 0: 只留稳压器与 tlmm(连 UFS/USB/屏幕全部关掉), 用来确认内核能否跑到 init
  stage 1(默认): UFS + USB2 + 稳压器 + tlmm + 串口 + 屏幕日志, 其他全关
  stage 2: 在 stage 1 基础上再打开 ADC/RTC/按键等无风险外设
"""
import argparse, pathlib, re, sys
import re as _re

HERE = pathlib.Path(__file__).resolve().parent.parent
REF = HERE / 'kernel/venus/star-reference.dts'
OUT = HERE / 'kernel/venus/sm8350-xiaomi-venus.dts'

# venus 实测值, 来源: Android 运行中的 /sys/firmware/fdt
IDS = '''
	/* ABL 挑表项用; 实测值来自本机 Android 的 /sys/firmware/fdt */
	qcom,msm-id = <0x19f 0x20001>, <0x1c8 0x20001>, <0x1f5 0x20001>;
	qcom,board-id = <0x10008 0x0>;'''

MEMORY = '''
	/* 本机实测(Android /sys/firmware/fdt): 8GB */
	memory@80000000 {
		device_type = "memory";
		reg = <0x00 0x80000000 0x00 0x39700000>,
		      <0x01 0x80000000 0x01 0x00000000>,
		      <0x00 0xc0000000 0x00 0xc0000000>;
	};'''

# venus 的 splash 帧缓冲(下游 DTB 的 cont_splash_region), 用 simpledrm 出早期日志
FB = '''
		/* 复用 ABL 摆好的 splash 帧缓冲, 靠 simpledrm 把早期 dmesg/panic 打到屏幕上;
		 * 不涉及面板/DSI 驱动 */
		framebuffer0: framebuffer@e1000000 {
			compatible = "simple-framebuffer";
			reg = <0 0xe1000000 0 (1440 * 3200 * 4)>;
			width = <1440>;
			height = <3200>;
			stride = <(1440 * 4)>;
			format = "a8r8g8b8";
		};'''

STAGE1_OFF = ['adsp', 'cdsp', 'mpss', 'slpi', 'ipa',
              'i2c4', 'i2c6', 'i2c8', 'i2c13', 'i2c15', 'spi1', 'spi11',
              'gpi_dma0', 'gpi_dma1', 'gpi_dma2', 'qupv3_id_1', 'qupv3_id_2',
              'pmk8350_adc_tm', 'pm8350_gpios', 'pm8350b_gpios',
              'pm8350c_gpios', 'pmr735a_gpios']
STAGE2_ON = ['pmk8350_adc_tm', 'pm8350_gpios', 'pm8350b_gpios',
              'pm8350c_gpios', 'pmr735a_gpios',
              'i2c4', 'i2c6', 'i2c8', 'i2c13', 'i2c15',
              'spi1', 'spi11', 'qupv3_id_1', 'qupv3_id_2',
              'gpi_dma0', 'gpi_dma1', 'gpi_dma2']


def drop_block(text, key):
    """删除包含 key 的子节点块(按大括号配平), 起点回退到行首。"""
    i = text.find(key)
    if i > 0:
        i = text.rfind('\n', 0, i) + 1
    if i < 0:
        return text
    j = text.index('{', i)
    depth = 0
    for k in range(j, len(text)):
        if text[k] == '{':
            depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0:
                end = text.index('\n', k) + 1
                while end < len(text) and text[end] in ' \t':
                    end = text.index('\n', end) + 1
                return text[:i] + text[end:]
    raise RuntimeError('unbalanced block ' + key)


def convert(stage):
    s = REF.read_text()
    # star-reference.dts 直接从 mbox 提取, 末尾可能带 '\ No newline' 与 git 版本号
    s = re.split(r'\\\\ No newline at end of file', s)[0]
    s = re.sub(r'\n?\d+\.\d+\.\d+\s*$', '\n', s)

    # 1) 身份: star -> venus
    s = s.replace('\tmodel = "Xiaomi Mi 11 Ultra";\n\tcompatible = "xiaomi,star", "qcom,sm8350";',
                  '\tmodel = "Xiaomi Mi 11 (venus)";\n\tcompatible = "xiaomi,venus", "qcom,sm8350";\n'
                  + IDS)

    # stage 0: 连屏幕日志也不要(排除 simpledrm 在早期内核里 panic 的可能)
    if stage == 0:
        s = re.sub(r'\n\t\tframebuffer0: framebuffer@[0-9a-f]+ \{.*?\n\t\t\};', '', s, flags=re.S)
    # 2) star 的两块 simple-framebuffer 用 star 的地址, 换成 venus 的
    s = re.sub(r'\n\t\tframebuffer0: framebuffer@[0-9a-f]+ \{.*?\n\t\t\};', FB, s, flags=re.S)
    s = re.sub(r'\n\t\tframebuffer1: framebuffer@[0-9a-f]+ \{.*?\n\t\t\};', '', s, flags=re.S)

    # 3) 内存: 用 venus 实测三段
    s = s.replace('\tchassis-type = "handset";', '\tchassis-type = "handset";\n' + MEMORY, 1)

    # 4) star 的 removed_mem 覆盖 0xd8800000..0xe2800000, 会压住 venus 的 splash 区
    s = s.replace('''		removed_mem: memory@d8800000 {
			reg = <0 0xd8800000 0 0xa000000>;''', '''		removed_mem: memory@d8800000 {
			reg = <0 0xd8800000 0 0x8800000>;''')
    s = re.sub(r'\n\t\tcont_splash_mem: memory@ea600000 \{.*?\n\t\t\};', '', s, flags=re.S)
    s = s.replace('''		reserved-memory {''', '''		reserved-memory {''')

    # venus 的 splash 区(下游 DTB cont_splash_region)在 reserved-memory 里声明
    s = re.sub(r'(\n\treserved-memory \{\n)', r'''\1		/* venus 的 ABL splash 区 */
		cont_splash_mem: memory@e1000000 {
			reg = <0 0xe1000000 0 0x2300000>;
			no-map;
		};

''', s, count=1)

    # 5) 固件路径 star -> venus
    s = s.replace('xiaomi/star/', 'xiaomi/venus/')

    # 6a) ramoops: star 用 0xb0000000, venus 的真实位置是 0xa9000000(整块 2MB 是 pmsg 环)。
    #     我们把整块当 console 区: 内核 panic 时 kmsg_dump 把日志写进这块内存,
    #     Android 起来后 cat /dev/pmsg0 直接读到 —— 不依赖屏幕、不依赖 UFS。
    s = re.sub(r'\n\t\tramoops@[0-9a-f]+ \{.*?\n\t\t\};',
"""
		/* venus 的真实 ramoops 区(取自本机下游 DTB: reg=<0xa9000000 0x200000>,
		 * pmsg-size 占满整块)。声明成 console 区, panic 日志落在偏移 0,
		 * Android 的 /dev/pmsg0 正好映射到同一位置 */
		ramoops@a9000000 {
			compatible = "ramoops";
			reg = <0 0xa9000000 0 0x200000>;
			console-size = <0x200000>;
			no-map;
		};
""", s, flags=re.S)

    # 6a2) dwc3 的**父节点** &usb_1 在 sm8350.dtsi 里也引用了 QMP PHY(usb_1_qmpphy)。
    #      我们只改了 &usb_1_dwc3, 结果 a600000.usb 一直 deferred 在
    #      "supplier 88e3000.phy not ready"(实测 dmesg 证据), UDC 永远不出现。
    #      这里把父节点的 phys 也缩到 qusb2 单 PHY。
    s = s.replace("""&usb_1 {""", """&usb_1 {
	/* 父节点也只保留 USB2 PHY, 否则 dwc3 会一直 deferred 等 disabled 的 QMP PHY */
	phys = <&usb_1_hsphy>;
	phy-names = "usb2-phy";
""")

    # 6b) venus 厂商值: 板级 USB2 PHY 调参(star 版是另一套 factory 值)
    s = s.replace("&usb_1_hsphy {\n\tvdda-pll-supply",
                  "&usb_1_hsphy {\n\t/* venus 厂商值: xiaomi-sm8350-common.dtsi 的 &usb2_phy0 param-override-seq */\n"
                  "\tqcom,param-override-seq = <0xc6 0x6c 0x0f 0x70 0x00 0x74>;\n\n\tvdda-pll-supply")

    # 6) 阶段一: 去掉 Type-C/pmic-glink(依赖 ADSP glink), USB 固定 peripheral
    s = drop_block(s, '\tpmic-glink {')
    s = drop_block(s, 'typec-mux@42 {')
    s = s.replace('''	dr_mode = "otg";
	usb-role-switch;''', '''	dr_mode = "peripheral";''')
    s = re.sub(r'&usb_1_dwc3_hs \{\n\tremote-endpoint = <&pmic_glink_hs_in>;\n\};\n', '', s)


    # 6c) WiFi(qca6490, 下游实测: PCIe RC0 + wlan-en=GPIO64 高有效 + 多路 PMIC 电源)
    #     mainline 没有 cnss 驱动, 这里用 fixed-regulator 把 wlan-en 拉高,
    #     并把下游用到的几路 WiFi 电源声明成 always-on, 让 PCIe 端点能连上。
    s = s.rstrip() + """

/* ---- WiFi(qca6490): 下游 DTB 实测 wlan-en-gpio = tlmm 64(高有效),
 *      bt-en = 65, sw-ctrl = 153; 电源来自 PMIC 各路(S10/S11/L9/PMR735A 等) ---- */
/ {
	wlan_en: regulator-wlan-en {
		compatible = "regulator-fixed";
		regulator-name = "wlan_en";
		regulator-min-microvolt = <1800000>;
		regulator-max-microvolt = <1800000>;
		gpio = <&tlmm 64 GPIO_ACTIVE_HIGH>;
		enable-active-high;
		regulator-boot-on;
		regulator-always-on;
		startup-delay-us = <200000>;
	};

	bt_en: regulator-bt-en {
		compatible = "regulator-fixed";
		regulator-name = "bt_en";
		regulator-min-microvolt = <1800000>;
		regulator-max-microvolt = <1800000>;
		gpio = <&tlmm 65 GPIO_ACTIVE_HIGH>;
		enable-active-high;
		regulator-boot-on;
		regulator-always-on;
	};
};
"""


    # 6f) GPU（Adreno 660）: 上游 sm8350.dtsi 已有完整节点，这里显式打开。
    #     固件 a660_sqe.fw / a660_gmu.bin / a660_zap.mdt(+.b0x) 来自厂商 vendor 分区。
    s = s.rstrip() + '''

/* ---- GPU: Adreno 660 ---- */
&gpu {
	status = "okay";
};

&gpu_zap_shader {
	firmware-name = "a660_zap.mdt";
};
'''

    # 6g) 蓝牙: WCN6851 挂在 uart18(qupv3 SE18, 0x890000, pins gpio68-71)。
    #     板级数据来自 Android 运行时 DTB 的 bluetooth(qos,bt-vdd-* 配置)。
    s = s.rstrip() + '''

/* ---- 蓝牙: WCN6851 on uart18 ---- */
&qupv3_id_2 {
	status = "okay";
};

&tlmm {
	venus_bt_uart_pins: venus-bt-uart-pins {
		pins = "gpio68", "gpio69", "gpio70", "gpio71";
		function = "qup18";
		drive-strength = <2>;
		bias-disable;
	};
};

&uart18 {
	status = "okay";
	pinctrl-names = "default";
	pinctrl-0 = <&venus_bt_uart_pins>;

	bluetooth {
		compatible = "qcom,wcn6855-bt";
		/* 电源轨已由 venus-wifi-power 在运行时打开(wlan/bt 共用),
		 * 这里挂一个 always-on 的 fixed 稳压器满足驱动的 bulk_get */
		vddio-supply = <&bt_vreg>;
		vddbtcxmx-supply = <&bt_vreg>;
		vddrfacmn-supply = <&bt_vreg>;
		vddrfa0p8-supply = <&bt_vreg>;
		vddrfa1p7-supply = <&bt_vreg>;
		vddrfa1p2-supply = <&bt_vreg>;
	};
};
'''


    # wlan_en / bt_en 只保留 boot-on：always-on 会让 sysfs 无法写 state，
    # 而这两根 GPIO 正是给 WCN 芯片做复位的手段（运行时实验必须能拨动）。
    def _drop_always_on(text, name):
        m = _re.search(r'(\n\t%s: regulator-[a-z-]+ \{)(.*?)(\n\t\};)' % name, text, _re.S)
        if not m:
            return text
        body = m.group(2).replace('\n\t\tregulator-always-on;', '')
        return text[:m.start(2)] + body + text[m.end(2):]

    for _n in ('wlan_en', 'bt_en'):
        s = _drop_always_on(s, _n)

    # wlan_en / bt_en 的 regulator-fixed 只有只读 state；要运行时拨 GPIO 必须套一层
    # regulator-output(即 regulator-userspace-consumer)，它才有可写的 state。
    s = s.rstrip() + """

/* ---- wlan_en / bt_en 的运行时开关(套一层 regulator-output 才有可写 state) ---- */
/ {
	wlan_en_ctl: regulator-wlan-en-ctl {
		compatible = "regulator-output";
		regulator-name = "wlan_en_ctl";
		vout-supply = <&wlan_en>;
		regulator-boot-on;
	};

	bt_en_ctl: regulator-bt-en-ctl {
		compatible = "regulator-output";
		regulator-name = "bt_en_ctl";
		vout-supply = <&bt_en>;
		regulator-boot-on;
	};
};
"""
    # 6h) 显示：mdss + dsi0 + dsi0_phy + 面板（K2，1440x3200 DSC 命令模式）
    s = s.rstrip() + """

/* ---- 显示: mdss / dsi0 / dsi0_phy / 面板 ---- */
&mdss {
	status = "okay";
};

&mdss_dsi0 {
	vdda-supply = <&vreg_l6b_1p2>;
	status = "okay";
};

&mdss_dsi0_phy {
	vdds-supply = <&vreg_l5b_0p88>;
	status = "okay";
};

&mdss_dsi0_out {
	remote-endpoint = <&venus_panel_in>;
	data-lanes = <0 1 2 3>;
	/* 命令模式面板由 MDP 的 vsync 当 TE（上游 sdm845 机型同样做法） */
	qcom,te-source = "mdp_vsync_e";
};

&mdss_dsi0 {
	panel@0 {
		compatible = "xiaomi,venus-k2";
		reg = <0>;

		reset-gpios = <&tlmm 24 GPIO_ACTIVE_LOW>;

		vddio-supply = <&vreg_l12c_1p8>;
		vdd-supply = <&vreg_l13c_3p0>;

		port {
			venus_panel_in: endpoint {
				remote-endpoint = <&mdss_dsi0_out>;
			};
		};
	};
};
"""
    # 6e) WiFi 电源: **不**在设备树里强制常开(实测把 s11/s12 常开会开机挂死),
    #     改用 regulator-userspace-consumer, 开机后可在 /sys 里逐个打开,
    #     配合 pcie 的 unbind/bind 做运行时试验, 不需要反复刷机。
    wifi_rails = {
        'wifi_dig':  ('vreg_s11b_0p95', 1012000),
        'wifi_io':   ('vreg_s10b_1p8',  1800000),
        'wifi_rfa2': ('vreg_s12b_1p25', 1352000),
        'wifi_rfa1': ('vreg_s1c_1p86',  1904000),
        'wifi_aon':  ('pmr735a_s2',     1012000),
    }
    for name, (label, uv) in wifi_rails.items():
        s = _re.sub(r'(\n\t\t%s: [a-z0-9]+ \{)' % label,
                    r'\1', s)  # no-op, 仅确保 label 存在
    extra = '\n/* ---- WiFi 电源: 运行时开关(regulator-userspace-consumer) ---- */\n/ {\n'
    for name, (label, uv) in wifi_rails.items():
        extra += (
            '\t%s: regulator-%s {\n'
            '\t\tcompatible = "regulator-output";\n'
            '\t\tregulator-name = "%s";\n'
            '\t\tvout-supply = <&%s>;\n'
            '\t\tregulator-boot-on;\n'
            '\t};\n\n' % (name, name, name, label))
    extra += (
        '\tbt_vreg: regulator-bt-vreg {\n'
        '\t\tcompatible = "regulator-fixed";\n'
        '\t\tregulator-name = "bt_vreg";\n'
        '\t\tregulator-min-microvolt = <1800000>;\n'
        '\t\tregulator-max-microvolt = <1800000>;\n'
        '\t\tregulator-always-on;\n'
        '\t};\n')
    extra += '};\n' 
    s = s.rstrip() + '\n' + extra

    off = [n for n in STAGE1_OFF if not (stage >= 2 and n in STAGE2_ON)]
    if stage == 0:
        off = off + ['ufs_mem_hc', 'ufs_mem_phy', 'usb_1', 'usb_1_dwc3', 'usb_1_hsphy', 'usb_1_qmpphy']
    s = s.rstrip() + '\n\n/* ---- 阶段%d: 只保留 UFS/USB2/稳压器/tlmm/串口/屏幕日志, 其余逐步再开 ---- */\n' % stage
    s += ''.join(f'&{n} {{ status = "disabled"; }};\n' for n in off)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', type=int, default=1)
    ap.add_argument('--no-fb', action='store_true',
                    help='不保留 simple-framebuffer 节点(把 splash 区留给 init 自己用 /dev/mem 写)')
    a = ap.parse_args()
    txt = convert(a.stage)
    if a.no_fb:
        import re as _re
        txt = _re.sub(r'\n\t\tframebuffer0: framebuffer@[0-9a-f]+ \{.*?\n\t\t\};', '', txt, flags=_re.S)
    OUT.write_text(txt)
    print(f'{OUT}: {len(txt.splitlines())} 行, stage {a.stage}')


if __name__ == '__main__':
    main()
